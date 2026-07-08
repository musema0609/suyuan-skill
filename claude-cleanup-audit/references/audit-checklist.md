# Claude Cleanup Audit Checklist

Use this reference when a user asks for a complete Claude Code or Claude Desktop local cleanup review. Keep the work limited to local privacy/configuration hygiene unless the user asks for a harmless explanation.

## Claude Code Identity And Account Data

- Check `~/.claude.json` exists and is valid JSON.
- Check `userID` presence. If rotating it, back up first and generate a new random 64-character hex value.
- Check account/cache-style fields such as OAuth account data, anonymous IDs, Statsig/GrowthBook cache, dynamic config cache, subscription/cache metadata, and client cache keys.
- Ask whether to scrub these fields or delete the whole file.
- Preserve user-requested tokens such as `ANTHROPIC_AUTH_TOKEN` unless the user explicitly asks to remove them.

## Claude Code Settings

- Check `~/.claude/settings.json` exists and is valid JSON.
- Merge settings structurally; never replace the entire file for a small change.
- Check whether `env.BROWSER="/usr/bin/false"` is desired to prevent CLI login from opening the default browser automatically.
- Check `skipWebFetchPreflight`, `autoConnectIde`, privacy-related env toggles, prompt-history retention, and optional tool denies.
- Preserve existing `env`, hooks, MCP settings, model preferences, status line config, and permissions unless explicitly in scope.

## Claude Code Data Preservation

- Ask before deleting any chat or project history.
- Treat these as protected unless the user explicitly confirms deletion:
  - `~/.claude/projects`
  - `~/.claude/history.jsonl`
  - `~/.claude/file-history`
  - `~/.claude/debug`
- Check and optionally clear CLI caches and usage files:
  - `~/Library/Caches/claude-cli-nodejs`
  - `~/.claude/cache`
  - `~/.claude/stats-cache.json`
  - `~/.claude/usage-data`
  - `~/.claude/usage.jsonl`
  - `~/.claude/usage.with-fix.jsonl`

## macOS Keychain And Processes

- Check macOS Keychain item `Claude Code-credentials`.
- Ask before deleting it.
- List active Claude Code or Claude Desktop processes.
- Ask before killing processes because running sessions may lose state.

## Claude Desktop

- Identify whether `/Applications/Claude.app` exists.
- Identify bundle ID when present.
- Ask whether to clear only app data/cache or also remove the app bundle.
- Check common Desktop data locations:
  - `~/Library/Application Support/Claude`
  - `~/Library/Application Support/Claude-3p`
  - `~/Library/Application Support/com.anthropic.claudefordesktop`
  - `~/Library/Preferences/com.anthropic.claudefordesktop.plist`
  - `~/Library/Preferences/ByHost/com.anthropic.claudefordesktop*.plist`
  - `~/Library/HTTPStorages/com.anthropic.claudefordesktop`
  - `~/Library/Logs/Claude`
  - `~/Library/Caches/com.anthropic.claudefordesktop`
  - `~/Library/Caches/com.anthropic.claudefordesktop.ShipIt`
  - `~/Library/Saved Application State/com.anthropic.claudefordesktop.savedState`
  - `~/Library/WebKit/com.anthropic.claudefordesktop`

## macOS Identity And Region

- Check timezone, locale, language, device name, host names, account full name, and account short name.
- Do not change system identity values without target values and explicit approval.
- For username/home-folder changes, require backup and a second admin account.

## Browser Profiles

- Do not guess browser profiles.
- Ask for exact browser and profile path before clearing cookies, local storage, or web data.
- Explain that this skill handles local cleanup only, not fingerprint bypass.

## Reporting

For each item, report status and responsibility:

- `done`: verified complete.
- `needs_user_decision`: the user must choose a target or approve risk.
- `needs_agent_action`: the agent can complete it after approval.
- `not_applicable`: no matching file/app exists, or the item is outside local cleanup scope.
- `unknown`: evidence is incomplete.

For unresolved items, assign responsibility as `用户确认`, `Agent 待处理`, or `系统/第三方限制`.
