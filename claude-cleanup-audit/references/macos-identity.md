# macOS Device And User Name Changes

Use these steps only after the user confirms exact target names. Treat account short-name changes as risky because they can break home-directory paths, app licenses, shell config, and keychain assumptions.

## Confirm First

Ask for:

- New `ComputerName`, the visible Mac name. Spaces are allowed.
- New `LocalHostName`, the Bonjour/local network name. Use ASCII letters, digits, and hyphens.
- Whether to set `HostName`. Usually leave it empty unless the user knows they need it.
- Whether to change only the account full name or also the short username/home folder.
- Whether the user has a full backup and a second admin account.

## Device Name

Read current values:

```bash
scutil --get ComputerName
scutil --get LocalHostName
scutil --get HostName 2>/dev/null || true
```

Set values:

```bash
sudo scutil --set ComputerName "New Mac Name"
sudo scutil --set LocalHostName "new-mac-name"
sudo scutil --set HostName "new-mac-name.local"   # optional
dscacheutil -flushcache
```

UI path on recent macOS: System Settings -> General -> Sharing -> Local hostname / computer name.

## Account Full Name

This is safer than changing the short username.

UI path: System Settings -> Users & Groups -> click the user info button -> Full Name.

Verify:

```bash
id -un
dscl . -read /Users/$(id -un) RealName
```

## Short Username And Home Folder

Recommend UI flow instead of command-line edits:

1. Make a full backup.
2. Create a temporary second administrator account.
3. Log out of the target user.
4. Log in as the temporary administrator.
5. Rename `/Users/oldname` to `/Users/newname`.
6. Open System Settings -> Users & Groups.
7. Open Advanced Options for the target account.
8. Change `Account name` to `newname`.
9. Change `Home directory` to `/Users/newname`.
10. Do not change UID unless the user explicitly knows why.
11. Restart, log in to the renamed account, and verify shell, keychain, dev tools, and app paths.

If the user is currently logged in as the account being renamed, stop and ask them to use a second admin session.

## Timezone And Locale

Read:

```bash
systemsetup -gettimezone
defaults read -g AppleLocale
defaults read -g AppleLanguages
```

Set timezone examples:

```bash
sudo systemsetup -settimezone Asia/Singapore
sudo systemsetup -settimezone America/Los_Angeles
```

Locale/language are usually safer through System Settings -> General -> Language & Region.
