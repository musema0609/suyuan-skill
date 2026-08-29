Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\claude_cleanup.ps1'
. $scriptPath -NoMain

$script:Passed = 0
$script:Failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if (($Expected | ConvertTo-Json -Depth 20 -Compress) -cne ($Actual | ConvertTo-Json -Depth 20 -Compress)) {
        throw "$Message`nExpected: $Expected`nActual: $Actual"
    }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    if (-not $thrown) { throw $Message }
}

function New-TestHome {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('claude-cleanup-windows-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $path '.claude') -Force | Out-Null
    return $path
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "PASS $Name"
        $script:Passed++
    } catch {
        Write-Host "FAIL $Name - $($_.Exception.Message)" -ForegroundColor Red
        $script:Failed++
    }
}

Invoke-Test 'backup contains all Claude data and identity' {
    $testHomePath = New-TestHome
    try {
        $project = Join-Path $testHomePath '.claude\projects\session.jsonl'
        $skill = Join-Path $testHomePath '.claude\skills\demo\SKILL.md'
        New-Item -ItemType Directory -Path (Split-Path $project -Parent),(Split-Path $skill -Parent) -Force | Out-Null
        Set-Content -LiteralPath $project -Value 'session' -Encoding UTF8
        Set-Content -LiteralPath $skill -Value 'skill' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $testHomePath '.claude.json') -Value '{"userID":"old"}' -Encoding UTF8
        $backup = New-ClaudeBackup $testHomePath
        Assert-True (Test-Path -LiteralPath (Join-Path $backup 'dot-claude\projects\session.jsonl')) 'project missing from backup'
        Assert-True (Test-Path -LiteralPath (Join-Path $backup 'dot-claude\skills\demo\SKILL.md')) 'skill missing from backup'
        Assert-True (Test-Path -LiteralPath (Join-Path $backup 'claude.json')) 'identity missing from backup'
        $manifest = Read-JsonFile (Join-Path $backup 'manifest.json')
        Assert-True ([bool](Get-PropertyValue $manifest 'claudeJsonCopied')) 'manifest did not verify identity'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test 'backup records reparse points without following their targets' {
    $testHomePath = New-TestHome
    $externalPath = Join-Path ([IO.Path]::GetTempPath()) ('claude-cleanup-external-' + [guid]::NewGuid().ToString('N'))
    $linkPath = Join-Path $testHomePath '.claude\external-link'
    try {
        New-Item -ItemType Directory -Path $externalPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $externalPath 'outside.txt') -Value 'must not be copied' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $testHomePath '.claude\inside.txt') -Value 'must be copied' -Encoding UTF8
        New-Item -ItemType Junction -Path $linkPath -Target $externalPath | Out-Null
        Set-Content -LiteralPath (Join-Path $testHomePath '.claude.json') -Value '{"userID":"old"}' -Encoding UTF8
        $backup = New-ClaudeBackup $testHomePath
        $manifest = Read-JsonFile (Join-Path $backup 'manifest.json')
        Assert-Equal 1 (Get-PropertyValue $manifest 'reparsePointCount') 'reparse point count mismatch'
        Assert-Equal 'external-link' @((Get-PropertyValue $manifest 'reparsePoints'))[0].relativePath 'reparse point path missing from manifest'
        Assert-True (Test-Path -LiteralPath (Join-Path $backup 'dot-claude\inside.txt')) 'regular file missing from backup'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $backup 'dot-claude\external-link\outside.txt'))) 'external target was followed into backup'
        Assert-True (Test-Path -LiteralPath (Join-Path $externalPath 'outside.txt')) 'external target was modified'
    } finally {
        if (Test-Path -LiteralPath $linkPath) { try { [IO.Directory]::Delete($linkPath) } catch {} }
        Remove-Item -LiteralPath $testHomePath,$externalPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'deletion gate rejects protected and unknown paths' {
    $testHomePath = New-TestHome
    try {
        $claude = Join-Path $testHomePath '.claude'
        foreach ($name in $script:ProtectedNames) {
            $target = Join-Path $claude $name
            Assert-Throws { Move-ToQuarantine $target @($target) $claude (Join-Path $testHomePath 'trash') } "protected path accepted: $name"
        }
        Assert-Throws { Move-ToQuarantine (Join-Path $testHomePath 'Documents') @() $claude (Join-Path $testHomePath 'trash') } 'unknown path accepted'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test 'safe cache moves without touching project' {
    $testHomePath = New-TestHome
    try {
        $project = Join-Path $testHomePath '.claude\projects\session.jsonl'
        $cache = Join-Path $testHomePath '.claude\cache'
        New-Item -ItemType Directory -Path (Split-Path $project -Parent),$cache -Force | Out-Null
        Set-Content -LiteralPath $project -Value 'keep' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $cache 'entry') -Value 'cache' -Encoding UTF8
        $destination = Move-ToQuarantine $cache @($cache) (Join-Path $testHomePath '.claude') (Join-Path $testHomePath 'trash\run')
        Assert-True (-not (Test-Path -LiteralPath $cache)) 'cache was not moved'
        Assert-True (Test-Path -LiteralPath (Join-Path $destination 'entry')) 'cache entry missing in quarantine'
        Assert-True (Test-Path -LiteralPath $project) 'project was touched'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test 'identity rotation syncs internal backups' {
    $testHomePath = New-TestHome
    try {
        Write-JsonAtomic (Join-Path $testHomePath '.claude.json') ([pscustomobject]@{ userID='old'; machineID='old'; oauthAccount=[pscustomobject]@{}; keep=1 })
        $internal = Join-Path $testHomePath '.claude\backups\.claude.json.backup.1'
        Write-JsonAtomic $internal ([pscustomobject]@{ userID='old'; machineID='old'; oauthAccount=[pscustomobject]@{}; keepBackup=1 })
        Assert-Equal 1 (Rotate-ClaudeIdentity $testHomePath) 'backup count mismatch'
        $main = Read-JsonFile (Join-Path $testHomePath '.claude.json')
        $saved = Read-JsonFile $internal
        Assert-Equal (Get-PropertyValue $main 'userID') (Get-PropertyValue $saved 'userID') 'userID not synchronized'
        Assert-Equal (Get-PropertyValue $main 'machineID') (Get-PropertyValue $saved 'machineID') 'machineID not synchronized'
        Assert-True (-not (Test-HasProperty $main 'oauthAccount')) 'oauthAccount remained in main identity'
        Assert-True (-not (Test-HasProperty $saved 'oauthAccount')) 'oauthAccount remained in backup identity'
        Assert-True (([string](Get-PropertyValue $main 'userID')).Length -eq 64) 'rotated ID is not 64 hex characters'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test 'simple mode preserves telemetry and other settings' {
    $testHomePath = New-TestHome
    try {
        $settingsPath = Join-Path $testHomePath '.claude\settings.json'
        $original = [pscustomobject]@{
            env = [pscustomobject]@{ DISABLE_TELEMETRY='1'; TOKEN='secret' }
            hooks = [pscustomobject]@{ x=@('keep') }
        }
        Write-JsonAtomic $settingsPath $original
        Update-SimpleMode $testHomePath 1
        $updated = Read-JsonFile $settingsPath
        Assert-Equal '1' (Get-PropertyValue (Get-SettingsEnv $updated) 'CLAUDE_CODE_SIMPLE') 'simple mode not enabled'
        Assert-True (Test-SnapshotEqual (Get-TelemetrySnapshot $original) (Get-TelemetrySnapshot $updated)) 'telemetry changed'
        Assert-Equal @('keep') @((Get-PropertyValue (Get-PropertyValue $updated 'hooks') 'x')) 'hooks changed'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test 'safe target discovery stays on the narrow allowlist' {
    $testHomePath = New-TestHome
    try {
        $cache = Join-Path $testHomePath '.claude\cache'
        $project = Join-Path $testHomePath '.claude\projects'
        New-Item -ItemType Directory -Path $cache,$project -Force | Out-Null
        $targets = @(Get-SafeTargets $testHomePath)
        Assert-True ($targets -contains (Get-FullPath $cache)) 'safe cache was not discovered'
        Assert-True ($targets -notcontains (Get-FullPath $project)) 'protected project path was discovered as safe'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n$($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -gt 0) { exit 1 }
