#!/usr/bin/env python3
"""Read-only audit for local Claude cleanup/configuration on macOS."""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


HOME = Path.home()


def run(cmd: list[str], timeout: int = 8) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as exc:  # pragma: no cover - defensive CLI behavior
        return 999, "", str(exc)


def load_json(path: Path) -> tuple[Any | None, str | None]:
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except Exception as exc:
        return None, str(exc)


def redact(value: Any) -> str:
    text = str(value)
    if not text:
        return "<empty>"
    if len(text) <= 12:
        return "<redacted>"
    return f"{text[:6]}...{text[-4:]}"


def status_item(
    items: list[dict[str, str]],
    item_id: str,
    title: str,
    status: str,
    responsibility: str,
    evidence: str,
    next_action: str = "",
) -> None:
    items.append(
        {
            "id": item_id,
            "title": title,
            "status": status,
            "responsibility": responsibility,
            "evidence": evidence,
            "next_action": next_action,
        }
    )


def path_state(paths: list[Path]) -> tuple[list[str], list[str]]:
    present: list[str] = []
    absent: list[str] = []
    for path in paths:
        if path.exists():
            present.append(str(path))
        else:
            absent.append(str(path))
    return present, absent


def glob_present(patterns: list[str]) -> list[str]:
    found: list[str] = []
    for pattern in patterns:
        found.extend(glob.glob(os.path.expanduser(pattern)))
    return sorted(found)


def latest_path(paths: list[str]) -> str:
    if not paths:
        return ""
    return max(paths, key=lambda p: Path(p).stat().st_mtime if Path(p).exists() else 0)


def read_timezone() -> tuple[str, str]:
    code, out, err = run(["systemsetup", "-gettimezone"])
    if code == 0 and "Time Zone:" in out:
        timezone = out.replace("Time Zone:", "").strip()
        if timezone and "administrator access" not in timezone.lower():
            return timezone, out

    code, out, err = run(["readlink", "/etc/localtime"])
    if code == 0 and "zoneinfo/" in out:
        timezone = out.split("zoneinfo/", 1)[1].strip()
        return timezone, f"/etc/localtime -> {out}"
    return "", err or out


def parse_real_name(dscl_output: str) -> str:
    lines = dscl_output.splitlines()
    if not lines:
        return ""
    first = lines[0].strip()
    if first.startswith("RealName:"):
        inline = first.removeprefix("RealName:").strip()
        if inline:
            return inline
    return " ".join(line.strip() for line in lines[1:] if line.strip())


def audit(args: argparse.Namespace) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []

    timezone, timezone_evidence = read_timezone()
    if args.expected_timezone is None and timezone:
        status_item(items, "timezone", "macOS timezone", "done", "已验证", timezone_evidence)
    elif timezone == args.expected_timezone:
        status_item(items, "timezone", "macOS timezone", "done", "已验证", timezone_evidence)
    elif timezone:
        status_item(
            items,
            "timezone",
            "macOS timezone",
            "needs_user_decision",
            "用户确认",
            f"current={timezone}, expected={args.expected_timezone}",
            "Confirm whether to change timezone.",
        )
    else:
        status_item(items, "timezone", "macOS timezone", "unknown", "系统/第三方限制", timezone_evidence)

    name_values: list[str] = []
    for label, cmd in [
        ("ComputerName", ["scutil", "--get", "ComputerName"]),
        ("LocalHostName", ["scutil", "--get", "LocalHostName"]),
        ("HostName", ["scutil", "--get", "HostName"]),
    ]:
        code, out, err = run(cmd)
        name_values.append(f"{label}={out if code == 0 else '<empty>'}")
    code, out, _ = run(["id", "-un"])
    short_user = out if code == 0 else os.environ.get("USER", "")
    real_name = ""
    if short_user:
        code, out, _ = run(["dscl", ".", "-read", f"/Users/{short_user}", "RealName"])
        real_name = parse_real_name(out) if code == 0 else ""
    name_values.extend([f"User={short_user}", f"FullName={real_name or '<empty>'}"])
    status_item(
        items,
        "mac-identity",
        "Mac device and account names",
        "needs_user_decision",
        "用户确认",
        "; ".join(name_values),
        "If this matters, confirm target ComputerName/LocalHostName/FullName/short username.",
    )

    code, locale, _ = run(["defaults", "read", "-g", "AppleLocale"])
    code_lang, languages, _ = run(["defaults", "read", "-g", "AppleLanguages"])
    status_item(
        items,
        "locale-language",
        "macOS locale and languages",
        "needs_user_decision",
        "用户确认",
        f"AppleLocale={locale if locale else '<unknown>'}; AppleLanguages={languages if code_lang == 0 else '<unknown>'}",
        "Confirm whether locale/language should be changed.",
    )

    settings_path = HOME / ".claude" / "settings.json"
    settings, settings_error = load_json(settings_path) if settings_path.exists() else (None, "missing")
    if isinstance(settings, dict):
        status_item(items, "settings-json", "Claude settings JSON", "done", "已验证", str(settings_path))
        env = settings.get("env", {})
        if isinstance(env, dict):
            browser = env.get("BROWSER")
            if browser == "/usr/bin/false":
                status_item(items, "settings-browser", "Disable auto browser open", "done", "已验证", 'env.BROWSER="/usr/bin/false"')
            else:
                status_item(
                    items,
                    "settings-browser",
                    "Disable auto browser open",
                    "needs_agent_action",
                    "Agent 待处理",
                    f"env.BROWSER={browser!r}",
                    'Set env.BROWSER to "/usr/bin/false" after confirmation.',
                )
            token_present = bool(env.get("ANTHROPIC_AUTH_TOKEN") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))
            status_item(
                items,
                "auth-token",
                "ANTHROPIC_AUTH_TOKEN",
                "done" if token_present else "not_applicable",
                "已验证" if token_present else "不适用",
                "present, value redacted" if token_present else "not present in settings env or process env",
            )
        else:
            status_item(items, "settings-env", "Claude settings env object", "needs_user_decision", "用户确认", "env exists but is not an object")
        if settings.get("skipWebFetchPreflight") is True:
            status_item(items, "skip-webfetch", "skipWebFetchPreflight", "done", "已验证", "true")
        else:
            status_item(
                items,
                "skip-webfetch",
                "skipWebFetchPreflight",
                "needs_agent_action",
                "Agent 待处理",
                f"value={settings.get('skipWebFetchPreflight')!r}",
                "Set to true after confirmation.",
            )
        if settings.get("autoConnectIde") is False:
            status_item(items, "auto-connect-ide", "autoConnectIde", "done", "已验证", "false")
        else:
            status_item(
                items,
                "auto-connect-ide",
                "autoConnectIde",
                "needs_user_decision",
                "用户确认",
                f"value={settings.get('autoConnectIde')!r}",
                "Confirm whether Claude should auto-connect to IDE integrations.",
            )
        if isinstance(env, dict):
            privacy_env_keys = [
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
                "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
                "CLAUDE_CODE_DISABLE_TERMINAL_TITLE",
            ]
            present_privacy = [key for key in privacy_env_keys if key in env]
            status_item(
                items,
                "privacy-env",
                "Claude privacy-related env toggles",
                "done" if present_privacy else "needs_user_decision",
                "已验证" if present_privacy else "用户确认",
                "present: " + ", ".join(present_privacy) if present_privacy else "none of the common privacy env toggles found",
                "Confirm desired env toggles." if not present_privacy else "",
            )
        denied_tools = [
            "NotebookEdit",
            "CronCreate",
            "CronDelete",
            "CronList",
            "PushNotification",
            "RemoteTrigger",
            "ScheduleWakeup",
            "DesignSync",
        ]
        permissions = settings.get("permissions", {})
        deny = permissions.get("deny", []) if isinstance(permissions, dict) else []
        deny_set = set(deny) if isinstance(deny, list) else set()
        missing_denies = [tool for tool in denied_tools if tool not in deny_set]
        status_item(
            items,
            "disabled-tools",
            "Optional disabled Claude tools",
            "done" if not missing_denies else "needs_user_decision",
            "已验证" if not missing_denies else "用户确认",
            "all expected tools in permissions.deny"
            if not missing_denies
            else "missing from permissions.deny: " + ", ".join(missing_denies),
            "Confirm whether to add these tools to permissions.deny." if missing_denies else "",
        )
        if args.expect_slimming:
            slim_keys = ["disableBundledSkills", "disableWorkflows"]
            present = {key: settings.get(key) for key in slim_keys if key in settings}
            status_item(
                items,
                "slimming-config",
                "Claude slimming config",
                "done" if present else "needs_agent_action",
                "已验证" if present else "Agent 待处理",
                json.dumps(present, ensure_ascii=False) if present else "requested but no known slimming keys found",
            )
        else:
            status_item(items, "slimming-config", "Claude slimming config", "not_applicable", "不适用", "not expected by current checklist")
    else:
        status_item(items, "settings-json", "Claude settings JSON", "unknown", "Agent 待处理", settings_error or "missing")

    claude_json_path = HOME / ".claude.json"
    claude_json, claude_json_error = load_json(claude_json_path) if claude_json_path.exists() else (None, "missing")
    if isinstance(claude_json, dict):
        user_id = claude_json.get("userID")
        status_item(
            items,
            "claude-json-userid",
            "~/.claude.json userID",
            "done" if user_id else "needs_agent_action",
            "已验证" if user_id else "Agent 待处理",
            f"userID={redact(user_id)}" if user_id else "missing",
        )
        sensitive_patterns = [
            "oauth",
            "anonymous",
            "statsig",
            "growthbook",
            "cache",
            "dynamic",
            "subscription",
            "billing",
            "entitlement",
            "client",
        ]
        remaining = [
            key
            for key in claude_json.keys()
            if any(pattern in key.lower() for pattern in sensitive_patterns)
        ]
        status_item(
            items,
            "claude-json-scrub",
            "~/.claude.json account/cache scrub",
            "done" if not remaining else "needs_agent_action",
            "已验证" if not remaining else "Agent 待处理",
            "no matching top-level account/cache keys" if not remaining else "remaining keys: " + ", ".join(remaining),
        )
    else:
        status_item(items, "claude-json", "~/.claude.json", "unknown", "Agent 待处理", claude_json_error or "missing")
    backups = glob_present(["~/.claude.json.bak-*"])
    status_item(
        items,
        "claude-json-backup",
        "~/.claude.json backup",
        "done" if backups else "needs_agent_action",
        "已验证" if backups else "Agent 待处理",
        latest_path(backups) if backups else "no backup found",
    )

    protected = [
        HOME / ".claude" / "projects",
        HOME / ".claude" / "history.jsonl",
        HOME / ".claude" / "file-history",
        HOME / ".claude" / "debug",
    ]
    present, absent = path_state(protected)
    status_item(
        items,
        "claude-history-preserved",
        "Claude Code history/project paths preserved",
        "done" if present else "unknown",
        "已验证" if present else "用户确认",
        "present: " + ", ".join(present) + ("; absent: " + ", ".join(absent) if absent else ""),
    )

    cli_cache_paths = [
        HOME / "Library" / "Caches" / "claude-cli-nodejs",
        HOME / ".claude" / "cache",
        HOME / ".claude" / "stats-cache.json",
        HOME / ".claude" / "usage-data",
        HOME / ".claude" / "usage.jsonl",
        HOME / ".claude" / "usage.with-fix.jsonl",
    ]
    present, _ = path_state(cli_cache_paths)
    status_item(
        items,
        "claude-cli-cache",
        "Claude CLI caches/usage files",
        "done" if not present else "needs_agent_action",
        "已验证" if not present else "Agent 待处理",
        "all target paths absent" if not present else "still present: " + ", ".join(present),
    )

    code, out, err = run(["security", "find-generic-password", "-s", "Claude Code-credentials"])
    status_item(
        items,
        "keychain-credentials",
        "Keychain Claude Code-credentials",
        "done" if code != 0 else "needs_agent_action",
        "已验证" if code != 0 else "Agent 待处理",
        "not found" if code != 0 else "found",
    )

    desktop_app = Path("/Applications/Claude.app")
    if args.expect_desktop_app == "removed":
        status_item(
            items,
            "desktop-app",
            "/Applications/Claude.app",
            "done" if not desktop_app.exists() else "needs_agent_action",
            "已验证" if not desktop_app.exists() else "Agent 待处理",
            "absent" if not desktop_app.exists() else "present",
        )
    else:
        status_item(
            items,
            "desktop-app",
            "/Applications/Claude.app",
            "done" if desktop_app.exists() else "not_applicable",
            "已验证" if desktop_app.exists() else "不适用",
            "present" if desktop_app.exists() else "absent",
        )

    desktop_data_paths = [
        HOME / "Library" / "Application Support" / "Claude",
        HOME / "Library" / "Application Support" / "Claude-3p",
        HOME / "Library" / "Application Support" / "com.anthropic.claudefordesktop",
        HOME / "Library" / "Preferences" / "com.anthropic.claudefordesktop.plist",
        HOME / "Library" / "HTTPStorages" / "com.anthropic.claudefordesktop",
        HOME / "Library" / "Logs" / "Claude",
        HOME / "Library" / "Caches" / "com.anthropic.claudefordesktop",
        HOME / "Library" / "Caches" / "com.anthropic.claudefordesktop.ShipIt",
        HOME / "Library" / "Saved Application State" / "com.anthropic.claudefordesktop.savedState",
        HOME / "Library" / "WebKit" / "com.anthropic.claudefordesktop",
    ]
    desktop_globs = [
        "~/Library/Preferences/ByHost/com.anthropic.claudefordesktop*.plist",
        "~/Library/Application Support/CrashReporter/claude_*.plist",
    ]
    present, _ = path_state(desktop_data_paths)
    present.extend(glob_present(desktop_globs))
    status_item(
        items,
        "desktop-data",
        "Claude Desktop data/cache paths",
        "done" if not present else "needs_agent_action",
        "已验证" if not present else "Agent 待处理",
        "all target paths absent" if not present else "still present: " + ", ".join(sorted(present)),
    )

    gmt_paths = [
        HOME / "Library" / "LaunchAgents" / "com.codex.gmt8-clock.plist",
        HOME / "Applications" / "GMT8Clock.app",
        HOME / "GMT8Clock.app",
    ]
    present, _ = path_state(gmt_paths)
    uid = str(os.getuid())
    code, out, err = run(["launchctl", "print", f"gui/{uid}/com.codex.gmt8-clock"])
    loaded = code == 0
    status_item(
        items,
        "gmt8clock",
        "GMT8Clock helper",
        "done" if not present and not loaded else "needs_agent_action",
        "已验证" if not present and not loaded else "Agent 待处理",
        "not installed and launch agent not loaded" if not present and not loaded else "present/loaded",
    )

    code, out, err = run(["ps", "axo", "pid=,comm=,args="])
    claude_processes: list[str] = []
    if code == 0:
        for line in out.splitlines():
            lower = line.lower()
            if "audit_claude_cleanup.py" in lower:
                continue
            if "claude" in lower and ("anthropic" in lower or "/claude" in lower or " claude " in lower):
                claude_processes.append(line.strip())
    status_item(
        items,
        "active-processes",
        "Active Claude processes",
        "needs_user_decision" if claude_processes else "done",
        "用户确认" if claude_processes else "已验证",
        "\n".join(claude_processes[:8]) if claude_processes else "none found",
        "Ask before killing active processes." if claude_processes else "",
    )

    status_item(
        items,
        "browser-profiles",
        "Browser profile cleanup",
        "needs_user_decision",
        "用户确认",
        "not checked without exact browser/profile path",
        "Confirm browser and profile before touching browser data.",
    )

    status_item(
        items,
        "external-identity",
        "Payment/IP/phone/email/fingerprint evasion",
        "not_applicable",
        "系统/第三方限制",
        "outside local cleanup scope",
        "Do not provide bypass instructions; limit work to local privacy/config audit.",
    )

    return items


def print_markdown(items: list[dict[str, str]]) -> None:
    counts: dict[str, int] = {}
    for item in items:
        counts[item["status"]] = counts.get(item["status"], 0) + 1
    print("# Claude Cleanup Audit\n")
    print("## Summary\n")
    print(", ".join(f"{key}={value}" for key, value in sorted(counts.items())))
    print("\n## Items\n")
    for item in items:
        print(f"- [{item['status']}] {item['title']}")
        print(f"  - responsibility: {item['responsibility']}")
        print(f"  - evidence: {item['evidence']}")
        if item["next_action"]:
            print(f"  - next: {item['next_action']}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Read-only Claude cleanup audit")
    parser.add_argument("--expected-timezone", default=None, help="Optional IANA timezone to compare against, for example Asia/Singapore")
    parser.add_argument("--expect-desktop-app", choices=["removed", "present"], default="removed")
    parser.add_argument("--expect-slimming", action="store_true")
    parser.add_argument("--json", action="store_true", dest="json_output")
    parser.add_argument("--fail-on-unresolved", action="store_true")
    args = parser.parse_args()

    items = audit(args)
    if args.json_output:
        print(json.dumps(items, ensure_ascii=False, indent=2))
    else:
        print_markdown(items)

    if args.fail_on_unresolved and any(
        item["status"] in {"needs_user_decision", "needs_agent_action", "unknown"} for item in items
    ):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
