# Claude Cleanup Audit Checklist for Windows

Use this reference when a user asks for a complete Claude Code or Claude Desktop local cleanup review. Keep the work limited to local privacy/configuration hygiene unless the user asks for a harmless explanation.

## Claude Code Identity And Account Data

- Check `%USERPROFILE%\.claude.json` exists and is valid JSON.
- Check `userID` presence. If rotating it, back up first and generate a new random 64-character hex value.
- Check account/cache-style fields such as OAuth account data, anonymous IDs, Statsig/GrowthBook cache, dynamic config cache, subscription/cache metadata, and client cache keys.
- Ask whether to scrub these fields or delete the whole file.
- Preserve user-requested tokens such as `ANTHROPIC_AUTH_TOKEN` unless the user explicitly asks to remove them.

## Claude Code Settings

- Check `%USERPROFILE%\.claude\settings.json` exists and is valid JSON.
- Merge settings structurally; never replace the entire file for a small change.
- Check `env.BROWSER`. On native Windows, do not invent a macOS-style `/usr/bin/false` replacement; either preserve an explicit browser executable or use Claude's manual copy-login flow.
- Check `skipWebFetchPreflight`, `autoConnectIde`, privacy-related env toggles, prompt-history retention, and optional tool denies.
- Preserve existing `env`, hooks, MCP settings, model preferences, status line config, and permissions unless explicitly in scope.
- Check `%ProgramFiles%\ClaudeCode\managed-settings.json` as read-only managed policy; do not modify it without administrator/IT authority.

## Claude Code Data Preservation

- Ask before deleting any chat or project history.
- Treat these as protected unless the user explicitly confirms deletion:
  - `%USERPROFILE%\.claude\projects`
  - `%USERPROFILE%\.claude\history.jsonl`
  - `%USERPROFILE%\.claude\file-history`
  - `%USERPROFILE%\.claude\debug`
- Check and optionally clear CLI caches and usage files:
  - `%USERPROFILE%\.claude\cache`
  - `%USERPROFILE%\.claude\stats-cache.json`
  - `%USERPROFILE%\.claude\telemetry`
  - `%USERPROFILE%\.claude\usage-data`
  - `%USERPROFILE%\.claude\usage.jsonl`
  - `%USERPROFILE%\.claude\usage.with-fix.jsonl`
  - `%LOCALAPPDATA%\Claude\Cache`
  - `%LOCALAPPDATA%\Claude\Code Cache`
  - `%LOCALAPPDATA%\Claude\GPUCache`

## Windows Credentials And Processes

- Check `%USERPROFILE%\.claude\.credentials.json` without displaying secret material. On current Windows Claude Code this is the primary OAuth credential store.
- Check cleanup backups for readable `dot-claude\.credentials.json` copies and distinguish them from DPAPI-protected `credentials.json.dpapi` files.
- Check the legacy Windows Credential Manager target `Claude Code-credentials` without displaying secret material.
- Ask before deleting it.
- List active Claude Code or Claude Desktop processes using process name and executable command line.
- Ask before stopping processes because running sessions may lose state.

## Claude Desktop

- Identify Appx/MSIX packages, WinGet package `Anthropic.Claude`, registered installed apps, and known per-user install directories.
- Ask whether to clear only app data/cache or also uninstall the app.
- Do not run an arbitrary registry `UninstallString`; use a verified package ID or Windows Settings → Apps.
- Check common Desktop data locations:
  - `%APPDATA%\Claude`
  - `%LOCALAPPDATA%\Claude`
  - `%LOCALAPPDATA%\Anthropic\Claude`
  - matching Claude package directories under `%LOCALAPPDATA%\Packages`
  - `%LOCALAPPDATA%\CrashDumps\Claude*.dmp`

## Windows Identity And Region

- Check timezone, culture, language list, system locale, computer name, account full name, username, and profile path.
- Do not change system identity values without target values and explicit approval.
- For username/profile-folder changes, require a backup and a second administrator account.
- Treat `C:\Program Files\ClaudeCode` as managed configuration, not user cleanup data.

## WSL

- Native Windows and every WSL distribution are separate installations and home directories.
- Audit WSL only when the user confirms the target distribution.
- Do not pass Windows paths to Linux deletion commands or Linux paths to Windows deletion commands.

## Browser Profiles

- Do not guess browser profiles.
- Ask for the exact browser and profile path before clearing cookies, local storage, or web data.
- Explain that this skill handles local cleanup only, not fingerprint bypass.

## Reporting

For each item, report status and responsibility:

- `done`: verified complete.
- `needs_user_decision`: the user must choose a target or approve risk.
- `needs_agent_action`: the agent can complete it after approval.
- `not_applicable`: no matching file/app exists, or the item is outside local cleanup scope.
- `unknown`: evidence is incomplete.

For unresolved items, assign responsibility as `用户确认`, `Agent 待处理`, or `系统/第三方限制`.
