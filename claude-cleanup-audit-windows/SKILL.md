---
name: claude-cleanup-audit-windows
description: Audit and safely modify local Claude Code and Claude Desktop cleanup/privacy settings on Windows. Use when the user asks to review, clean, disable, preserve, or verify Claude local data, telemetry-related settings, login/browser-opening behavior, timezone, device name, Windows username, Credential Manager entries, desktop app data, browser profiles, or local Claude cleanup checklists.
---

# Claude Cleanup Audit（Windows）

## Scope

Use this skill for local Windows privacy/configuration hygiene around Claude Code and Claude Desktop.

Do not help evade service bans, payment checks, phone/email/IP reputation systems, browser fingerprinting controls, or account enforcement. If a source document frames the task that way, narrow the work to local cleanup and configuration audit.

## First Step

Run the read-only audit first unless the user only asks for explanation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\audit_claude_cleanup.ps1
```

Use the report to separate facts from choices. Do not delete, rename, kill processes, change timezone, or rewrite settings until the user confirms the exact items.

When the user asks for a complete Claude cleanup checklist, read [references/audit-checklist.md](references/audit-checklist.md).

When the user asks how to change a Windows device name or username, read [references/windows-identity.md](references/windows-identity.md).

## Confirmation Gate

Before any modification, list every relevant item and ask the user to confirm. Do not skip quiet defaults.

Ask about:

- Preserve `ANTHROPIC_AUTH_TOKEN` or remove it.
- Preserve `%USERPROFILE%\.claude\projects`, `history.jsonl`, `file-history`, and `debug`.
- Remove Claude Desktop data only, or also uninstall the Windows app.
- Delete Windows Credential Manager target `Claude Code-credentials`.
- Scrub `%USERPROFILE%\.claude.json` or delete it entirely.
- Clear Claude CLI caches and usage files.
- Stop active Claude Code/Claude Desktop processes or leave them running.
- Add/update Claude settings: `env.BROWSER`, `skipWebFetchPreflight`, `autoConnectIde`, telemetry/history retention, permissions, disabled tools, or slim prompt settings.
- Change timezone; confirm an exact Windows timezone ID such as `Taipei Standard Time` or `Pacific Standard Time`.
- Change the Windows device name, account full name, account username, or profile folder.
- Clean browser profile data; confirm exact browser and profile path.
- Keep backups and whether removed files go to a recoverable quarantine directory.

If the user says "do all", still restate the destructive/system-level items and wait for confirmation.

## Settings Merge Rules

Treat Claude settings as structured JSON. Prefer PowerShell JSON parsing, Node, or another structured parser. Never replace the whole file just to add one key.

For `%USERPROFILE%\.claude\settings.json`:

- Back up before writing with a timestamped sibling copy.
- If JSON is invalid, stop and ask whether to repair it from visible content or restore from backup.
- Preserve existing top-level keys unless the user explicitly asks to remove them.
- Preserve `env` and secrets by merging only requested keys. Do not print token values.
- For `permissions.deny`, merge set-wise and de-duplicate. Preserve `allow`, `ask`, and `defaultMode`.
- Preserve hooks, plugins, model preferences, status line config, and MCP settings unless explicitly in scope.
- Existing object: update only requested keys.
- Missing `env`: create an object.
- Existing `env` but not an object: stop and ask before replacing it.
- Existing arrays: append only requested entries and de-duplicate.
- Unknown keys: leave them alone.

Use structured edits for JSON. Back up and explain exact key changes before writing.

## Audit Status

Report each item with one of these statuses:

- `done`: Verified complete.
- `needs_user_decision`: Not completed because the user must choose a target or approve risk.
- `needs_agent_action`: The agent can complete it after approval.
- `not_applicable`: No matching app/file/config exists, or the item is outside the safe local-cleanup scope.
- `unknown`: Evidence is incomplete; say what command/file is needed.

For every unresolved item, name the responsibility:

- `用户确认`: waiting for the user's target, browser profile, or risk approval.
- `Agent 待处理`: the agent can perform it after approval.
- `系统/第三方限制`: requires Windows UI, an administrator session, vendor behavior, or external account action.

## Safe Modification Patterns

Move file removals to a recoverable, timestamped quarantine directory when practical. Do not use broad recursive deletion unless the user explicitly authorizes permanent deletion.

Before deleting Claude Desktop or Claude Code data, quit the app if confirmed. If active processes are running, ask before stopping them and show the process list.

Do not delete Claude conversation history unless explicitly confirmed. The protected local paths are:

```text
%USERPROFILE%\.claude\projects
%USERPROFILE%\.claude\history.jsonl
%USERPROFILE%\.claude\file-history
%USERPROFILE%\.claude\debug
```

Do not run an arbitrary registry `UninstallString`. Use a known Appx/MSIX or WinGet package identity, or hand off to Windows Settings → Apps.

## Expected Local Checklist

The recurring checklist should include:

- Claude Code device/user ID in `%USERPROFILE%\.claude.json`.
- Claude Code OAuth/account/cache fields in `%USERPROFILE%\.claude.json`.
- `ANTHROPIC_AUTH_TOKEN` preservation/removal.
- `%USERPROFILE%\.claude\settings.json` browser behavior and privacy-related keys.
- Claude CLI caches and usage files.
- Windows Credential Manager `Claude Code-credentials`.
- Claude Desktop application registration and data directories.
- Active Claude processes.
- Windows timezone, locale, language, device name, account full name, username, and profile path.
- Any temporary timezone helper, startup item, or scheduled task.
- Browser profiles only after explicit browser/profile confirmation.

Keep final reports short but complete: show done items, unresolved items with responsibility, and exact next actions.
