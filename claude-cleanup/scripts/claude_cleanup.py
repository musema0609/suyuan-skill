#!/usr/bin/env python3
"""在 macOS 上审计并安全清理 Claude Code / Claude Desktop 本机状态。"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import pathlib
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile

TELEMETRY_KEYS = ("DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
ACCOUNT_CACHE_KEYS = {
    "additionalModelCostsCache", "additionalModelOptionsCache", "anonymousId", "autoCompactWindowsCache",
    "cachedChromeExtensionInstalled", "cachedDynamicConfigs", "cachedExperimentData", "cachedExperimentFeatures",
    "cachedExtraUsageDisabledReason", "cachedGrowthBookFeatures", "cachedGrowthBookFeaturesAt", "cachedStatsigGates",
    "clientDataCache", "clientDataCacheSlots", "feedbackSurveyState", "groveConfigCache", "metricsStatusCache",
    "modelAccessCache", "oauthAccount", "orgModelDefaultCache", "passesEligibilityCache", "s1mAccessCache",
}
PROTECTED = {
    "CLAUDE.md", "agents", "backups", "commands", "debug", "file-history", "history.jsonl", "hooks",
    "mcp-servers", "plans", "plugins", "projects", "scripts", "session-env", "sessions", "settings.json",
    "settings.local.json", "skills", "tasks", "todos",
}
CLI_CACHE = ("cache", "stats-cache.json", "telemetry", "usage-data", "usage.jsonl", "usage.with-fix.jsonl")
SAFE_RELATIVE = ("Library/Caches/claude-cli-nodejs", "Library/Logs/Claude")
SAFE_GLOBS = (
    "Library/Caches/com.anthropic.claudefordesktop*", "Library/Logs/DiagnosticReports/Claude*",
    "Library/Application Support/CrashReporter/Claude*",
)
DESKTOP_RELATIVE = (
    "Library/Application Support/Claude", "Library/Application Support/Claude-3p",
    "Library/Application Support/com.anthropic.claudefordesktop",
    "Library/HTTPStorages/com.anthropic.claudefordesktop",
    "Library/Preferences/com.anthropic.claudefordesktop.plist",
    "Library/Saved Application State/com.anthropic.claudefordesktop.savedState",
    "Library/WebKit/com.anthropic.claudefordesktop",
)
DESKTOP_GLOBS = ("Library/Preferences/ByHost/com.anthropic.claudefordesktop*.plist",)
APP = pathlib.Path("/Applications/Claude.app")


def read_json(path: pathlib.Path, default: object | None = None) -> object:
    if not path.exists() and default is not None:
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: pathlib.Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp = pathlib.Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def settings_env(data: object) -> dict[str, object]:
    if not isinstance(data, dict) or not isinstance(data.get("env", {}), dict):
        raise ValueError("settings.json 的顶层或 env 结构异常，拒绝修改")
    return data.get("env", {})


def telemetry(data: object) -> dict[str, object | None]:
    env = settings_env(data)
    return {key: env.get(key) for key in TELEMETRY_KEYS}


def discover(home: pathlib.Path) -> tuple[list[pathlib.Path], list[pathlib.Path]]:
    claude = home / ".claude"
    safe = [claude / name for name in CLI_CACHE]
    safe += [home / name for name in SAFE_RELATIVE]
    desktop = [home / name for name in DESKTOP_RELATIVE]
    for pattern in SAFE_GLOBS:
        safe += map(pathlib.Path, glob.glob(str(home / pattern)))
    for pattern in DESKTOP_GLOBS:
        desktop += map(pathlib.Path, glob.glob(str(home / pattern)))
    safe = {p for p in safe if p.exists() or p.is_symlink()}
    desktop = {p for p in desktop if p.exists() or p.is_symlink()}
    return sorted(safe, key=str), sorted(desktop, key=str)


def claude_processes() -> list[str]:
    result = subprocess.run(["ps", "-axo", "pid=,comm=,args="], capture_output=True, text=True, check=False)
    found = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=2)
        if len(parts) < 2 or parts[0] == str(os.getpid()):
            continue
        command = pathlib.Path(parts[1]).name.lower()
        args = parts[2] if len(parts) == 3 else ""
        first = pathlib.Path(args.split(maxsplit=1)[0]).name.lower() if args else ""
        if command in {"claude", "claude-code"} or first in {"claude", "claude-code"} or "/Claude.app/" in args:
            found.append(line.strip())
    return found


def running_under_claude() -> bool:
    pid = os.getppid()
    for _ in range(12):
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "ppid=,comm=,args="], capture_output=True, text=True, check=False
        )
        parts = result.stdout.strip().split(maxsplit=2)
        if len(parts) < 2:
            return False
        command = pathlib.Path(parts[1]).name.lower()
        first = pathlib.Path(parts[2].split(maxsplit=1)[0]).name.lower() if len(parts) == 3 else ""
        if command in {"claude", "claude-code"} or first in {"claude", "claude-code"}:
            return True
        next_pid = int(parts[0])
        if next_pid <= 1 or next_pid == pid:
            return False
        pid = next_pid
    return False


def current_timezone() -> str:
    try:
        target = pathlib.Path("/etc/localtime").readlink().as_posix()
    except OSError:
        return "未知"
    return target.split("/zoneinfo/", 1)[1] if "/zoneinfo/" in target else "未知"


def create_backup(home: pathlib.Path) -> pathlib.Path:
    claude, identity = home / ".claude", home / ".claude.json"
    if not claude.is_dir():
        raise FileNotFoundError("~/.claude 不存在，无法满足先全量备份的硬要求")
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    partial = home / "ClaudeBackups" / f"claude-cleanup-{stamp}.partial"
    final = partial.with_suffix("")
    partial.mkdir(parents=True)
    shutil.copytree(claude, partial / "dot-claude", symlinks=True)

    def stats(root: pathlib.Path) -> tuple[int, int]:
        regular = [p for p in root.rglob("*") if p.is_file() and not p.is_symlink()]
        return len(regular), sum(p.stat().st_size for p in regular)

    if stats(claude) != stats(partial / "dot-claude"):
        raise RuntimeError(f"~/.claude 备份校验失败，保留未完成副本：{partial}")
    copied_identity = False
    if identity.is_file():
        shutil.copy2(identity, partial / "claude.json")
        copied_identity = identity.stat().st_size == (partial / "claude.json").stat().st_size
        if not copied_identity:
            raise RuntimeError(f"~/.claude.json 备份校验失败，保留未完成副本：{partial}")
    files, bytes_ = stats(claude)
    write_json(partial / "manifest.json", {"files": files, "regularFileBytes": bytes_, "claudeJsonCopied": copied_identity})
    partial.rename(final)
    return final


def move_to_trash(target: pathlib.Path, allowed: set[pathlib.Path], claude: pathlib.Path, batch: pathlib.Path) -> pathlib.Path:
    absolute = target.absolute()
    protected = {claude / name for name in PROTECTED}
    if absolute == claude.absolute() or any(absolute == p.absolute() or p.absolute() in absolute.parents for p in protected):
        raise RuntimeError(f"拒绝触碰受保护路径：{target}")
    if absolute not in {path.absolute() for path in allowed}:
        raise RuntimeError(f"目标不在删除白名单：{target}")
    batch.mkdir(parents=True, exist_ok=True)
    destination = batch / f"{len(list(batch.iterdir())):02d}-{target.name}"
    shutil.move(str(target), str(destination))
    return destination


def rotate_identity(home: pathlib.Path) -> int:
    identity, backups = home / ".claude.json", home / ".claude/backups"
    if not identity.is_file():
        raise FileNotFoundError("~/.claude.json 不存在，无法轮换本地 ID")
    files = [identity]
    if backups.is_dir():
        files += sorted(p for p in backups.glob(".claude.json.backup.*") if p.is_file() and not p.is_symlink())
    ids, prepared = {"userID": secrets.token_hex(32), "machineID": secrets.token_hex(32)}, []
    for path in files:
        data = read_json(path)
        if not isinstance(data, dict):
            raise ValueError(f"身份文件不是 JSON object：{path}")
        updated = dict(data)
        updated.update(ids)
        for key in ACCOUNT_CACHE_KEYS:
            updated.pop(key, None)
        prepared.append((path, updated))
    for path, data in prepared:
        write_json(path, data)
    return len(files) - 1


def update_simple(home: pathlib.Path, mode: int) -> None:
    path = home / ".claude/settings.json"
    if mode == 2 and not path.exists():
        return
    data = read_json(path, {})
    if not isinstance(data, dict):
        raise ValueError("settings.json 顶层必须是 JSON object")
    before, updated, env = telemetry(data), dict(data), dict(settings_env(data))
    if mode == 1:
        env["CLAUDE_CODE_SIMPLE"] = "1"
    else:
        env.pop("CLAUDE_CODE_SIMPLE", None)
    updated["env"] = env
    if telemetry(updated) != before:
        raise RuntimeError("精简模式修改触碰了遥测设置")
    if updated != data:
        write_json(path, updated)


def ask_yes(prompt: str) -> bool:
    return input(f"{prompt} [y/N]：").strip().lower() == "y"


def ask_choice(prompt: str, allowed: set[int]) -> int:
    value = input(prompt).strip() or "0"
    if not value.isdigit() or int(value) not in allowed:
        raise ValueError("输入不在允许范围内，已停止且未修改")
    return int(value)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="安全审计和清理 Claude 本机状态")
    parser.add_argument("--audit", action="store_true", help="只读审计")
    args = parser.parse_args(argv)
    home, app = pathlib.Path.home(), APP
    claude, identity, settings = home / ".claude", home / ".claude.json", home / ".claude/settings.json"
    if running_under_claude() and not args.audit:
        print("拒绝执行：当前脚本由 Claude Code 启动。请改用 Codex 或普通终端；这里只允许 --audit。", file=sys.stderr)
        return 2
    try:
        settings_data = read_json(settings, {})
        env = settings_env(settings_data)
        safe, desktop = discover(home)
        processes = claude_processes()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"审计失败：{error}", file=sys.stderr)
        return 2
    disabled = [key for key in TELEMETRY_KEYS if str(env.get(key, "")).lower() in {"1", "true", "yes", "on"}]
    print("Claude Cleanup 会自动清理明确可再生的缓存/日志；风险操作仍由你选择。")
    print("输入最终 CONFIRM 前不会写盘；所有移除只进入废纸篓。\n\n只读审计：")
    print(f"- ~/.claude：{'存在' if claude.is_dir() else '不存在'}；~/.claude.json：{'存在' if identity.is_file() else '不存在'}")
    print(f"- 可自动清理缓存/日志：{len(safe)} 项；Claude Desktop 持久数据：{len(desktop)} 项")
    print(f"- Claude.app：{'存在' if app.exists() else '不存在'}；相关进程：{len(processes)} 个")
    print(f"- 遥测关闭键：{', '.join(disabled) if disabled else '未检测到'}（脚本不会改变）")
    print(f"- 精简模式：{'已启用' if str(env.get('CLAUDE_CODE_SIMPLE', '')).lower() in {'1', 'true'} else '未启用'}；时区：{current_timezone()}")
    if args.audit:
        return 0
    if not sys.stdin.isatty():
        print("拒绝执行：需要真实 TTY 完成知情确认。", file=sys.stderr)
        return 2

    try:
        print("\n只询问有风险的操作；可再生缓存和日志不逐项询问。")
        rotate = ask_yes("轮换本地 userID/machineID，并清除已知账号缓存字段？")
        keychain = ask_yes("删除钥匙串 Claude Code-credentials（会退出 CLI 登录）？")
        desktop_mode = ask_choice("Claude Desktop：0 保留；1 清登录态/持久数据；2 再移除应用。选择 [0]：", {0, 1, 2})
        simple_mode = ask_choice("精简模式：0 保持；1 启用 CLAUDE_CODE_SIMPLE；2 移除该设置。选择 [0]：", {0, 1, 2})
        set_timezone = current_timezone() != "Asia/Taipei" and ask_yes("把 macOS 时区改为 Asia/Taipei？")
        risky = rotate or keychain or desktop_mode or simple_mode
        clean_safe = not processes
        if processes and risky:
            print("\n所选风险操作要求由你正常退出所有 Claude Code / Claude Desktop；脚本不会 kill 进程。")
            input("退出后按 Enter 重新检查：")
            if claude_processes():
                print("仍检测到 Claude 进程，已取消且未写盘。", file=sys.stderr)
                return 2
            clean_safe = True
        targets = (safe if clean_safe else []) + (desktop if desktop_mode else [])
        if desktop_mode == 2 and app.exists():
            targets.append(app)

        print("\n最终执行清单：")
        print("1. 第一个写操作：完整备份并校验 ~/.claude，同时备份 ~/.claude.json。")
        action = "自动清理" if clean_safe else "因 Claude 正在运行而跳过"
        print(f"2. {action} {len(safe)} 项缓存/日志。")
        for target in targets:
            print(f"   - {target}")
        print(f"3. 身份轮换：{'是' if rotate else '否'}；删除钥匙串：{'是' if keychain else '否'}；精简模式：{simple_mode}；修改时区：{'是' if set_timezone else '否'}")
        print("绝不清理 sessions、projects、history、skills、plugins、hooks、commands、agents、MCP、设置文件或任何项目/Git/Codex 数据。")
        print("所有移除只进废纸篓；遥测键逐值保持不变。")
        if input("完全理解后输入 CONFIRM 开始；其他输入取消：").strip() != "CONFIRM":
            print("已取消，没有修改任何内容。")
            return 1

        before_telemetry = telemetry(read_json(settings, {}))
        protected_before = [claude / name for name in PROTECTED if (claude / name).exists() or (claude / name).is_symlink()]
        backup = create_backup(home)  # 第一个写操作
        print(f"\n[1/6] 全量备份已校验：{backup}")
        if set_timezone:
            print("[人工步骤] 仅在终端原生 sudo 隐藏提示中输入 Mac 开机密码；脚本不会读取或保存密码。")
            subprocess.run(["sudo", "-v"], check=True)
        print(f"[2/6] 身份轮换：同步 {rotate_identity(home)} 份内部备份" if rotate else "[2/6] 身份保持不变")
        if keychain:
            result = subprocess.run(["security", "delete-generic-password", "-s", "Claude Code-credentials"], capture_output=True, text=True, check=False)
            if result.returncode not in {0, 44}:
                raise RuntimeError(f"钥匙串处理失败：{result.stderr.strip()}")
        print(f"[3/6] 钥匙串：{'已处理' if keychain else '保持不变'}")
        batch = home / ".Trash" / f"claude-cleanup-{dt.datetime.now().strftime('%Y%m%d-%H%M%S-%f')}"
        moved = [move_to_trash(target, set(targets), claude, batch) for target in targets]
        print(f"[4/6] 已移入废纸篓：{len(moved)} 项")
        if simple_mode:
            update_simple(home, simple_mode)
        print(f"[5/6] 精简模式：{('保持', '启用', '移除')[simple_mode]}")
        if set_timezone:
            subprocess.run(["sudo", "/usr/sbin/systemsetup", "-settimezone", "Asia/Taipei"], check=True)
            if current_timezone() != "Asia/Taipei":
                raise RuntimeError("时区修改后验证失败")
        if telemetry(read_json(settings, {})) != before_telemetry:
            raise RuntimeError("遥测设置发生变化，已停止")
        missing = [path for path in protected_before if not (path.exists() or path.is_symlink())]
        if missing:
            raise RuntimeError("受保护路径丢失：" + ", ".join(map(str, missing)))
        print(f"[6/6] 遥测状态未变；时区：{current_timezone()}\n\n完成。未清空废纸篓。\n备份：{backup}")
        if moved:
            print(f"废纸篓批次：{batch}")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"停止：{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
