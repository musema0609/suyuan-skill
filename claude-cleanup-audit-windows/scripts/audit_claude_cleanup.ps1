[CmdletBinding()]
param(
    [string]$ExpectedTimeZone,
    [ValidateSet('removed','present')][string]$ExpectDesktopApp = 'removed',
    [switch]$ExpectSlimming,
    [switch]$Json,
    [switch]$FailOnUnresolved,
    [string]$HomePath = [Environment]::GetFolderPath('UserProfile'),
    [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-JsonObject($Value) {
    return ($Value -is [Collections.IDictionary]) -or ($Value -is [pscustomobject])
}

function Test-HasProperty($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-External([string]$FilePath, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 8) {
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $quotedArguments = @($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
        $psi.Arguments = $quotedArguments -join ' '
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            return [pscustomobject]@{ ExitCode = 999; StdOut = ''; StdErr = 'timeout' }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $process.StandardOutput.ReadToEnd().Trim()
            StdErr = $process.StandardError.ReadToEnd().Trim()
        }
    } catch {
        return [pscustomobject]@{ ExitCode = 999; StdOut = ''; StdErr = $_.Exception.Message }
    }
}

function Read-JsonSafe([string]$Path) {
    try {
        return [pscustomobject]@{
            Data = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
            Error = $null
        }
    } catch {
        return [pscustomobject]@{ Data = $null; Error = $_.Exception.Message }
    }
}

function Protect-Value($Value) {
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return '<empty>' }
    if ($text.Length -le 12) { return '<redacted>' }
    return $text.Substring(0, 6) + '...' + $text.Substring($text.Length - 4)
}

function New-StatusItem(
    [string]$Id,
    [string]$Title,
    [string]$Status,
    [string]$Responsibility,
    [string]$Evidence,
    [string]$NextAction = ''
) {
    return [pscustomobject][ordered]@{
        id = $Id
        title = $Title
        status = $Status
        responsibility = $Responsibility
        evidence = $Evidence
        next_action = $NextAction
    }
}

function Get-AuditRoots([string]$UserHomePath) {
    $actualHome = [Environment]::GetFolderPath('UserProfile')
    $homeFull = [IO.Path]::GetFullPath($UserHomePath).TrimEnd('\')
    $isActual = $homeFull.Equals([IO.Path]::GetFullPath($actualHome).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    $local = if ($isActual -and $env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $UserHomePath 'AppData\Local' }
    $roaming = if ($isActual -and $env:APPDATA) { $env:APPDATA } else { Join-Path $UserHomePath 'AppData\Roaming' }
    return [pscustomobject]@{
        Home = $homeFull
        Claude = Join-Path $UserHomePath '.claude'
        Identity = Join-Path $UserHomePath '.claude.json'
        Settings = Join-Path $UserHomePath '.claude\settings.json'
        LocalAppData = [IO.Path]::GetFullPath($local)
        AppData = [IO.Path]::GetFullPath($roaming)
    }
}

function Get-ExistingPaths([string[]]$Paths) {
    return @($Paths | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) })
}

function Get-ClaudeProcessEvidence {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $name = [string]$_.Name
            $line = [string]$_.CommandLine
            ($name -match '^(?i:claude|claude-code)\.exe$') -or
            ($name -match '^(?i:node)\.exe$' -and $line -match '(?i)@anthropic-ai[\\/]claude-code|[\\/]\.local[\\/](bin|share)[\\/]claude')
        } | Select-Object -First 8 | ForEach-Object {
            "{0} {1} {2}" -f $_.ProcessId, $_.Name, ([string]$_.CommandLine)
        })
    } catch { return @() }
}

function Get-DesktopInstallEvidence([string]$UserHomePath) {
    $roots = Get-AuditRoots $UserHomePath
    $evidence = [Collections.Generic.List[string]]::new()
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.Name -match '(?i)claude') -or ([string]$_.PackageFullName -match '(?i)claude')
        } | ForEach-Object { $evidence.Add("Appx:$($_.Name)") }
    }
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $result = Invoke-External 'winget.exe' @('list','--id','Anthropic.Claude','-e','--accept-source-agreements') 15
        if ($result.ExitCode -eq 0 -and $result.StdOut -match '(?i)Anthropic\.Claude') { $evidence.Add('WinGet:Anthropic.Claude') }
    }
    foreach ($path in @(
        (Join-Path $roots.LocalAppData 'Programs\Claude'),
        (Join-Path $roots.LocalAppData 'AnthropicClaude')
    )) { if (Test-Path -LiteralPath $path) { $evidence.Add($path) } }
    foreach ($base in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | ForEach-Object {
            $item = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $displayName = if ($null -ne $item -and (Test-HasProperty $item 'DisplayName')) { [string](Get-PropertyValue $item 'DisplayName') } else { '' }
            $publisher = if ($null -ne $item -and (Test-HasProperty $item 'Publisher')) { [string](Get-PropertyValue $item 'Publisher') } else { '' }
            if ($displayName -match '^(?i)Claude( Desktop)?$' -and $publisher -match '(?i)Anthropic') {
                $evidence.Add("InstalledApp:$displayName")
            }
        }
    }
    return @($evidence | Sort-Object -Unique)
}

function Invoke-ClaudeCleanupAudit([string]$UserHomePath, [string]$ExpectedZone, [string]$DesktopExpectation, [bool]$SlimmingExpected) {
    $items = [Collections.Generic.List[object]]::new()
    $roots = Get-AuditRoots $UserHomePath

    try {
        $timezone = (Get-TimeZone -ErrorAction Stop).Id
        if ([string]::IsNullOrWhiteSpace($ExpectedZone) -or $timezone -eq $ExpectedZone) {
            $items.Add((New-StatusItem 'timezone' 'Windows timezone' 'done' '已验证' "current=$timezone"))
        } else {
            $items.Add((New-StatusItem 'timezone' 'Windows timezone' 'needs_user_decision' '用户确认' "current=$timezone, expected=$ExpectedZone" 'Confirm whether to change timezone.'))
        }
    } catch {
        $items.Add((New-StatusItem 'timezone' 'Windows timezone' 'unknown' '系统/第三方限制' $_.Exception.Message))
    }

    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $localUser = if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) { Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue } else { $null }
        $identityEvidence = "ComputerName=$($computer.Name); Domain=$($computer.Domain); PartOfDomain=$($computer.PartOfDomain); User=$env:USERNAME; FullName=$(if ($localUser) {$localUser.FullName} else {'<unavailable>'}); Profile=$UserHomePath"
        $items.Add((New-StatusItem 'windows-identity' 'Windows device and account names' 'needs_user_decision' '用户确认' $identityEvidence 'If this matters, confirm exact target names and whether the device is managed.'))
    } catch {
        $items.Add((New-StatusItem 'windows-identity' 'Windows device and account names' 'unknown' '系统/第三方限制' $_.Exception.Message))
    }

    try {
        $culture = (Get-Culture).Name
        $systemLocale = if (Get-Command Get-WinSystemLocale -ErrorAction SilentlyContinue) { (Get-WinSystemLocale).Name } else { '<unavailable>' }
        $languages = if (Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue) { (Get-WinUserLanguageList).LanguageTag -join ', ' } else { '<unavailable>' }
        $items.Add((New-StatusItem 'locale-language' 'Windows locale and languages' 'needs_user_decision' '用户确认' "Culture=$culture; SystemLocale=$systemLocale; Languages=$languages" 'Confirm whether locale/language should be changed.'))
    } catch {
        $items.Add((New-StatusItem 'locale-language' 'Windows locale and languages' 'unknown' '系统/第三方限制' $_.Exception.Message))
    }

    if (Test-Path -LiteralPath $roots.Settings -PathType Leaf) {
        $settingsResult = Read-JsonSafe $roots.Settings
        $settings = $settingsResult.Data
    } else {
        $settingsResult = [pscustomobject]@{ Data = $null; Error = 'missing' }
        $settings = $null
    }
    if (Test-JsonObject $settings) {
        $items.Add((New-StatusItem 'settings-json' 'Claude settings JSON' 'done' '已验证' $roots.Settings))
        $envObject = if (Test-HasProperty $settings 'env') { Get-PropertyValue $settings 'env' } else { [pscustomobject]@{} }
        if (Test-JsonObject $envObject) {
            if (Test-HasProperty $envObject 'BROWSER') {
                $items.Add((New-StatusItem 'settings-browser' 'Claude browser-open behavior' 'done' '已验证' "env.BROWSER=$([string](Get-PropertyValue $envObject 'BROWSER'))"))
            } else {
                $items.Add((New-StatusItem 'settings-browser' 'Claude browser-open behavior' 'needs_user_decision' '用户确认' 'env.BROWSER is not set' 'On native Windows, preserve default behavior or confirm an explicit browser executable; do not use /usr/bin/false.'))
            }
            $tokenPresent = ((Test-HasProperty $envObject 'ANTHROPIC_AUTH_TOKEN') -and [bool](Get-PropertyValue $envObject 'ANTHROPIC_AUTH_TOKEN')) -or [bool]$env:ANTHROPIC_AUTH_TOKEN
            $items.Add((New-StatusItem 'auth-token' 'ANTHROPIC_AUTH_TOKEN' $(if ($tokenPresent) {'done'} else {'not_applicable'}) $(if ($tokenPresent) {'已验证'} else {'不适用'}) $(if ($tokenPresent) {'present, value redacted'} else {'not present in settings env or process env'})))
            $privacyKeys = @('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC','CLAUDE_CODE_DISABLE_AUTO_MEMORY','CLAUDE_CODE_DISABLE_TERMINAL_TITLE')
            $presentPrivacy = @($privacyKeys | Where-Object { Test-HasProperty $envObject $_ })
            $items.Add((New-StatusItem 'privacy-env' 'Claude privacy-related env toggles' $(if ($presentPrivacy.Count) {'done'} else {'needs_user_decision'}) $(if ($presentPrivacy.Count) {'已验证'} else {'用户确认'}) $(if ($presentPrivacy.Count) {'present: ' + ($presentPrivacy -join ', ')} else {'none of the common privacy env toggles found'}) $(if ($presentPrivacy.Count) {''} else {'Confirm desired env toggles.'})))
        } else {
            $items.Add((New-StatusItem 'settings-env' 'Claude settings env object' 'needs_user_decision' '用户确认' 'env exists but is not an object'))
            $envObject = [pscustomobject]@{}
        }
        foreach ($setting in @(
            [pscustomobject]@{ Id='skip-webfetch'; Title='skipWebFetchPreflight'; Desired=$true; Responsibility='Agent 待处理' },
            [pscustomobject]@{ Id='auto-connect-ide'; Title='autoConnectIde'; Desired=$false; Responsibility='用户确认' }
        )) {
            $value = if (Test-HasProperty $settings $setting.Title) { Get-PropertyValue $settings $setting.Title } else { $null }
            $isDesired = $value -is [bool] -and $value -eq $setting.Desired
            $items.Add((New-StatusItem $setting.Id $setting.Title $(if ($isDesired) {'done'} elseif ($setting.Id -eq 'skip-webfetch') {'needs_agent_action'} else {'needs_user_decision'}) $(if ($isDesired) {'已验证'} else {$setting.Responsibility}) "value=$value" $(if ($isDesired) {''} else {'Confirm before changing.'})))
        }
        $deniedTools = @('NotebookEdit','CronCreate','CronDelete','CronList','PushNotification','RemoteTrigger','ScheduleWakeup','DesignSync')
        $permissions = if (Test-HasProperty $settings 'permissions') { Get-PropertyValue $settings 'permissions' } else { $null }
        $deny = if ((Test-JsonObject $permissions) -and (Test-HasProperty $permissions 'deny')) { @(Get-PropertyValue $permissions 'deny') } else { @() }
        $missingDenies = @($deniedTools | Where-Object { $deny -notcontains $_ })
        $items.Add((New-StatusItem 'disabled-tools' 'Optional disabled Claude tools' $(if (-not $missingDenies.Count) {'done'} else {'needs_user_decision'}) $(if (-not $missingDenies.Count) {'已验证'} else {'用户确认'}) $(if (-not $missingDenies.Count) {'all expected tools in permissions.deny'} else {'missing from permissions.deny: ' + ($missingDenies -join ', ')}) $(if ($missingDenies.Count) {'Confirm whether to merge these tools into permissions.deny.'} else {''})))
        if ($SlimmingExpected) {
            $presentSlim = @('disableBundledSkills','disableWorkflows') | Where-Object { Test-HasProperty $settings $_ }
            $items.Add((New-StatusItem 'slimming-config' 'Claude slimming config' $(if ($presentSlim.Count) {'done'} else {'needs_agent_action'}) $(if ($presentSlim.Count) {'已验证'} else {'Agent 待处理'}) $(if ($presentSlim.Count) {'present: ' + ($presentSlim -join ', ')} else {'requested but no known slimming keys found'})))
        } else {
            $items.Add((New-StatusItem 'slimming-config' 'Claude slimming config' 'not_applicable' '不适用' 'not expected by current checklist'))
        }
    } else {
        $items.Add((New-StatusItem 'settings-json' 'Claude settings JSON' 'unknown' 'Agent 待处理' ([string]$settingsResult.Error)))
    }

    $managedSettings = Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json'
    $items.Add((New-StatusItem 'managed-settings' 'Windows managed Claude settings' $(if (Test-Path -LiteralPath $managedSettings) {'done'} else {'not_applicable'}) $(if (Test-Path -LiteralPath $managedSettings) {'已验证'} else {'不适用'}) $(if (Test-Path -LiteralPath $managedSettings) {$managedSettings + ' (read-only policy)'} else {'not present'})))

    if (Test-Path -LiteralPath $roots.Identity -PathType Leaf) {
        $identityResult = Read-JsonSafe $roots.Identity
        $identity = $identityResult.Data
    } else {
        $identityResult = [pscustomobject]@{ Data = $null; Error = 'missing' }
        $identity = $null
    }
    if (Test-JsonObject $identity) {
        $userId = if (Test-HasProperty $identity 'userID') { Get-PropertyValue $identity 'userID' } else { $null }
        $items.Add((New-StatusItem 'claude-json-userid' '%USERPROFILE%\.claude.json userID' $(if ($userId) {'done'} else {'needs_agent_action'}) $(if ($userId) {'已验证'} else {'Agent 待处理'}) $(if ($userId) {'userID=' + (Protect-Value $userId)} else {'missing'})))
        $patterns = @('oauth','anonymous','statsig','growthbook','cache','dynamic','subscription','billing','entitlement','client')
        $names = if ($identity -is [Collections.IDictionary]) { @($identity.Keys) } else { @($identity.PSObject.Properties.Name) }
        $remaining = @($names | Where-Object { $name = $_; $patterns | Where-Object { $name -match [regex]::Escape($_) } } | Sort-Object -Unique)
        $items.Add((New-StatusItem 'claude-json-scrub' '%USERPROFILE%\.claude.json account/cache scrub' $(if (-not $remaining.Count) {'done'} else {'needs_agent_action'}) $(if (-not $remaining.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $remaining.Count) {'no matching top-level account/cache keys'} else {'remaining keys: ' + ($remaining -join ', ')})))
    } else {
        $items.Add((New-StatusItem 'claude-json' '%USERPROFILE%\.claude.json' 'unknown' 'Agent 待处理' ([string]$identityResult.Error)))
    }
    $backupCandidates = @(Get-ChildItem -LiteralPath $UserHomePath -Filter '.claude.json.bak-*' -File -Force -ErrorAction SilentlyContinue)
    $backupRoot = Join-Path $UserHomePath 'ClaudeBackups'
    if (Test-Path -LiteralPath $backupRoot) { $backupCandidates += @(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'claude-cleanup-*' -Force -ErrorAction SilentlyContinue) }
    $latestBackup = $backupCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $items.Add((New-StatusItem 'claude-json-backup' 'Claude cleanup backup' $(if ($latestBackup) {'done'} else {'needs_agent_action'}) $(if ($latestBackup) {'已验证'} else {'Agent 待处理'}) $(if ($latestBackup) {$latestBackup.FullName} else {'no backup found'})))

    $protected = @('projects','history.jsonl','file-history','debug') | ForEach-Object { Join-Path $roots.Claude $_ }
    $presentProtected = @(Get-ExistingPaths $protected)
    $items.Add((New-StatusItem 'claude-history-preserved' 'Claude Code history/project paths preserved' $(if ($presentProtected.Count) {'done'} else {'unknown'}) $(if ($presentProtected.Count) {'已验证'} else {'用户确认'}) $(if ($presentProtected.Count) {'present: ' + ($presentProtected -join ', ')} else {'none of the protected paths are present'})))

    $cachePaths = @('cache','stats-cache.json','telemetry','usage-data','usage.jsonl','usage.with-fix.jsonl') | ForEach-Object { Join-Path $roots.Claude $_ }
    $cachePaths += @(
        (Join-Path $roots.LocalAppData 'Claude\Cache'),
        (Join-Path $roots.LocalAppData 'Claude\Code Cache'),
        (Join-Path $roots.LocalAppData 'Claude\GPUCache')
    )
    $presentCaches = @(Get-ExistingPaths $cachePaths)
    $items.Add((New-StatusItem 'claude-cli-cache' 'Claude CLI caches/usage files' $(if (-not $presentCaches.Count) {'done'} else {'needs_agent_action'}) $(if (-not $presentCaches.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $presentCaches.Count) {'all target paths absent'} else {'still present: ' + ($presentCaches -join ', ')})))

    if (Get-Command cmdkey.exe -ErrorAction SilentlyContinue) {
        $credentialOutput = (& cmdkey.exe /list 2>&1 | Out-String)
        $credentialFound = $credentialOutput.IndexOf('Claude Code-credentials', [StringComparison]::OrdinalIgnoreCase) -ge 0
        $items.Add((New-StatusItem 'credential-manager' 'Credential Manager Claude Code-credentials' $(if ($credentialFound) {'needs_agent_action'} else {'done'}) $(if ($credentialFound) {'Agent 待处理'} else {'已验证'}) $(if ($credentialFound) {'found'} else {'not found'})))
    } else {
        $items.Add((New-StatusItem 'credential-manager' 'Credential Manager Claude Code-credentials' 'unknown' '系统/第三方限制' 'cmdkey.exe unavailable'))
    }

    $desktopInstall = @(Get-DesktopInstallEvidence $UserHomePath)
    $desktopPresent = $desktopInstall.Count -gt 0
    $desktopDone = if ($DesktopExpectation -eq 'removed') { -not $desktopPresent } else { $desktopPresent }
    $items.Add((New-StatusItem 'desktop-app' 'Claude Desktop application' $(if ($desktopDone) {'done'} elseif ($DesktopExpectation -eq 'removed') {'needs_agent_action'} else {'not_applicable'}) $(if ($desktopDone) {'已验证'} elseif ($DesktopExpectation -eq 'removed') {'Agent 待处理'} else {'不适用'}) $(if ($desktopPresent) {$desktopInstall -join '; '} else {'not detected'})))

    $desktopData = @(
        (Join-Path $roots.AppData 'Claude'),
        (Join-Path $roots.LocalAppData 'Claude'),
        (Join-Path $roots.LocalAppData 'Anthropic\Claude')
    )
    $packageRoot = Join-Path $roots.LocalAppData 'Packages'
    if (Test-Path -LiteralPath $packageRoot) {
        $desktopData += @(Get-ChildItem -LiteralPath $packageRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)claude' } | ForEach-Object FullName)
    }
    $presentDesktopData = @(Get-ExistingPaths $desktopData)
    $items.Add((New-StatusItem 'desktop-data' 'Claude Desktop data/cache paths' $(if (-not $presentDesktopData.Count) {'done'} else {'needs_agent_action'}) $(if (-not $presentDesktopData.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $presentDesktopData.Count) {'all target paths absent'} else {'still present: ' + ($presentDesktopData -join ', ')})))

    $helperPaths = @(
        (Join-Path $roots.LocalAppData 'GMT8Clock'),
        (Join-Path $roots.AppData 'Microsoft\Windows\Start Menu\Programs\Startup\GMT8Clock.lnk')
    )
    $presentHelpers = @(Get-ExistingPaths $helperPaths)
    $scheduled = @()
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $scheduled = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^(?i)GMT8Clock$' })
    }
    $items.Add((New-StatusItem 'timezone-helper' 'GMT8Clock helper' $(if (-not $presentHelpers.Count -and -not $scheduled.Count) {'done'} else {'needs_agent_action'}) $(if (-not $presentHelpers.Count -and -not $scheduled.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $presentHelpers.Count -and -not $scheduled.Count) {'not installed and no scheduled task found'} else {'present or scheduled'})))

    $processes = @(Get-ClaudeProcessEvidence)
    $items.Add((New-StatusItem 'active-processes' 'Active Claude processes' $(if ($processes.Count) {'needs_user_decision'} else {'done'}) $(if ($processes.Count) {'用户确认'} else {'已验证'}) $(if ($processes.Count) {$processes -join [Environment]::NewLine} else {'none found'}) $(if ($processes.Count) {'Ask before stopping active processes.'} else {''})))

    $wslResult = if (Get-Command wsl.exe -ErrorAction SilentlyContinue) { Invoke-External 'wsl.exe' @('-l','-q') 8 } else { $null }
    $wslEvidence = if ($null -ne $wslResult -and $wslResult.ExitCode -eq 0 -and $wslResult.StdOut) { $wslResult.StdOut -replace "`0", '' } else { 'no WSL distributions detected' }
    $wslPresent = $wslEvidence -ne 'no WSL distributions detected'
    $items.Add((New-StatusItem 'wsl-installations' 'WSL Claude environments' $(if ($wslPresent) {'needs_user_decision'} else {'not_applicable'}) $(if ($wslPresent) {'用户确认'} else {'不适用'}) $wslEvidence $(if ($wslPresent) {'Confirm exact WSL distribution before auditing its Linux home.'} else {''})))

    $items.Add((New-StatusItem 'browser-profiles' 'Browser profile cleanup' 'needs_user_decision' '用户确认' 'not checked without exact browser/profile path' 'Confirm browser and profile before touching browser data.'))
    $items.Add((New-StatusItem 'external-identity' 'Payment/IP/phone/email/fingerprint evasion' 'not_applicable' '系统/第三方限制' 'outside local cleanup scope' 'Do not provide bypass instructions; limit work to local privacy/config audit.'))
    return @($items)
}

function Write-MarkdownReport($Items) {
    $counts = @{}
    foreach ($item in $Items) {
        if (-not $counts.ContainsKey($item.status)) { $counts[$item.status] = 0 }
        $counts[$item.status]++
    }
    Write-Output '# Claude Cleanup Audit for Windows'
    Write-Output ''
    Write-Output '## Summary'
    Write-Output ''
    Write-Output (($counts.Keys | Sort-Object | ForEach-Object { "$_=$($counts[$_])" }) -join ', ')
    Write-Output ''
    Write-Output '## Items'
    Write-Output ''
    foreach ($item in $Items) {
        Write-Output "- [$($item.status)] $($item.title)"
        Write-Output "  - responsibility: $($item.responsibility)"
        Write-Output "  - evidence: $($item.evidence)"
        if ($item.next_action) { Write-Output "  - next: $($item.next_action)" }
    }
}

function Invoke-AuditMain {
    $items = @(Invoke-ClaudeCleanupAudit -UserHomePath $HomePath -ExpectedZone $ExpectedTimeZone -DesktopExpectation $ExpectDesktopApp -SlimmingExpected:$ExpectSlimming)
    if ($Json) { $items | ConvertTo-Json -Depth 8 }
    else { Write-MarkdownReport $items }
    $script:AuditExitCode = if ($FailOnUnresolved -and @($items | Where-Object { $_.status -in @('needs_user_decision','needs_agent_action','unknown') }).Count -gt 0) { 1 } else { 0 }
}

if (-not $NoMain) {
    $script:AuditExitCode = 0
    Invoke-AuditMain
    exit $script:AuditExitCode
}
﻿[CmdletBinding()]
param(
    [string]$ExpectedTimeZone,
    [ValidateSet('removed','present')][string]$ExpectDesktopApp = 'removed',
    [switch]$ExpectSlimming,
    [switch]$Json,
    [switch]$FailOnUnresolved,
    [string]$HomePath = [Environment]::GetFolderPath('UserProfile'),
    [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-JsonObject($Value) {
    return ($Value -is [Collections.IDictionary]) -or ($Value -is [pscustomobject])
}

function Test-HasProperty($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-External([string]$FilePath, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 8) {
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $quotedArguments = @($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
        $psi.Arguments = $quotedArguments -join ' '
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            return [pscustomobject]@{ ExitCode = 999; StdOut = ''; StdErr = 'timeout' }
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $process.StandardOutput.ReadToEnd().Trim()
            StdErr = $process.StandardError.ReadToEnd().Trim()
        }
    } catch {
        return [pscustomobject]@{ ExitCode = 999; StdOut = ''; StdErr = $_.Exception.Message }
    }
}

function Read-JsonSafe([string]$Path) {
    try {
        return [pscustomobject]@{
            Data = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
            Error = $null
        }
    } catch {
        return [pscustomobject]@{ Data = $null; Error = $_.Exception.Message }
    }
}

function Protect-Value($Value) {
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return '<empty>' }
    if ($text.Length -le 12) { return '<redacted>' }
    return $text.Substring(0, 6) + '...' + $text.Substring($text.Length - 4)
}

function New-StatusItem(
    [string]$Id,
    [string]$Title,
    [string]$Status,
    [string]$Responsibility,
    [string]$Evidence,
    [string]$NextAction = ''
) {
    return [pscustomobject][ordered]@{
        id = $Id
        title = $Title
        status = $Status
        responsibility = $Responsibility
        evidence = $Evidence
        next_action = $NextAction
    }
}

function Get-AuditRoots([string]$UserHomePath) {
    $actualHome = [Environment]::GetFolderPath('UserProfile')
    $homeFull = [IO.Path]::GetFullPath($UserHomePath).TrimEnd('\')
    $isActual = $homeFull.Equals([IO.Path]::GetFullPath($actualHome).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    $local = if ($isActual -and $env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $UserHomePath 'AppData\Local' }
    $roaming = if ($isActual -and $env:APPDATA) { $env:APPDATA } else { Join-Path $UserHomePath 'AppData\Roaming' }
    return [pscustomobject]@{
        Home = $homeFull
        Claude = Join-Path $UserHomePath '.claude'
        Identity = Join-Path $UserHomePath '.claude.json'
        Settings = Join-Path $UserHomePath '.claude\settings.json'
        LocalAppData = [IO.Path]::GetFullPath($local)
        AppData = [IO.Path]::GetFullPath($roaming)
    }
}

function Get-ExistingPaths([string[]]$Paths) {
    return @($Paths | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) })
}

function Get-ClaudeProcessEvidence {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $name = [string]$_.Name
            $line = [string]$_.CommandLine
            ($name -match '^(?i:claude|claude-code)\.exe$') -or
            ($name -match '^(?i:node)\.exe$' -and $line -match '(?i)@anthropic-ai[\\/]claude-code|[\\/]\.local[\\/](bin|share)[\\/]claude')
        } | Select-Object -First 8 | ForEach-Object {
            "{0} {1} {2}" -f $_.ProcessId, $_.Name, ([string]$_.CommandLine)
        })
    } catch { return @() }
}

function Get-DesktopInstallEvidence([string]$UserHomePath) {
    $roots = Get-AuditRoots $UserHomePath
    $evidence = [Collections.Generic.List[string]]::new()
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.Name -match '(?i)claude') -or ([string]$_.PackageFullName -match '(?i)claude')
        } | ForEach-Object { $evidence.Add("Appx:$($_.Name)") }
    }
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $result = Invoke-External 'winget.exe' @('list','--id','Anthropic.Claude','-e','--accept-source-agreements') 15
        if ($result.ExitCode -eq 0 -and $result.StdOut -match '(?i)Anthropic\.Claude') { $evidence.Add('WinGet:Anthropic.Claude') }
    }
    foreach ($path in @(
        (Join-Path $roots.LocalAppData 'Programs\Claude'),
        (Join-Path $roots.LocalAppData 'AnthropicClaude')
    )) { if (Test-Path -LiteralPath $path) { $evidence.Add($path) } }
    foreach ($base in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | ForEach-Object {
            $item = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $displayName = if ($null -ne $item -and (Test-HasProperty $item 'DisplayName')) { [string](Get-PropertyValue $item 'DisplayName') } else { '' }
            $publisher = if ($null -ne $item -and (Test-HasProperty $item 'Publisher')) { [string](Get-PropertyValue $item 'Publisher') } else { '' }
            if ($displayName -match '^(?i)Claude( Desktop)?$' -and $publisher -match '(?i)Anthropic') {
                $evidence.Add("InstalledApp:$displayName")
            }
        }
    }
    return @($evidence | Sort-Object -Unique)
}

function Invoke-ClaudeCleanupAudit([string]$UserHomePath, [string]$ExpectedZone, [string]$DesktopExpectation, [bool]$SlimmingExpected) {
    $items = [Collections.Generic.List[object]]::new()
    $roots = Get-AuditRoots $UserHomePath

    try {
        $timezone = (Get-TimeZone -ErrorAction Stop).Id
        if ([string]::IsNullOrWhiteSpace($ExpectedZone) -or $timezone -eq $ExpectedZone) {
            $items.Add((New-StatusItem 'timezone' 'Windows timezone' 'done' '已验证' "current=$timezone"))
        } else {
            $items.Add((New-StatusItem 'timezone' 'Windows timezone' 'needs_user_decision' '用户确认' "current=$timezone, expected=$ExpectedZone" 'Confirm whether to change timezone.'))
        }
    } catch {
        $items.Add((New-StatusItem 'timezone' 'Windows timezone' 'unknown' '系统/第三方限制' $_.Exception.Message))
    }

    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $localUser = if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) { Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue } else { $null }
        $identityEvidence = "ComputerName=$($computer.Name); Domain=$($computer.Domain); PartOfDomain=$($computer.PartOfDomain); User=$env:USERNAME; FullName=$(if ($localUser) {$localUser.FullName} else {'<unavailable>'}); Profile=$UserHomePath"
        $items.Add((New-StatusItem 'windows-identity' 'Windows device and account names' 'needs_user_decision' '用户确认' $identityEvidence 'If this matters, confirm exact target names and whether the device is managed.'))
    } catch {
        $items.Add((New-StatusItem 'windows-identity' 'Windows device and account names' 'unknown' '系统/第三方限制' $_.Exception.Message))
    }

    try {
        $culture = (Get-Culture).Name
        $systemLocale = if (Get-Command Get-WinSystemLocale -ErrorAction SilentlyContinue) { (Get-WinSystemLocale).Name } else { '<unavailable>' }
        $languages = if (Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue) { (Get-WinUserLanguageList).LanguageTag -join ', ' } else { '<unavailable>' }
        $items.Add((New-StatusItem 'locale-language' 'Windows locale and languages' 'needs_user_decision' '用户确认' "Culture=$culture; SystemLocale=$systemLocale; Languages=$languages" 'Confirm whether locale/language should be changed.'))
    } catch {
        $items.Add((New-StatusItem 'locale-language' 'Windows locale and languages' 'unknown' '系统/第三方限制' $_.Exception.Message))
    }

    if (Test-Path -LiteralPath $roots.Settings -PathType Leaf) {
        $settingsResult = Read-JsonSafe $roots.Settings
        $settings = $settingsResult.Data
    } else {
        $settingsResult = [pscustomobject]@{ Data = $null; Error = 'missing' }
        $settings = $null
    }
    if (Test-JsonObject $settings) {
        $items.Add((New-StatusItem 'settings-json' 'Claude settings JSON' 'done' '已验证' $roots.Settings))
        $envObject = if (Test-HasProperty $settings 'env') { Get-PropertyValue $settings 'env' } else { [pscustomobject]@{} }
        if (Test-JsonObject $envObject) {
            if (Test-HasProperty $envObject 'BROWSER') {
                $items.Add((New-StatusItem 'settings-browser' 'Claude browser-open behavior' 'done' '已验证' "env.BROWSER=$([string](Get-PropertyValue $envObject 'BROWSER'))"))
            } else {
                $items.Add((New-StatusItem 'settings-browser' 'Claude browser-open behavior' 'needs_user_decision' '用户确认' 'env.BROWSER is not set' 'On native Windows, preserve default behavior or confirm an explicit browser executable; do not use /usr/bin/false.'))
            }
            $tokenPresent = ((Test-HasProperty $envObject 'ANTHROPIC_AUTH_TOKEN') -and [bool](Get-PropertyValue $envObject 'ANTHROPIC_AUTH_TOKEN')) -or [bool]$env:ANTHROPIC_AUTH_TOKEN
            $items.Add((New-StatusItem 'auth-token' 'ANTHROPIC_AUTH_TOKEN' $(if ($tokenPresent) {'done'} else {'not_applicable'}) $(if ($tokenPresent) {'已验证'} else {'不适用'}) $(if ($tokenPresent) {'present, value redacted'} else {'not present in settings env or process env'})))
            $privacyKeys = @('CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC','CLAUDE_CODE_DISABLE_AUTO_MEMORY','CLAUDE_CODE_DISABLE_TERMINAL_TITLE')
            $presentPrivacy = @($privacyKeys | Where-Object { Test-HasProperty $envObject $_ })
            $items.Add((New-StatusItem 'privacy-env' 'Claude privacy-related env toggles' $(if ($presentPrivacy.Count) {'done'} else {'needs_user_decision'}) $(if ($presentPrivacy.Count) {'已验证'} else {'用户确认'}) $(if ($presentPrivacy.Count) {'present: ' + ($presentPrivacy -join ', ')} else {'none of the common privacy env toggles found'}) $(if ($presentPrivacy.Count) {''} else {'Confirm desired env toggles.'})))
        } else {
            $items.Add((New-StatusItem 'settings-env' 'Claude settings env object' 'needs_user_decision' '用户确认' 'env exists but is not an object'))
            $envObject = [pscustomobject]@{}
        }
        foreach ($setting in @(
            [pscustomobject]@{ Id='skip-webfetch'; Title='skipWebFetchPreflight'; Desired=$true; Responsibility='Agent 待处理' },
            [pscustomobject]@{ Id='auto-connect-ide'; Title='autoConnectIde'; Desired=$false; Responsibility='用户确认' }
        )) {
            $value = if (Test-HasProperty $settings $setting.Title) { Get-PropertyValue $settings $setting.Title } else { $null }
            $isDesired = $value -is [bool] -and $value -eq $setting.Desired
            $items.Add((New-StatusItem $setting.Id $setting.Title $(if ($isDesired) {'done'} elseif ($setting.Id -eq 'skip-webfetch') {'needs_agent_action'} else {'needs_user_decision'}) $(if ($isDesired) {'已验证'} else {$setting.Responsibility}) "value=$value" $(if ($isDesired) {''} else {'Confirm before changing.'})))
        }
        $deniedTools = @('NotebookEdit','CronCreate','CronDelete','CronList','PushNotification','RemoteTrigger','ScheduleWakeup','DesignSync')
        $permissions = if (Test-HasProperty $settings 'permissions') { Get-PropertyValue $settings 'permissions' } else { $null }
        $deny = if ((Test-JsonObject $permissions) -and (Test-HasProperty $permissions 'deny')) { @(Get-PropertyValue $permissions 'deny') } else { @() }
        $missingDenies = @($deniedTools | Where-Object { $deny -notcontains $_ })
        $items.Add((New-StatusItem 'disabled-tools' 'Optional disabled Claude tools' $(if (-not $missingDenies.Count) {'done'} else {'needs_user_decision'}) $(if (-not $missingDenies.Count) {'已验证'} else {'用户确认'}) $(if (-not $missingDenies.Count) {'all expected tools in permissions.deny'} else {'missing from permissions.deny: ' + ($missingDenies -join ', ')}) $(if ($missingDenies.Count) {'Confirm whether to merge these tools into permissions.deny.'} else {''})))
        if ($SlimmingExpected) {
            $presentSlim = @('disableBundledSkills','disableWorkflows') | Where-Object { Test-HasProperty $settings $_ }
            $items.Add((New-StatusItem 'slimming-config' 'Claude slimming config' $(if ($presentSlim.Count) {'done'} else {'needs_agent_action'}) $(if ($presentSlim.Count) {'已验证'} else {'Agent 待处理'}) $(if ($presentSlim.Count) {'present: ' + ($presentSlim -join ', ')} else {'requested but no known slimming keys found'})))
        } else {
            $items.Add((New-StatusItem 'slimming-config' 'Claude slimming config' 'not_applicable' '不适用' 'not expected by current checklist'))
        }
    } else {
        $items.Add((New-StatusItem 'settings-json' 'Claude settings JSON' 'unknown' 'Agent 待处理' ([string]$settingsResult.Error)))
    }

    $managedSettings = Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json'
    $items.Add((New-StatusItem 'managed-settings' 'Windows managed Claude settings' $(if (Test-Path -LiteralPath $managedSettings) {'done'} else {'not_applicable'}) $(if (Test-Path -LiteralPath $managedSettings) {'已验证'} else {'不适用'}) $(if (Test-Path -LiteralPath $managedSettings) {$managedSettings + ' (read-only policy)'} else {'not present'})))

    if (Test-Path -LiteralPath $roots.Identity -PathType Leaf) {
        $identityResult = Read-JsonSafe $roots.Identity
        $identity = $identityResult.Data
    } else {
        $identityResult = [pscustomobject]@{ Data = $null; Error = 'missing' }
        $identity = $null
    }
    if (Test-JsonObject $identity) {
        $userId = if (Test-HasProperty $identity 'userID') { Get-PropertyValue $identity 'userID' } else { $null }
        $items.Add((New-StatusItem 'claude-json-userid' '%USERPROFILE%\.claude.json userID' $(if ($userId) {'done'} else {'needs_agent_action'}) $(if ($userId) {'已验证'} else {'Agent 待处理'}) $(if ($userId) {'userID=' + (Protect-Value $userId)} else {'missing'})))
        $patterns = @('oauth','anonymous','statsig','growthbook','cache','dynamic','subscription','billing','entitlement','client')
        $names = if ($identity -is [Collections.IDictionary]) { @($identity.Keys) } else { @($identity.PSObject.Properties.Name) }
        $remaining = @($names | Where-Object { $name = $_; $patterns | Where-Object { $name -match [regex]::Escape($_) } } | Sort-Object -Unique)
        $items.Add((New-StatusItem 'claude-json-scrub' '%USERPROFILE%\.claude.json account/cache scrub' $(if (-not $remaining.Count) {'done'} else {'needs_agent_action'}) $(if (-not $remaining.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $remaining.Count) {'no matching top-level account/cache keys'} else {'remaining keys: ' + ($remaining -join ', ')})))
    } else {
        $items.Add((New-StatusItem 'claude-json' '%USERPROFILE%\.claude.json' 'unknown' 'Agent 待处理' ([string]$identityResult.Error)))
    }
    $backupCandidates = @(Get-ChildItem -LiteralPath $UserHomePath -Filter '.claude.json.bak-*' -File -Force -ErrorAction SilentlyContinue)
    $backupRoot = Join-Path $UserHomePath 'ClaudeBackups'
    if (Test-Path -LiteralPath $backupRoot) { $backupCandidates += @(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'claude-cleanup-*' -Force -ErrorAction SilentlyContinue) }
    $latestBackup = $backupCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $items.Add((New-StatusItem 'claude-json-backup' 'Claude cleanup backup' $(if ($latestBackup) {'done'} else {'needs_agent_action'}) $(if ($latestBackup) {'已验证'} else {'Agent 待处理'}) $(if ($latestBackup) {$latestBackup.FullName} else {'no backup found'})))

    $protected = @('projects','history.jsonl','file-history','debug') | ForEach-Object { Join-Path $roots.Claude $_ }
    $presentProtected = @(Get-ExistingPaths $protected)
    $items.Add((New-StatusItem 'claude-history-preserved' 'Claude Code history/project paths preserved' $(if ($presentProtected.Count) {'done'} else {'unknown'}) $(if ($presentProtected.Count) {'已验证'} else {'用户确认'}) $(if ($presentProtected.Count) {'present: ' + ($presentProtected -join ', ')} else {'none of the protected paths are present'})))

    $cachePaths = @('cache','stats-cache.json','telemetry','usage-data','usage.jsonl','usage.with-fix.jsonl') | ForEach-Object { Join-Path $roots.Claude $_ }
    $cachePaths += @(
        (Join-Path $roots.LocalAppData 'Claude\Cache'),
        (Join-Path $roots.LocalAppData 'Claude\Code Cache'),
        (Join-Path $roots.LocalAppData 'Claude\GPUCache')
    )
    $presentCaches = @(Get-ExistingPaths $cachePaths)
    $items.Add((New-StatusItem 'claude-cli-cache' 'Claude CLI caches/usage files' $(if (-not $presentCaches.Count) {'done'} else {'needs_agent_action'}) $(if (-not $presentCaches.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $presentCaches.Count) {'all target paths absent'} else {'still present: ' + ($presentCaches -join ', ')})))

    if (Get-Command cmdkey.exe -ErrorAction SilentlyContinue) {
        $credentialOutput = (& cmdkey.exe /list 2>&1 | Out-String)
        $credentialFound = $credentialOutput.IndexOf('Claude Code-credentials', [StringComparison]::OrdinalIgnoreCase) -ge 0
        $items.Add((New-StatusItem 'credential-manager' 'Credential Manager Claude Code-credentials' $(if ($credentialFound) {'needs_agent_action'} else {'done'}) $(if ($credentialFound) {'Agent 待处理'} else {'已验证'}) $(if ($credentialFound) {'found'} else {'not found'})))
    } else {
        $items.Add((New-StatusItem 'credential-manager' 'Credential Manager Claude Code-credentials' 'unknown' '系统/第三方限制' 'cmdkey.exe unavailable'))
    }

    $desktopInstall = @(Get-DesktopInstallEvidence $UserHomePath)
    $desktopPresent = $desktopInstall.Count -gt 0
    $desktopDone = if ($DesktopExpectation -eq 'removed') { -not $desktopPresent } else { $desktopPresent }
    $items.Add((New-StatusItem 'desktop-app' 'Claude Desktop application' $(if ($desktopDone) {'done'} elseif ($DesktopExpectation -eq 'removed') {'needs_agent_action'} else {'not_applicable'}) $(if ($desktopDone) {'已验证'} elseif ($DesktopExpectation -eq 'removed') {'Agent 待处理'} else {'不适用'}) $(if ($desktopPresent) {$desktopInstall -join '; '} else {'not detected'})))

    $desktopData = @(
        (Join-Path $roots.AppData 'Claude'),
        (Join-Path $roots.LocalAppData 'Claude'),
        (Join-Path $roots.LocalAppData 'Anthropic\Claude')
    )
    $packageRoot = Join-Path $roots.LocalAppData 'Packages'
    if (Test-Path -LiteralPath $packageRoot) {
        $desktopData += @(Get-ChildItem -LiteralPath $packageRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)claude' } | ForEach-Object FullName)
    }
    $presentDesktopData = @(Get-ExistingPaths $desktopData)
    $items.Add((New-StatusItem 'desktop-data' 'Claude Desktop data/cache paths' $(if (-not $presentDesktopData.Count) {'done'} else {'needs_agent_action'}) $(if (-not $presentDesktopData.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $presentDesktopData.Count) {'all target paths absent'} else {'still present: ' + ($presentDesktopData -join ', ')})))

    $helperPaths = @(
        (Join-Path $roots.LocalAppData 'GMT8Clock'),
        (Join-Path $roots.AppData 'Microsoft\Windows\Start Menu\Programs\Startup\GMT8Clock.lnk')
    )
    $presentHelpers = @(Get-ExistingPaths $helperPaths)
    $scheduled = @()
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $scheduled = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match '^(?i)GMT8Clock$' })
    }
    $items.Add((New-StatusItem 'timezone-helper' 'GMT8Clock helper' $(if (-not $presentHelpers.Count -and -not $scheduled.Count) {'done'} else {'needs_agent_action'}) $(if (-not $presentHelpers.Count -and -not $scheduled.Count) {'已验证'} else {'Agent 待处理'}) $(if (-not $presentHelpers.Count -and -not $scheduled.Count) {'not installed and no scheduled task found'} else {'present or scheduled'})))

    $processes = @(Get-ClaudeProcessEvidence)
    $items.Add((New-StatusItem 'active-processes' 'Active Claude processes' $(if ($processes.Count) {'needs_user_decision'} else {'done'}) $(if ($processes.Count) {'用户确认'} else {'已验证'}) $(if ($processes.Count) {$processes -join [Environment]::NewLine} else {'none found'}) $(if ($processes.Count) {'Ask before stopping active processes.'} else {''})))

    $wslResult = if (Get-Command wsl.exe -ErrorAction SilentlyContinue) { Invoke-External 'wsl.exe' @('-l','-q') 8 } else { $null }
    $wslEvidence = if ($null -ne $wslResult -and $wslResult.ExitCode -eq 0 -and $wslResult.StdOut) { $wslResult.StdOut -replace "`0", '' } else { 'no WSL distributions detected' }
    $wslPresent = $wslEvidence -ne 'no WSL distributions detected'
    $items.Add((New-StatusItem 'wsl-installations' 'WSL Claude environments' $(if ($wslPresent) {'needs_user_decision'} else {'not_applicable'}) $(if ($wslPresent) {'用户确认'} else {'不适用'}) $wslEvidence $(if ($wslPresent) {'Confirm exact WSL distribution before auditing its Linux home.'} else {''})))

    $items.Add((New-StatusItem 'browser-profiles' 'Browser profile cleanup' 'needs_user_decision' '用户确认' 'not checked without exact browser/profile path' 'Confirm browser and profile before touching browser data.'))
    $items.Add((New-StatusItem 'external-identity' 'Payment/IP/phone/email/fingerprint evasion' 'not_applicable' '系统/第三方限制' 'outside local cleanup scope' 'Do not provide bypass instructions; limit work to local privacy/config audit.'))
    return @($items)
}

function Write-MarkdownReport($Items) {
    $counts = @{}
    foreach ($item in $Items) {
        if (-not $counts.ContainsKey($item.status)) { $counts[$item.status] = 0 }
        $counts[$item.status]++
    }
    Write-Output '# Claude Cleanup Audit for Windows'
    Write-Output ''
    Write-Output '## Summary'
    Write-Output ''
    Write-Output (($counts.Keys | Sort-Object | ForEach-Object { "$_=$($counts[$_])" }) -join ', ')
    Write-Output ''
    Write-Output '## Items'
    Write-Output ''
    foreach ($item in $Items) {
        Write-Output "- [$($item.status)] $($item.title)"
        Write-Output "  - responsibility: $($item.responsibility)"
        Write-Output "  - evidence: $($item.evidence)"
        if ($item.next_action) { Write-Output "  - next: $($item.next_action)" }
    }
}

function Invoke-AuditMain {
    $items = @(Invoke-ClaudeCleanupAudit -UserHomePath $HomePath -ExpectedZone $ExpectedTimeZone -DesktopExpectation $ExpectDesktopApp -SlimmingExpected:$ExpectSlimming)
    if ($Json) { $items | ConvertTo-Json -Depth 8 }
    else { Write-MarkdownReport $items }
    if ($FailOnUnresolved -and @($items | Where-Object { $_.status -in @('needs_user_decision','needs_agent_action','unknown') }).Count -gt 0) { return 1 }
    return 0
}

if (-not $NoMain) { exit (Invoke-AuditMain) }
