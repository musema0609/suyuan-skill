#!/usr/bin/env python3
"""macOS 上交互式、失败即停止的 Claude 本机清理脚本。

脚本故意不提供非交互式确认参数。所有破坏性操作都限制在下方白名单中，
执行前必须完整备份 ~/.claude，文件只移入废纸篓而不永久删除。
"""

from __future__ import annotations

import argparse
import dataclasses
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
from typing import Iterable


TRUTHY = {"1", "true", "yes", "on"}

ACCOUNT_CACHE_KEYS = {
    "additionalModelCostsCache",
    "additionalModelOptionsCache",
    "anonymousId",
    "autoCompactWindowsCache",
    "cachedChromeExtensionInstalled",
    "cachedDynamicConfigs",
    "cachedExperimentData",
    "cachedExperimentFeatures",
    "cachedExtraUsageDisabledReason",
    "cachedGrowthBookFeatures",
    "cachedGrowthBookFeaturesAt",
    "cachedStatsigGates",
    "clientDataCache",
    "clientDataCacheSlots",
    "feedbackSurveyState",
    "groveConfigCache",
    "metricsStatusCache",
    "modelAccessCache",
    "oauthAccount",
    "orgModelDefaultCache",
    "passesEligibilityCache",
    "s1mAccessCache",
}

PROTECTED_CLAUDE_NAMES = {
    "CLAUDE.md",
    "agents",
    "backups",
    "commands",
    "debug",
    "file-history",
    "history.jsonl",
    "hooks",
    "mcp-servers",
    "plans",
    "plugins",
    "projects",
    "scripts",
    "session-env",
    "sessions",
    "settings.json",
    "settings.local.json",
    "skills",
    "tasks",
    "todos",
}

CLI_CACHE_NAMES = (
    "cache",
    "stats-cache.json",
    "telemetry",
    "usage-data",
    "usage.jsonl",
    "usage.with-fix.jsonl",
)

DESKTOP_RELATIVE_PATHS = (
    "Library/Application Support/Claude",
    "Library/Application Support/Claude-3p",
    "Library/Application Support/com.anthropic.claudefordesktop",
    "Library/Caches/com.anthropic.claudefordesktop",
    "Library/Caches/com.anthropic.claudefordesktop.ShipIt",
    "Library/HTTPStorages/com.anthropic.claudefordesktop",
    "Library/Logs/Claude",
    "Library/Preferences/com.anthropic.claudefordesktop.plist",
    "Library/Saved Application State/com.anthropic.claudefordesktop.savedState",
    "Library/WebKit/com.anthropic.claudefordesktop",
)

DESKTOP_GLOBS = (
    "Library/Preferences/ByHost/com.anthropic.claudefordesktop*.plist",
    "Library/Application Support/CrashReporter/Claude*",
    "Library/Logs/DiagnosticReports/Claude*",
)

TELEMETRY_KEYS = (
    "DISABLE_TELEMETRY",
    "DISABLE_ERROR_REPORTING",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
)


@dataclasses.dataclass(frozen=True)
class Paths:
    home: pathlib.Path

    @property
    def claude_dir(self) -> pathlib.Path:
        return self.home / ".claude"

    @property
    def claude_json(self) -> pathlib.Path:
        return self.home / ".claude.json"

    @property
    def settings(self) -> pathlib.Path:
        return self.claude_dir / "settings.json"

    @property
    def backup_root(self) -> pathlib.Path:
        return self.home / "ClaudeBackups"

    @property
    def trash(self) -> pathlib.Path:
        return self.home / ".Trash"


@dataclasses.dataclass(frozen=True)
class Plan:
    rotate_identity: bool
    delete_keychain: bool
    desktop_data: bool
    desktop_app: bool
    clear_cli_caches: bool
    simple_prompt: str  # preserve | enable | disable
    set_taipei_timezone: bool


def read_json(path: pathlib.Path, *, default: object | None = None) -> object:
    if not path.exists() and default is not None:
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def atomic_write_json(path: pathlib.Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    old_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = pathlib.Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, old_mode)
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def env_from_settings(settings: object) -> dict[str, object]:
    if not isinstance(settings, dict):
        raise ValueError("settings.json 顶层必须是 JSON object")
    env = settings.get("env", {})
    if not isinstance(env, dict):
        raise ValueError("settings.json 的 env 不是 object，拒绝自动替换")
    return env


def telemetry_snapshot(settings: object) -> dict[str, object | None]:
    env = env_from_settings(settings)
    return {key: env.get(key) for key in TELEMETRY_KEYS}


def telemetry_status(settings: object) -> str:
    env = env_from_settings(settings)
    if str(env.get("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "")).lower() in TRUTHY:
        return "已关闭（CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC）"
    if str(env.get("DISABLE_TELEMETRY", "")).lower() in TRUTHY:
        return "已关闭（DISABLE_TELEMETRY）"
    return "未检测到关闭开关"


def update_simple_prompt(settings: object, mode: str) -> dict[str, object]:
    if not isinstance(settings, dict):
        raise ValueError("settings.json 顶层必须是 JSON object")
    result = dict(settings)
    env = dict(env_from_settings(settings))
    telemetry_before = {key: env.get(key) for key in TELEMETRY_KEYS}
    if mode == "enable":
        env["CLAUDE_CODE_SIMPLE"] = "1"
    elif mode == "disable":
        env.pop("CLAUDE_CODE_SIMPLE", None)
    elif mode != "preserve":
        raise ValueError(f"未知 simple prompt mode: {mode}")
    result["env"] = env
    telemetry_after = {key: env.get(key) for key in TELEMETRY_KEYS}
    if telemetry_after != telemetry_before:
        raise AssertionError("遥测状态不得被 prompt 优化修改")
    return result


def rotate_identity(
    data: object,
    *,
    new_user_id: str | None = None,
    new_machine_id: str | None = None,
) -> tuple[dict[str, object], dict[str, str | None], dict[str, str]]:
    if not isinstance(data, dict):
        raise ValueError("~/.claude.json 顶层必须是 JSON object")
    result = dict(data)
    old_ids = {
        key: result.get(key) if isinstance(result.get(key), str) else None
        for key in ("userID", "machineID")
    }
    new_ids = {
        "userID": new_user_id or secrets.token_hex(32),
        "machineID": new_machine_id or secrets.token_hex(32),
    }
    result.update(new_ids)
    for key in ACCOUNT_CACHE_KEYS:
        result.pop(key, None)
    return result, old_ids, new_ids


def identity_backup_files(paths: Paths) -> list[pathlib.Path]:
    root = paths.claude_dir / "backups"
    if not root.is_dir():
        return []
    return sorted(
        path
        for path in root.glob(".claude.json.backup.*")
        if path.is_file() and not path.is_symlink()
    )


def rotate_identity_files(paths: Paths) -> tuple[dict[str, str | None], dict[str, str], int]:
    if not paths.claude_json.is_file():
        raise FileNotFoundError(f"身份文件不存在：{paths.claude_json}")
    files = [paths.claude_json, *identity_backup_files(paths)]
    new_ids = {"userID": secrets.token_hex(32), "machineID": secrets.token_hex(32)}
    prepared: list[tuple[pathlib.Path, dict[str, object]]] = []
    old_ids: dict[str, str | None] | None = None
    for path in files:
        updated, observed_old, observed_new = rotate_identity(
            read_json(path),
            new_user_id=new_ids["userID"],
            new_machine_id=new_ids["machineID"],
        )
        if observed_new != new_ids:
            raise AssertionError("身份轮换生成了不一致的 ID")
        if path == paths.claude_json:
            old_ids = observed_old
        prepared.append((path, updated))
    for path, updated in prepared:
        atomic_write_json(path, updated)
    if old_ids is None:
        raise AssertionError("未处理主身份文件")
    return old_ids, new_ids, len(prepared) - 1


def tree_inventory(root: pathlib.Path) -> tuple[int, int]:
    count = 0
    size = 0
    for path in root.rglob("*"):
        count += 1
        try:
            if path.is_file() and not path.is_symlink():
                size += path.stat().st_size
        except FileNotFoundError:
            pass
    return count, size


def create_full_backup(paths: Paths) -> pathlib.Path:
    if not paths.claude_dir.is_dir():
        raise FileNotFoundError(f"全局目录不存在：{paths.claude_dir}")
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = paths.backup_root / f"claude-cleanup-{stamp}"
    destination.mkdir(parents=True, mode=0o700)
    os.chmod(destination, 0o700)
    copied_claude = destination / "dot-claude"
    shutil.copytree(paths.claude_dir, copied_claude, symlinks=True, copy_function=shutil.copy2)
    if paths.claude_json.exists():
        shutil.copy2(paths.claude_json, destination / "claude.json")
    source_inventory = tree_inventory(paths.claude_dir)
    backup_inventory = tree_inventory(copied_claude)
    if source_inventory != backup_inventory:
        raise RuntimeError(
            f"备份校验失败：source={source_inventory}, backup={backup_inventory}"
        )
    manifest = {
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source": str(paths.claude_dir),
        "items": source_inventory[0],
        "regularFileBytes": source_inventory[1],
        "claudeJsonCopied": paths.claude_json.exists(),
    }
    atomic_write_json(destination / "manifest.json", manifest)
    return destination


def protected_paths(paths: Paths) -> tuple[pathlib.Path, ...]:
    return tuple(paths.claude_dir / name for name in sorted(PROTECTED_CLAUDE_NAMES))


def is_within(path: pathlib.Path, parent: pathlib.Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(parent.resolve(strict=False))
        return True
    except ValueError:
        return False


def assert_deletion_allowed(path: pathlib.Path, paths: Paths) -> None:
    for protected in protected_paths(paths):
        if is_within(path, protected) or is_within(protected, path):
            raise RuntimeError(f"拒绝清理受保护路径：{path}（保护项：{protected}）")


def existing_desktop_paths(paths: Paths) -> list[pathlib.Path]:
    found = [paths.home / relative for relative in DESKTOP_RELATIVE_PATHS]
    for pattern in DESKTOP_GLOBS:
        found.extend(pathlib.Path(item) for item in glob.glob(str(paths.home / pattern)))
    unique = {item for item in found if item.exists() or item.is_symlink()}
    return sorted(unique, key=str)


def existing_cli_cache_paths(paths: Paths) -> list[pathlib.Path]:
    found = [paths.claude_dir / name for name in CLI_CACHE_NAMES]
    found.append(paths.home / "Library/Caches/claude-cli-nodejs")
    return [item for item in found if item.exists() or item.is_symlink()]


def trash_destination(source: pathlib.Path, paths: Paths, run_dir: pathlib.Path) -> pathlib.Path:
    try:
        relative = source.relative_to(paths.home)
        prefix = pathlib.Path("home")
    except ValueError:
        relative = pathlib.Path(*source.parts[1:])
        prefix = pathlib.Path("root")
    return run_dir / prefix / relative


def move_to_trash(source: pathlib.Path, paths: Paths, run_dir: pathlib.Path) -> pathlib.Path:
    assert_deletion_allowed(source, paths)
    destination = trash_destination(source, paths, run_dir)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise FileExistsError(f"废纸篓目标已存在：{destination}")
    shutil.move(str(source), str(destination))
    return destination


def current_timezone() -> str:
    localtime = pathlib.Path("/etc/localtime")
    try:
        target = os.path.realpath(localtime)
        marker = "/zoneinfo/"
        return target.split(marker, 1)[1] if marker in target else target
    except OSError:
        return "unknown"


def list_processes(pattern: str) -> list[str]:
    if shutil.which("pgrep") is None or shutil.which("ps") is None:
        return []
    pgrep = subprocess.run(
        ["pgrep", "-f", pattern],
        capture_output=True,
        text=True,
        check=False,
    )
    pids = [pid for pid in pgrep.stdout.split() if pid != str(os.getpid())]
    if not pids:
        return []
    result = subprocess.run(
        ["ps", "-p", ",".join(pids), "-o", "pid=,comm="],
        capture_output=True,
        text=True,
        check=False,
    )
    return [" ".join(line.split()) for line in result.stdout.splitlines() if line.strip()]


def list_desktop_processes() -> list[str]:
    return list_processes(r"/Applications/Claude\.app|Claude Helper")


def list_cli_processes() -> list[str]:
    return list_processes(r"(^|/)(claude)( |$)")


def ask_yes_no(prompt: str, *, default: bool = False) -> bool:
    suffix = "[Y/n]" if default else "[y/N]"
    while True:
        answer = input(f"{prompt} {suffix} ").strip().lower()
        if not answer:
            return default
        if answer in {"y", "yes", "是"}:
            return True
        if answer in {"n", "no", "否"}:
            return False
        print("请输入 y 或 n。")


def ask_choice(prompt: str, choices: dict[str, str], *, default: str) -> str:
    print(prompt)
    for key, text in choices.items():
        marker = "（默认）" if key == default else ""
        print(f"  {key}. {text}{marker}")
    while True:
        answer = input(f"选择 [{default}]: ").strip() or default
        if answer in choices:
            return answer
        print(f"请输入：{', '.join(choices)}")


def collect_plan(paths: Paths, settings: object) -> Plan:
    print("\n逐项选择。每项都只影响本项；未选择的内容保持原样。")
    rotate = ask_yes_no("轮换 ~/.claude.json 的本地 userID，并清除其中账号/cache 字段？")
    keychain = ask_yes_no("删除 macOS Keychain 的 Claude Code-credentials（会退出 CLI 登录）？")
    desktop = ask_choice(
        "Claude Desktop 清理范围：",
        {
            "0": "不清理桌面端",
            "1": "清理桌面端数据、缓存、日志和偏好设置；保留 /Applications/Claude.app",
            "2": "清理桌面端数据，并把 /Applications/Claude.app 一并移入废纸篓",
        },
        default="0",
    )
    cli_caches = ask_yes_no(
        "清理明确列出的 CLI cache/usage/failed-telemetry 文件？会话、skills、plugins、hooks 不在列表中。"
    )
    simple = ask_choice(
        "Claude Code 精简 system prompt：持久启用 CLAUDE_CODE_SIMPLE 会跳过 hooks、LSP、插件同步、auto-memory 等运行时加载，但不会删除它们。",
        {
            "0": "保持当前设置",
            "1": "在 settings.json 中启用 CLAUDE_CODE_SIMPLE=1",
            "2": "从 settings.json 删除 CLAUDE_CODE_SIMPLE，恢复完整模式",
        },
        default="0",
    )
    timezone = False
    if sys.platform == "darwin":
        timezone = ask_yes_no(
            f"当前时区是 {current_timezone()}。本 skill 建议使用 Asia/Taipei；是否修改？macOS 稍后会在终端安全地提示输入开机密码。",
            default=False,
        )
    return Plan(
        rotate_identity=rotate,
        delete_keychain=keychain,
        desktop_data=desktop in {"1", "2"},
        desktop_app=desktop == "2",
        clear_cli_caches=cli_caches,
        simple_prompt={"0": "preserve", "1": "enable", "2": "disable"}[simple],
        set_taipei_timezone=timezone,
    )


def print_audit(paths: Paths, settings: object) -> None:
    print("\n当前状态（只读）：")
    print(f"- ~/.claude：{'存在' if paths.claude_dir.is_dir() else '不存在'}")
    print(f"- ~/.claude.json：{'存在' if paths.claude_json.exists() else '不存在'}")
    print(f"- 遥测状态：{telemetry_status(settings)}；脚本将原样继承，不主动开关")
    print(f"- CLAUDE_CODE_SIMPLE：{env_from_settings(settings).get('CLAUDE_CODE_SIMPLE', '未设置')}")
    if sys.platform == "darwin":
        print(f"- macOS 时区：{current_timezone()}")
        print(f"- /Applications/Claude.app：{'存在' if pathlib.Path('/Applications/Claude.app').exists() else '不存在'}")
    desktop = existing_desktop_paths(paths)
    cli = existing_cli_cache_paths(paths)
    print(f"- 可选桌面端清理目标：{len(desktop)} 个现存路径")
    print(f"- 可选 CLI cache 清理目标：{len(cli)} 个现存路径")
    desktop_processes = list_desktop_processes()
    cli_processes = list_cli_processes()
    print(f"- 正在运行的 Claude Desktop 进程：{len(desktop_processes)} 个")
    print(f"- 正在运行的 Claude Code CLI 进程：{len(cli_processes)} 个")
    for process in desktop_processes + cli_processes:
        print(f"  - {process}")


def print_plan(paths: Paths, settings: object, plan: Plan) -> None:
    print("\n================ 最终执行清单 ================")
    print("第一项一定执行：")
    print(f"- 全量复制 {paths.claude_dir} 到 {paths.backup_root}/claude-cleanup-<时间戳>/dot-claude")
    print("- 同时备份 ~/.claude.json（如存在），并校验文件数量与普通文件字节数")
    print("- 备份可能含 token、会话和自定义配置；目录权限设为仅当前用户可访问")
    print("\n将修改：")
    if plan.rotate_identity:
        print("- ~/.claude.json：轮换 userID 和 machineID，删除代码中明确列出的账号/cache 字段；保留其他键")
        backup_count = len(identity_backup_files(paths))
        print(f"- ~/.claude/backups/.claude.json.backup.*：同步轮换 {backup_count} 份 JSON 备份，防止旧 ID 被恢复；不删除 backups 目录")
    if plan.delete_keychain:
        print("- macOS Keychain：删除 Claude Code-credentials")
    if plan.simple_prompt != "preserve":
        action = "启用" if plan.simple_prompt == "enable" else "移除"
        print(f"- ~/.claude/settings.json：{action} CLAUDE_CODE_SIMPLE；遥测相关键保持逐值不变")
    if plan.set_taipei_timezone:
        print("- macOS 系统时区：改为 Asia/Taipei；密码由 sudo 在终端隐藏输入，不会被脚本读取或保存")
    if not any((plan.rotate_identity, plan.delete_keychain, plan.simple_prompt != "preserve", plan.set_taipei_timezone)):
        print("- 无")
    print("\n将移入废纸篓（不会清空废纸篓）：")
    delete_targets: list[pathlib.Path] = []
    if plan.desktop_data:
        delete_targets.extend(existing_desktop_paths(paths))
    if plan.desktop_app and pathlib.Path("/Applications/Claude.app").exists():
        delete_targets.append(pathlib.Path("/Applications/Claude.app"))
    if plan.clear_cli_caches:
        delete_targets.extend(existing_cli_cache_paths(paths))
    if delete_targets:
        for target in delete_targets:
            print(f"- {target}")
    else:
        print("- 无")
    print("\n绝对不会删除：")
    print("- ~/.claude/projects、history.jsonl、file-history、debug、sessions")
    print("- ~/.claude/skills、plugins、hooks、commands、scripts、agents、mcp-servers")
    print("- ~/.claude/backups 目录本身（仅在选择本地 identity reset 时结构化修改其中匹配的 JSON 备份）")
    print("- ~/.claude/CLAUDE.md、settings*.json（settings.json 只可能做上面明确的结构化修改）")
    print("- 任何项目目录、Git 仓库、Codex 会话或未列出的路径")
    print(f"- 当前遥测状态：{telemetry_status(settings)}；保持不变")
    print("================================================")


def require_process_decision(plan: Plan) -> None:
    affected: list[str] = []
    if plan.desktop_data or plan.desktop_app:
        affected.extend(list_desktop_processes())
    if plan.rotate_identity or plan.delete_keychain or plan.clear_cli_caches:
        affected.extend(list_cli_processes())
    if affected:
        print("\n检测到会受所选操作影响的 Claude 进程：")
        for process in affected:
            print(f"- {process}")
        print("请人工正常退出会受本次操作影响的 Claude Desktop / Claude Code 会话。")
        input("处理完成后按 Enter 重新检查；输入不会被当作命令执行。")
        remaining_affected: list[str] = []
        if plan.desktop_data or plan.desktop_app:
            remaining_affected.extend(list_desktop_processes())
        if plan.rotate_identity or plan.delete_keychain or plan.clear_cli_caches:
            remaining_affected.extend(list_cli_processes())
        if remaining_affected:
            print("仍检测到受影响的 Claude 进程。为避免边写边清，脚本停止；尚未创建备份或修改文件。")
            raise SystemExit(2)

    live_processes = list_desktop_processes() + list_cli_processes()
    if live_processes:
        print("\n仍有不受所选操作直接影响的 Claude 进程在运行：")
        for process in live_processes:
            print(f"- {process}")
        print("它们可能在全量复制 ~/.claude 时写入新内容，因此备份不是严格的单一时间点快照。")
        confirmation = input(
            "建议先正常退出；若明确接受实时备份风险并继续，输入 LIVE BACKUP，其他输入取消："
        ).strip()
        if confirmation != "LIVE BACKUP":
            print("已取消，尚未创建备份或修改文件。")
            raise SystemExit(2)


def apply_plan(paths: Paths, settings: object, plan: Plan) -> None:
    require_process_decision(plan)
    protected_before = {
        path for path in protected_paths(paths) if path.exists() or path.is_symlink()
    }
    backup = create_full_backup(paths)
    print(f"\n[1/6] 全量备份完成并验证：{backup}")

    trash_run = paths.trash / f"claude-cleanup-{dt.datetime.now().strftime('%Y%m%d-%H%M%S-%f')}"
    moved: list[tuple[pathlib.Path, pathlib.Path]] = []

    targets: list[pathlib.Path] = []
    if plan.desktop_data:
        targets.extend(existing_desktop_paths(paths))
    if plan.desktop_app and pathlib.Path("/Applications/Claude.app").exists():
        targets.append(pathlib.Path("/Applications/Claude.app"))
    if plan.clear_cli_caches:
        targets.extend(existing_cli_cache_paths(paths))
    for target in targets:
        assert_deletion_allowed(target, paths)

    if plan.set_taipei_timezone:
        print("macOS 将先验证管理员权限。请在终端的隐藏提示中输入开机密码；脚本不会读取或保存密码。")
        input("准备好后按 Enter。")
        subprocess.run(["sudo", "-v"], check=True)

    if plan.rotate_identity:
        old_ids, new_ids, backup_count = rotate_identity_files(paths)
        old_user_id = old_ids["userID"] or "missing"
        print(
            f"[2/6] 本地 userID/machineID 已轮换：{old_user_id[:8]}… -> "
            f"{new_ids['userID'][:8]}…；同步更新 {backup_count} 份 Claude JSON 备份"
        )
    else:
        print("[2/6] 跳过本地 identity 修改")

    if plan.delete_keychain:
        result = subprocess.run(
            ["security", "delete-generic-password", "-a", os.environ.get("USER", ""), "-s", "Claude Code-credentials"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode not in {0, 44}:
            raise RuntimeError(f"Keychain 删除失败：{result.stderr.strip()}")
        print("[3/6] Keychain Claude Code-credentials 已处理")
    else:
        print("[3/6] 跳过 Keychain")

    for target in targets:
        destination = move_to_trash(target, paths, trash_run)
        moved.append((target, destination))
    print(f"[4/6] 已移入废纸篓：{len(moved)} 个路径")

    if plan.simple_prompt != "preserve":
        latest = read_json(paths.settings, default={})
        before = telemetry_snapshot(latest)
        updated_settings = update_simple_prompt(latest, plan.simple_prompt)
        atomic_write_json(paths.settings, updated_settings)
        after = telemetry_snapshot(read_json(paths.settings))
        if before != after:
            raise RuntimeError("settings 写入后遥测状态发生变化，已停止")
        print(f"[5/6] CLAUDE_CODE_SIMPLE：{plan.simple_prompt}；遥测键保持不变")
    else:
        print("[5/6] settings 保持不变")

    if plan.set_taipei_timezone:
        subprocess.run(["sudo", "systemsetup", "-settimezone", "Asia/Taipei"], check=True)
        if current_timezone() != "Asia/Taipei":
            raise RuntimeError(f"时区验证失败，当前是 {current_timezone()}")
        print("[6/6] 时区已验证为 Asia/Taipei")
    else:
        print("[6/6] 跳过时区修改")

    missing_protected = [
        protected
        for protected in sorted(protected_before, key=str)
        if not (protected.exists() or protected.is_symlink())
    ]
    if missing_protected:
        raise RuntimeError(
            "受保护路径验证失败：" + ", ".join(str(path) for path in missing_protected)
        )
    for source, _ in moved:
        if source.exists() or source.is_symlink():
            raise RuntimeError(f"清理验证失败，原路径仍存在：{source}")
    print("\n完成。全量备份和废纸篓内容均保留；未清空废纸篓。")
    print(f"备份：{backup}")
    if moved:
        print(f"废纸篓批次：{trash_run}")


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="安全审计和清理本机 Claude Code / Desktop 数据")
    parser.add_argument("--audit", action="store_true", help="只读审计，不提问、不修改")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)
    paths = Paths(pathlib.Path.home())
    settings = read_json(paths.settings, default={})
    print("Claude Cleanup 将先审计，再逐项询问，最后展示精确执行清单。")
    print("在你输入最终 CONFIRM 前，不会创建备份、修改设置、删除凭据或移动任何文件。")
    print("脚本没有静默确认参数；所有删除只会进入废纸篓。")
    print_audit(paths, settings)
    if args.audit:
        return 0
    if not sys.stdin.isatty():
        print("拒绝执行：交互式确认需要 TTY。可使用 --audit 做只读检查。", file=sys.stderr)
        return 2
    plan = collect_plan(paths, settings)
    print_plan(paths, settings, plan)
    confirmation = input("完全理解上述范围后，输入 CONFIRM 正式开始；其他任何输入都会取消：").strip()
    if confirmation != "CONFIRM":
        print("已取消，没有修改任何内容。")
        return 1
    apply_plan(paths, settings, plan)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
