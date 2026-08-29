# Windows Device And User Name Changes

Use these steps only after the user confirms exact target names. Treat account username and profile-folder changes as risky because they can break profile paths, application registrations, shell configuration, credentials, ACLs, scheduled tasks, and licenses.

## Confirm First

Ask for:

- New Windows computer name. Use 15 or fewer ASCII letters, digits, and hyphens when legacy network compatibility matters.
- Whether to change only the account display/full name or also the username and profile folder.
- Whether the machine is joined to Microsoft Entra ID, Active Directory, or managed by an organization.
- Whether the user has a full backup, recovery key if device encryption is enabled, and a second administrator account.
- Exact Windows timezone ID if changing timezone.

## Device Name

Read current values:

```powershell
$env:COMPUTERNAME
Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain, UserName
```

Rename only after explicit confirmation:

```powershell
Rename-Computer -NewName "NEW-PC-NAME" -Restart:$false
```

Renaming requires administrator rights and takes effect after restart. On managed or domain-joined machines, stop and defer to the administrator unless the user has authority.

UI path: Settings → System → About → Rename this PC.

## Account Full Name

This is safer than changing the username/profile folder.

Read:

```powershell
Get-LocalUser -Name $env:USERNAME | Select-Object Name, FullName, Enabled
```

For a local account, set only after confirmation and from an administrator session:

```powershell
Set-LocalUser -Name $env:USERNAME -FullName "New Display Name"
```

Microsoft, Entra ID, domain, and organization-managed accounts may ignore or overwrite local display-name changes. Use the account/organization management surface instead.

## Username And Profile Folder

Do not automate this from the active user session. Recommend this guarded flow:

1. Make a full backup and record BitLocker/device-encryption recovery information.
2. Create and verify a temporary second administrator account.
3. Sign out of the target account completely.
4. Sign in as the second administrator.
5. Confirm whether the account is local, Microsoft, Entra ID, or domain-managed.
6. Prefer creating a new correctly named account and migrating data over editing `ProfileList` manually.
7. If profile migration is required, preserve ACL ownership, application data, credential access, environment variables, scheduled tasks, and developer-tool paths.
8. Restart and verify sign-in, profile path, Windows Credential Manager, Git/SSH, IDEs, package managers, and application licenses.

If the user is currently logged in as the account being changed, stop and require the second administrator session.

## Timezone And Locale

Read:

```powershell
Get-TimeZone
Get-Culture
Get-WinSystemLocale
Get-WinUserLanguageList
```

List exact timezone IDs and set one only after confirmation:

```powershell
Get-TimeZone -ListAvailable
Set-TimeZone -Id "Taipei Standard Time"
```

Language and regional formats are usually safer through Settings → Time & language → Language & region. Some changes require sign-out or restart.
