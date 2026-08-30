[CmdletBinding()]
param(
    [switch]$Audit,
    [string]$HomePath = [Environment]::GetFolderPath('UserProfile'),
    [switch]$NoMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TelemetryKeys = @(
    'DISABLE_TELEMETRY',
    'DISABLE_ERROR_REPORTING',
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
)
$script:AccountCacheKeys = @(
    'additionalModelCostsCache', 'additionalModelOptionsCache', 'anonymousId', 'autoCompactWindowsCache',
    'cachedChromeExtensionInstalled', 'cachedDynamicConfigs', 'cachedExperimentData', 'cachedExperimentFeatures',
    'cachedExtraUsageDisabledReason', 'cachedGrowthBookFeatures', 'cachedGrowthBookFeaturesAt', 'cachedStatsigGates',
    'clientDataCache', 'clientDataCacheSlots', 'feedbackSurveyState', 'groveConfigCache', 'metricsStatusCache',
    'modelAccessCache', 'oauthAccount', 'orgModelDefaultCache', 'overageCreditGrantCache', 'passesEligibilityCache', 's1mAccessCache'
)
$script:ProtectedNames = @(
    '.credentials.json', 'CLAUDE.md', 'agents', 'backups', 'commands', 'debug', 'file-history', 'history.jsonl', 'hooks',
    'mcp-servers', 'plans', 'plugins', 'projects', 'scripts', 'session-env', 'sessions', 'settings.json',
    'settings.local.json', 'skills', 'tasks', 'todos'
)
$script:CliCacheNames = @(
    'cache', 'stats-cache.json', 'telemetry', 'usage-data', 'usage.jsonl', 'usage.with-fix.jsonl'
)
$script:CredentialTarget = 'Claude Code-credentials'
$script:TaipeiTimeZone = 'Taipei Standard Time'

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-IsSameOrChild([string]$Path, [string]$Root) {
    $candidate = Get-FullPath $Path
    $base = Get-FullPath $Root
    return $candidate.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

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

function Set-PropertyValue($Object, [string]$Name, $Value) {
    if ($Object -is [Collections.IDictionary]) {
        $Object[$Name] = $Value
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Remove-PropertyValue($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) {
        [void]$Object.Remove($Name)
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) {
        [void]$Object.PSObject.Properties.Remove($Name)
    }
}

function Read-JsonFile([string]$Path, [switch]$AllowMissing) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($AllowMissing) { return [pscustomobject]@{} }
        throw "JSON 文件不存在：$Path"
    }
    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "JSON 无效：$Path；$($_.Exception.Message)"
    }
    return $data
}

function Write-JsonAtomic([string]$Path, $Data) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Data | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-SettingsEnv($Data) {
    if (-not (Test-JsonObject $Data)) { throw 'settings.json 顶层必须是 JSON object' }
    if (-not (Test-HasProperty $Data 'env')) { return [pscustomobject]@{} }
    $envObject = Get-PropertyValue $Data 'env'
    if (-not (Test-JsonObject $envObject)) { throw 'settings.json 的 env 结构异常，拒绝修改' }
    return $envObject
}

function Get-TelemetrySnapshot($Data) {
    $envObject = Get-SettingsEnv $Data
    $snapshot = [ordered]@{}
    foreach ($key in $script:TelemetryKeys) {
        $snapshot[$key] = if (Test-HasProperty $envObject $key) { Get-PropertyValue $envObject $key } else { $null }
    }
    return [pscustomobject]$snapshot
}

function Test-SnapshotEqual($Left, $Right) {
    return (($Left | ConvertTo-Json -Compress) -ceq ($Right | ConvertTo-Json -Compress))
}

function Get-CleanupRoots([string]$UserHomePath) {
    $actualHome = [Environment]::GetFolderPath('UserProfile')
    $isActual = (Get-FullPath $UserHomePath).Equals((Get-FullPath $actualHome), [StringComparison]::OrdinalIgnoreCase)
    $local = if ($isActual -and $env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $UserHomePath 'AppData\Local' }
    $roaming = if ($isActual -and $env:APPDATA) { $env:APPDATA } else { Join-Path $UserHomePath 'AppData\Roaming' }
    return [pscustomobject]@{
        Home = Get-FullPath $UserHomePath
        Claude = Join-Path $UserHomePath '.claude'
        Identity = Join-Path $UserHomePath '.claude.json'
        Credentials = Join-Path $UserHomePath '.claude\.credentials.json'
        Settings = Join-Path $UserHomePath '.claude\settings.json'
        LocalAppData = Get-FullPath $local
        AppData = Get-FullPath $roaming
    }
}

function Get-SafeTargets([string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($name in $script:CliCacheNames) { $targets.Add((Join-Path $roots.Claude $name)) }
    foreach ($relative in @(
        'Claude\Cache', 'Claude\Code Cache', 'Claude\GPUCache', 'Claude\Logs',
        'Anthropic\Claude\Cache'
    )) { $targets.Add((Join-Path $roots.LocalAppData $relative)) }
    $targets.Add((Join-Path $roots.AppData 'Claude\logs'))
    $crashRoot = Join-Path $roots.LocalAppData 'CrashDumps'
    if (Test-Path -LiteralPath $crashRoot -PathType Container) {
        Get-ChildItem -LiteralPath $crashRoot -Filter 'Claude*.dmp' -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $targets.Add($_.FullName) }
    }
    return @($targets | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-FullPath $_ } | Sort-Object -Unique)
}

function Get-DesktopTargets([string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($path in @(
        (Join-Path $roots.AppData 'Claude'),
        (Join-Path $roots.LocalAppData 'Claude'),
        (Join-Path $roots.LocalAppData 'Anthropic\Claude')
    )) { $targets.Add($path) }
    $packageRoot = Join-Path $roots.LocalAppData 'Packages'
    if (Test-Path -LiteralPath $packageRoot -PathType Container) {
        Get-ChildItem -LiteralPath $packageRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)claude' -and $_.Name -match '(?i)anthropic|claude' } |
            ForEach-Object { $targets.Add($_.FullName) }
    }
    return @($targets | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-FullPath $_ } | Sort-Object -Unique)
}

function Test-ClaudeProcessRecord($Process) {
    $name = [string]$Process.Name
    $commandLine = [string]$Process.CommandLine
    if ($name -match '^(?i:claude|claude-code)\.exe$') { return $true }
    if ($name -match '^(?i:node)\.exe$' -and $commandLine -match '(?i)@anthropic-ai[\\/]claude-code|[\\/]\.local[\\/](bin|share)[\\/]claude') { return $true }
    return $false
}

function Get-ClaudeProcesses {
    $evidence = [Collections.Generic.List[string]]::new()
    try { $processes = @(Get-Process -ErrorAction Stop) }
    catch { throw "无法审计 Claude 进程：$($_.Exception.Message)" }
    foreach ($process in $processes) {
        if ($process.Id -eq $PID) { continue }
        $name = [string]$process.ProcessName
        $path = try { [string]$process.Path } catch { '' }
        if ($name -match '^(?i:claude|claude-code)$') {
            $evidence.Add(("{0} {1}.exe {2}" -f $process.Id, $name, $path).Trim())
            continue
        }
        if ($name -notmatch '^(?i:node)$' -or $path -match '(?i)[\\/]OpenAI[\\/]Codex[\\/]') { continue }
        $commandLine = ''
        try {
            $record = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction Stop
            $commandLine = [string]$record.CommandLine
        } catch {}
        if ($commandLine -match '(?i)@anthropic-ai[\\/]claude-code|[\\/]\.local[\\/](bin|share)[\\/]claude' -or
            $path -match '(?i)anthropic|claude') {
            $evidence.Add(("{0} node.exe {1}" -f $process.Id, $(if ($commandLine) {$commandLine} else {$path})).Trim())
        }
    }
    return @($evidence | Sort-Object -Unique)
}

function Test-RunningUnderClaude {
    if ($env:CLAUDECODE -match '^(?i:1|true|yes)$' -or $env:CLAUDE_CODE_ENTRYPOINT) { return $true }
    try {
        $currentId = $PID
        for ($i = 0; $i -lt 16; $i++) {
            $current = Get-CimInstance Win32_Process -Filter "ProcessId=$currentId" -ErrorAction Stop
            if ($null -eq $current -or [int]$current.ParentProcessId -le 0) { return $false }
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($current.ParentProcessId)" -ErrorAction SilentlyContinue
            if ($null -eq $parent) { return $false }
            if (Test-ClaudeProcessRecord $parent) { return $true }
            if ([int]$parent.ParentProcessId -eq $currentId) { return $false }
            $currentId = [int]$parent.ProcessId
        }
    } catch { return $false }
    return $false
}

function Get-CurrentTimeZoneId {
    try { return (Get-TimeZone -ErrorAction Stop).Id } catch { return '未知' }
}

function Get-TreeInventory([string]$Root) {
    $rootFull = Get-FullPath $Root
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($rootFull)
    $fileCount = 0
    $bytes = 0L
    $reparsePoints = [Collections.Generic.List[object]]::new()
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $relative = $item.FullName.Substring($rootFull.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                $linkType = if ($item.PSObject.Properties['LinkType']) { [string]$item.LinkType } else { 'ReparsePoint' }
                $targets = if ($item.PSObject.Properties['Target']) { @($item.Target | ForEach-Object { [string]$_ }) } else { @() }
                $reparsePoints.Add([ordered]@{
                    relativePath = $relative
                    linkType = $linkType
                    targets = $targets
                    isDirectory = [bool]$item.PSIsContainer
                })
                continue
            }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
            else {
                $fileCount++
                $bytes += [long]$item.Length
            }
        }
    }
    return [pscustomobject]@{ Files = $fileCount; Bytes = $bytes; ReparsePoints = @($reparsePoints) }
}

function Copy-TreeWithoutReparse([string]$Source, [string]$Destination) {
    $sourceFull = Get-FullPath $Source
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ Source = $sourceFull; Destination = (Get-FullPath $Destination) })
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $current.Source -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $destinationItem = Join-Path $current.Destination $item.Name
            if ($item.PSIsContainer) {
                New-Item -ItemType Directory -Path $destinationItem -Force | Out-Null
                $pending.Enqueue([pscustomobject]@{ Source = $item.FullName; Destination = $destinationItem })
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination $destinationItem -Force
            }
        }
    }
}

function Test-ByteArrayEqual([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

function Protect-CredentialFile([string]$SourcePath, [string]$DestinationPath) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return $false }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    $plain = [IO.File]::ReadAllBytes($SourcePath)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plain,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $parent = Split-Path -Parent $DestinationPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllBytes($DestinationPath, $protected)
        $roundTrip = [Security.Cryptography.ProtectedData]::Unprotect(
            [IO.File]::ReadAllBytes($DestinationPath),
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        if (-not (Test-ByteArrayEqual $plain $roundTrip)) { throw 'DPAPI round-trip verification failed' }
    } catch {
        if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue }
        throw "凭据 DPAPI 保护失败：$($_.Exception.Message)"
    }
    return $true
}

function New-ClaudeBackup([string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    if (-not (Test-Path -LiteralPath $roots.Claude -PathType Container)) {
        throw '%USERPROFILE%\.claude 不存在，无法满足先全量备份的硬要求'
    }
    $sourceInventory = Get-TreeInventory $roots.Claude
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'
    $backupRoot = Join-Path $UserHomePath 'ClaudeBackups'
    $partial = Join-Path $backupRoot "claude-cleanup-$stamp.partial"
    $final = $partial.Substring(0, $partial.Length - '.partial'.Length)
    New-Item -ItemType Directory -Path $partial -Force | Out-Null
    try {
        Copy-TreeWithoutReparse $roots.Claude (Join-Path $partial 'dot-claude')
        $credentialProtected = $false
        $credentialCopy = Join-Path $partial 'dot-claude\.credentials.json'
        if (Test-Path -LiteralPath $credentialCopy -PathType Leaf) {
            $credentialProtected = Protect-CredentialFile $credentialCopy (Join-Path $partial 'credentials.json.dpapi')
            Remove-Item -LiteralPath $credentialCopy -Force
        }
        $backupInventory = Get-TreeInventory (Join-Path $partial 'dot-claude')
        $expectedFiles = $sourceInventory.Files
        $expectedBytes = $sourceInventory.Bytes
        if ($credentialProtected) {
            $expectedFiles--
            $expectedBytes -= [long](Get-Item -LiteralPath $roots.Credentials).Length
        }
        if ($expectedFiles -ne $backupInventory.Files -or $expectedBytes -ne $backupInventory.Bytes -or $backupInventory.ReparsePoints.Count -ne 0) {
            throw "~/.claude 备份校验失败，保留未完成副本：$partial"
        }
        $identityCopied = $false
        if (Test-Path -LiteralPath $roots.Identity -PathType Leaf) {
            $identityDestination = Join-Path $partial 'claude.json'
            Copy-Item -LiteralPath $roots.Identity -Destination $identityDestination -Force
            $identityCopied = ((Get-Item -LiteralPath $roots.Identity).Length -eq (Get-Item -LiteralPath $identityDestination).Length)
            if (-not $identityCopied) { throw "~/.claude.json 备份校验失败，保留未完成副本：$partial" }
        }
        Write-JsonAtomic (Join-Path $partial 'manifest.json') ([ordered]@{
            files = $backupInventory.Files
            regularFileBytes = $backupInventory.Bytes
            sourceFiles = $sourceInventory.Files
            sourceRegularFileBytes = $sourceInventory.Bytes
            reparsePointCount = $sourceInventory.ReparsePoints.Count
            reparsePoints = @($sourceInventory.ReparsePoints)
            claudeJsonCopied = $identityCopied
            credentialProtected = $credentialProtected
            credentialProtection = $(if ($credentialProtected) {'Windows DPAPI CurrentUser'} else {'not present'})
        })
        Move-Item -LiteralPath $partial -Destination $final
        return $final
    } catch {
        throw
    }
}

function Protect-ExistingBackupCredentials([string]$UserHomePath) {
    $backupRoot = Join-Path $UserHomePath 'ClaudeBackups'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { return 0 }
    $protectedCount = 0
    foreach ($backup in @(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'claude-cleanup-*' -Force -ErrorAction Stop)) {
        if ($backup.Name.EndsWith('.partial', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $plain = Join-Path $backup.FullName 'dot-claude\.credentials.json'
        if (-not (Test-Path -LiteralPath $plain -PathType Leaf)) { continue }
        $protectedPath = Join-Path $backup.FullName 'credentials.json.dpapi'
        [void](Protect-CredentialFile $plain $protectedPath)
        Remove-Item -LiteralPath $plain -Force
        $inventory = Get-TreeInventory (Join-Path $backup.FullName 'dot-claude')
        $manifestPath = Join-Path $backup.FullName 'manifest.json'
        $manifest = Read-JsonFile $manifestPath -AllowMissing
        Set-PropertyValue $manifest 'files' $inventory.Files
        Set-PropertyValue $manifest 'regularFileBytes' $inventory.Bytes
        Set-PropertyValue $manifest 'credentialProtected' $true
        Set-PropertyValue $manifest 'credentialProtection' 'Windows DPAPI CurrentUser'
        Set-PropertyValue $manifest 'credentialSanitizedAt' ([DateTime]::UtcNow.ToString('o'))
        Write-JsonAtomic $manifestPath $manifest
        $protectedCount++
    }
    return $protectedCount
}

function Move-ToQuarantine(
    [string]$Target,
    [string[]]$Allowed,
    [string]$ClaudeRoot,
    [string]$Batch
) {
    $absolute = Get-FullPath $Target
    $allowedFull = @($Allowed | ForEach-Object { Get-FullPath $_ })
    if (-not ($allowedFull | Where-Object { $_.Equals($absolute, [StringComparison]::OrdinalIgnoreCase) })) {
        throw "目标不在删除白名单：$Target"
    }
    if ((Get-FullPath $ClaudeRoot).Equals($absolute, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝触碰受保护路径：$Target"
    }
    foreach ($name in $script:ProtectedNames) {
        if (Test-IsSameOrChild $absolute (Join-Path $ClaudeRoot $name)) {
            throw "拒绝触碰受保护路径：$Target"
        }
    }
    if (-not (Test-Path -LiteralPath $Target)) { return $null }
    New-Item -ItemType Directory -Path $Batch -Force | Out-Null
    $index = @(Get-ChildItem -LiteralPath $Batch -Force -ErrorAction SilentlyContinue).Count
    $leaf = Split-Path -Leaf $Target
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'target' }
    $destination = Join-Path $Batch ('{0:d3}-{1}' -f $index, $leaf)
    Move-Item -LiteralPath $Target -Destination $destination
    return $destination
}

function New-Hex64 {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Rotate-ClaudeIdentity([string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    if (-not (Test-Path -LiteralPath $roots.Identity -PathType Leaf)) {
        throw '%USERPROFILE%\.claude.json 不存在，无法轮换本地 ID'
    }
    $files = [Collections.Generic.List[string]]::new()
    $files.Add($roots.Identity)
    $backupRoot = Join-Path $roots.Claude 'backups'
    if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        Get-ChildItem -LiteralPath $backupRoot -Filter '.claude.json.backup.*' -File -Force |
            Sort-Object FullName | ForEach-Object { $files.Add($_.FullName) }
    }
    $userId = New-Hex64
    $machineId = New-Hex64
    $prepared = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $data = Read-JsonFile $file
        if (-not (Test-JsonObject $data)) { throw "身份文件不是 JSON object：$file" }
        Set-PropertyValue $data 'userID' $userId
        Set-PropertyValue $data 'machineID' $machineId
        foreach ($key in $script:AccountCacheKeys) { Remove-PropertyValue $data $key }
        $prepared.Add([pscustomobject]@{ Path = $file; Data = $data })
    }
    foreach ($item in $prepared) { Write-JsonAtomic $item.Path $item.Data }
    return $files.Count - 1
}

function Update-SimpleMode([string]$UserHomePath, [int]$Mode) {
    $roots = Get-CleanupRoots $UserHomePath
    if ($Mode -eq 2 -and -not (Test-Path -LiteralPath $roots.Settings -PathType Leaf)) { return }
    $data = Read-JsonFile $roots.Settings -AllowMissing
    if (-not (Test-JsonObject $data)) { throw 'settings.json 顶层必须是 JSON object' }
    $before = Get-TelemetrySnapshot $data
    $envObject = Get-SettingsEnv $data
    if ($Mode -eq 1) { Set-PropertyValue $envObject 'CLAUDE_CODE_SIMPLE' '1' }
    else { Remove-PropertyValue $envObject 'CLAUDE_CODE_SIMPLE' }
    Set-PropertyValue $data 'env' $envObject
    if (-not (Test-SnapshotEqual (Get-TelemetrySnapshot $data) $before)) {
        throw '精简模式修改触碰了遥测设置'
    }
    Write-JsonAtomic $roots.Settings $data
}

function Test-LegacyCredentialTarget([string]$UserHomePath) {
    $actualHome = [Environment]::GetFolderPath('UserProfile')
    if (-not (Get-FullPath $UserHomePath).Equals((Get-FullPath $actualHome), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Get-Command cmdkey.exe -ErrorAction SilentlyContinue)) { return $false }
    $output = (& cmdkey.exe /list 2>&1 | Out-String)
    return $output.IndexOf($script:CredentialTarget, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-CredentialTarget([string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    return (Test-Path -LiteralPath $roots.Credentials -PathType Leaf) -or (Test-LegacyCredentialTarget $UserHomePath)
}

function Resolve-ClaudeLogoutLauncher {
    foreach ($name in @('claude.exe','claude.cmd','claude.bat','claude.ps1')) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [string]$command.Source
        }
    }
    return $null
}

function New-ClaudeLogoutStartInfo([string]$LauncherPath) {
    if ([string]::IsNullOrWhiteSpace($LauncherPath)) { throw 'Claude 启动器路径为空' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $extension = [IO.Path]::GetExtension($LauncherPath).ToLowerInvariant()
    switch ($extension) {
        '.exe' {
            $psi.FileName = $LauncherPath
            $psi.Arguments = '"auth" "logout"'
        }
        { $_ -in @('.cmd','.bat') } {
            $commandInterpreter = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
                Join-Path $env:SystemRoot 'System32\cmd.exe'
            } else { $env:ComSpec }
            $psi.FileName = $commandInterpreter
            $psi.Arguments = '/d /s /c ""' + $LauncherPath + '" auth logout"'
        }
        '.ps1' {
            $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $psi.FileName = $engine
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $LauncherPath + '" auth logout'
        }
        default { throw "不支持的 Claude Windows 启动器格式：$extension" }
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    return $psi
}

function Invoke-ClaudeAuthLogout([string]$UserHomePath) {
    $actualHome = [Environment]::GetFolderPath('UserProfile')
    if (-not (Get-FullPath $UserHomePath).Equals((Get-FullPath $actualHome), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $launcher = Resolve-ClaudeLogoutLauncher
    if ([string]::IsNullOrWhiteSpace($launcher)) { return $false }
    $psi = New-ClaudeLogoutStartInfo $launcher
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    if (-not $process.WaitForExit(20000)) { throw 'claude auth logout 超时；脚本不会自动结束该进程' }
    return $process.ExitCode -eq 0
}

function Remove-CredentialTarget([string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    [void](Invoke-ClaudeAuthLogout $UserHomePath)
    if (Test-Path -LiteralPath $roots.Credentials -PathType Leaf) { Remove-Item -LiteralPath $roots.Credentials -Force }
    if (Test-LegacyCredentialTarget $UserHomePath) {
        & cmdkey.exe ("/delete:$($script:CredentialTarget)") | Out-Null
        if ($LASTEXITCODE -ne 0 -and (Test-LegacyCredentialTarget $UserHomePath)) { throw '旧版 Windows Credential Manager 凭据删除失败' }
    }
    if ((Test-Path -LiteralPath $roots.Credentials -PathType Leaf) -or (Test-LegacyCredentialTarget $UserHomePath)) { throw 'Claude Code 凭据删除后验证失败' }
}

function Get-DesktopInstallState([string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    $appx = @()
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $appx = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            ([string]$_.Name -match '(?i)claude') -or ([string]$_.PackageFullName -match '(?i)claude')
        })
    }
    $wingetInstalled = $false
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $output = (& winget.exe list --id Anthropic.Claude -e --accept-source-agreements 2>$null | Out-String)
        $wingetInstalled = $LASTEXITCODE -eq 0 -and $output -match '(?i)Anthropic\.Claude'
    }
    $userDirs = @(
        (Join-Path $roots.LocalAppData 'Programs\Claude'),
        (Join-Path $roots.LocalAppData 'AnthropicClaude')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $registryEntries = [Collections.Generic.List[string]]::new()
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
                $registryEntries.Add($displayName)
            }
        }
    }
    return [pscustomobject]@{
        AppxPackages = $appx
        WingetInstalled = $wingetInstalled
        UserInstallDirectories = @($userDirs | ForEach-Object { Get-FullPath $_ })
        RegistryEntries = @($registryEntries)
        Present = ($appx.Count -gt 0 -or $wingetInstalled -or @($userDirs).Count -gt 0 -or $registryEntries.Count -gt 0)
        SupportedPackageRemoval = ($appx.Count -gt 0 -or $wingetInstalled)
    }
}

function Remove-DesktopPackages($State) {
    $actions = [Collections.Generic.List[string]]::new()
    foreach ($package in @($State.AppxPackages)) {
        if (-not (Get-Command Remove-AppxPackage -ErrorAction SilentlyContinue)) { throw 'Remove-AppxPackage 不可用' }
        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
        $actions.Add("Appx:$($package.PackageFullName)")
    }
    if ($State.WingetInstalled) {
        & winget.exe uninstall --id Anthropic.Claude -e --silent --accept-source-agreements | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "WinGet 卸载 Claude Desktop 失败，退出码 $LASTEXITCODE" }
        $actions.Add('WinGet:Anthropic.Claude')
    }
    return @($actions)
}

function Read-Yes([string]$Prompt) {
    return ((Read-Host "$Prompt [y/N]").Trim().ToLowerInvariant() -eq 'y')
}

function Read-Choice([string]$Prompt, [int[]]$Allowed) {
    $value = (Read-Host $Prompt).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { $value = '0' }
    $number = 0
    if (-not [int]::TryParse($value, [ref]$number) -or $Allowed -notcontains $number) {
        throw '输入不在允许范围内，已停止且未修改'
    }
    return $number
}

function Get-UniqueExistingTargets([string[]]$Targets) {
    return @($Targets | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { Get-FullPath $_ } | Sort-Object -Unique | Sort-Object Length -Descending)
}

function Invoke-ClaudeCleanup([switch]$AuditOnly, [string]$UserHomePath) {
    $roots = Get-CleanupRoots $UserHomePath
    if ((Test-RunningUnderClaude) -and -not $AuditOnly) {
        Write-Error '拒绝执行：当前脚本由 Claude Code 启动。请改用 Codex 或普通 PowerShell；这里只允许 -Audit。'
        return 2
    }
    try {
        $settingsData = Read-JsonFile $roots.Settings -AllowMissing
        $envObject = Get-SettingsEnv $settingsData
        $safe = @(Get-SafeTargets $UserHomePath)
        $desktop = @(Get-DesktopTargets $UserHomePath)
        $processes = @(Get-ClaudeProcesses)
        $installState = Get-DesktopInstallState $UserHomePath
    } catch {
        Write-Error "审计失败：$($_.Exception.Message)"
        return 2
    }
    $disabled = @()
    foreach ($key in $script:TelemetryKeys) {
        if (Test-HasProperty $envObject $key) {
            $value = [string](Get-PropertyValue $envObject $key)
            if ($value.ToLowerInvariant() -in @('1', 'true', 'yes', 'on')) { $disabled += $key }
        }
    }
    $simpleValue = if (Test-HasProperty $envObject 'CLAUDE_CODE_SIMPLE') { [string](Get-PropertyValue $envObject 'CLAUDE_CODE_SIMPLE') } else { '' }
    Write-Host 'Claude Cleanup 会自动清理明确可再生的缓存/日志；风险操作仍由你选择。'
    Write-Host "输入最终 CONFIRM 前不会写盘；文件移除只进入隔离目录。`n`n只读审计："
    Write-Host ("- %USERPROFILE%\.claude：{0}；%USERPROFILE%\.claude.json：{1}" -f $(if (Test-Path $roots.Claude -PathType Container) {'存在'} else {'不存在'}), $(if (Test-Path $roots.Identity -PathType Leaf) {'存在'} else {'不存在'}))
    Write-Host "- 可自动清理缓存/日志：$($safe.Count) 项；Claude Desktop 持久数据：$($desktop.Count) 项"
    Write-Host ("- Claude Desktop 应用：{0}；相关进程：{1} 个" -f $(if ($installState.Present) {'存在'} else {'未检测到'}), $processes.Count)
    Write-Host ("- Claude Code 凭据：{0}" -f $(if (Test-CredentialTarget $UserHomePath) {'检测到 .credentials.json 或旧版 Credential Manager 项'} else {'未检测到'}))
    Write-Host ("- 遥测关闭键：{0}（脚本不会改变）" -f $(if ($disabled.Count) {$disabled -join ', '} else {'未检测到'}))
    Write-Host ("- 精简模式：{0}；时区：{1}" -f $(if ($simpleValue.ToLowerInvariant() -in @('1','true')) {'已启用'} else {'未启用'}), (Get-CurrentTimeZoneId))
    if ($AuditOnly) { return 0 }
    try {
        if ([Console]::IsInputRedirected) { throw '拒绝执行：需要真实交互式终端完成知情确认' }
        Write-Host "`n只询问有风险的操作；可再生缓存和日志不逐项询问。"
        $rotate = Read-Yes '轮换本地 userID/machineID，并清除已知账号缓存字段？'
        $credential = Read-Yes '删除 .claude\.credentials.json 和旧版 Credential Manager 项（会退出 CLI 登录）？'
        $desktopMode = Read-Choice 'Claude Desktop：0 保留；1 清登录态/持久数据；2 再卸载应用。选择 [0]' @(0,1,2)
        $simpleMode = Read-Choice '精简模式：0 保持；1 启用 CLAUDE_CODE_SIMPLE；2 移除该设置。选择 [0]' @(0,1,2)
        $setTimezone = (Get-CurrentTimeZoneId) -ne $script:TaipeiTimeZone -and (Read-Yes '把 Windows 时区改为 Taipei Standard Time？')
        $risky = $rotate -or $credential -or $desktopMode -ne 0 -or $simpleMode -ne 0
        $cleanSafe = $processes.Count -eq 0
        if ($processes.Count -gt 0 -and $risky) {
            Write-Host "`n所选风险操作要求由你正常退出所有 Claude Code / Claude Desktop；脚本不会 Stop-Process。"
            [void](Read-Host '退出后按 Enter 重新检查')
            if (@(Get-ClaudeProcesses).Count -gt 0) { throw '仍检测到 Claude 进程，已取消且未写盘' }
            $cleanSafe = $true
        }
        if ($desktopMode -eq 2 -and $installState.RegistryEntries.Count -gt 0 -and -not $installState.SupportedPackageRemoval) {
            throw '检测到仅有注册表卸载项的 Claude Desktop。脚本不会运行未知 UninstallString；请先通过 Windows 设置 → 应用卸载后重跑。'
        }
        $targets = [Collections.Generic.List[string]]::new()
        if ($cleanSafe) { foreach ($item in $safe) { $targets.Add($item) } }
        if ($desktopMode -gt 0) { foreach ($item in $desktop) { $targets.Add($item) } }
        if ($desktopMode -eq 2) { foreach ($item in $installState.UserInstallDirectories) { $targets.Add($item) } }
        $targetList = @(Get-UniqueExistingTargets $targets.ToArray())

        Write-Host "`n最终执行清单："
        Write-Host '1. 第一个写操作：完整备份并校验 %USERPROFILE%\.claude，同时备份 %USERPROFILE%\.claude.json。'
        Write-Host ("2. {0} {1} 项缓存/日志。" -f $(if ($cleanSafe) {'自动清理'} else {'因 Claude 正在运行而跳过'}), $safe.Count)
        foreach ($target in $targetList) { Write-Host "   - $target" }
        Write-Host ("3. 身份轮换：{0}；删除凭据：{1}；桌面应用模式：{2}；精简模式：{3}；修改时区：{4}" -f $rotate, $credential, $desktopMode, $simpleMode, $setTimezone)
        Write-Host '绝不清理 sessions、projects、history、skills、plugins、hooks、commands、agents、MCP、设置文件或任何项目/Git/Codex 数据。'
        Write-Host '普通文件只进隔离目录；凭据在 DPAPI 加密备份验证后永久移除；包管理器卸载恢复需重新安装；遥测键逐值保持不变。'
        if ((Read-Host '完全理解后输入 CONFIRM 开始；其他输入取消').Trim() -cne 'CONFIRM') {
            Write-Host '已取消，没有修改任何内容。'
            return 1
        }

        $beforeTelemetry = Get-TelemetrySnapshot (Read-JsonFile $roots.Settings -AllowMissing)
        $protectedBefore = @($script:ProtectedNames | ForEach-Object { Join-Path $roots.Claude $_ } | Where-Object { Test-Path -LiteralPath $_ })
        if ($credential) { $protectedBefore = @($protectedBefore | Where-Object { -not $_.Equals($roots.Credentials, [StringComparison]::OrdinalIgnoreCase) }) }
        $backup = New-ClaudeBackup $UserHomePath
        Write-Host "`n[1/7] 全量备份已校验：$backup"
        if ($setTimezone) {
            Write-Host '[系统步骤] Set-TimeZone 可能要求管理员 PowerShell；脚本不会读取或保存密码。'
        }
        $identityProgress = if ($rotate) { "[2/7] 身份轮换：同步 $(Rotate-ClaudeIdentity $UserHomePath) 份内部备份" } else { '[2/7] 身份保持不变' }
        Write-Host $identityProgress
        $credentialBackupsProtected = 0
        if ($credential) {
            $credentialBackupsProtected = Protect-ExistingBackupCredentials $UserHomePath
            Remove-CredentialTarget $UserHomePath
        }
        Write-Host ("[3/7] Claude Code 凭据：{0}" -f $(if ($credential) {"已移除；DPAPI 保护 $credentialBackupsProtected 份旧备份"} else {'保持不变'}))
        $batch = Join-Path $UserHomePath ('ClaudeCleanupTrash\claude-cleanup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'))
        $moved = [Collections.Generic.List[string]]::new()
        foreach ($target in $targetList) {
            $destination = Move-ToQuarantine $target $targetList $roots.Claude $batch
            if ($destination) { $moved.Add($destination) }
        }
        Write-Host "[4/7] 已移入隔离目录：$($moved.Count) 项"
        $packageActions = @()
        if ($desktopMode -eq 2) { $packageActions = @(Remove-DesktopPackages $installState) }
        Write-Host ("[5/7] Claude Desktop 包卸载：{0}" -f $(if ($packageActions.Count) {$packageActions -join ', '} else {'未执行'}))
        if ($simpleMode -ne 0) { Update-SimpleMode $UserHomePath $simpleMode }
        Write-Host ("[6/7] 精简模式：{0}" -f @('保持','启用','移除')[$simpleMode])
        if ($setTimezone) {
            Set-TimeZone -Id $script:TaipeiTimeZone -ErrorAction Stop
            if ((Get-CurrentTimeZoneId) -ne $script:TaipeiTimeZone) { throw '时区修改后验证失败' }
        }
        $afterTelemetry = Get-TelemetrySnapshot (Read-JsonFile $roots.Settings -AllowMissing)
        if (-not (Test-SnapshotEqual $beforeTelemetry $afterTelemetry)) { throw '遥测设置发生变化，已停止' }
        $missing = @($protectedBefore | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing.Count -gt 0) { throw ('受保护路径丢失：' + ($missing -join ', ')) }
        Write-Host "[7/7] 遥测状态未变；时区：$(Get-CurrentTimeZoneId)"
        Write-Host "`n完成。未永久删除隔离文件。`n备份：$backup"
        if ($moved.Count -gt 0) { Write-Host "隔离批次：$batch" }
        return 0
    } catch {
        Write-Error "停止：$($_.Exception.Message)"
        return 2
    }
}

if (-not $NoMain) {
    exit (Invoke-ClaudeCleanup -AuditOnly:$Audit -UserHomePath $HomePath)
}
