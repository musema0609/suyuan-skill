Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\audit_claude_cleanup.ps1'
. $scriptPath -NoMain

$script:Passed = 0
$script:Failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "PASS $Name"
        $script:Passed++
    } catch {
        Write-Host "FAIL $Name - $($_.Exception.Message)`n$($_.ScriptStackTrace)" -ForegroundColor Red
        $script:Failed++
    }
}

function New-TestHome {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('claude-cleanup-audit-windows-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $path '.claude') -Force | Out-Null
    return $path
}

Invoke-Test 'redaction does not reveal short or full secrets' {
    Assert-True ((Protect-Value 'short') -eq '<redacted>') 'short secret was not redacted'
    $redacted = Protect-Value 'abcdefghijklmnopqrstuvwxyz'
    Assert-True ($redacted -eq 'abcdef...wxyz') 'long value redaction shape changed'
    Assert-True ($redacted -notmatch 'ghijklmnopqrstuv') 'middle of secret leaked'
}

Invoke-Test 'invalid JSON is reported without throwing' {
    $testHomePath = New-TestHome
    try {
        $path = Join-Path $testHomePath '.claude\settings.json'
        Set-Content -LiteralPath $path -Value '{invalid' -Encoding UTF8
        $result = Read-JsonSafe $path
        Assert-True ($null -eq $result.Data) 'invalid JSON returned data'
        Assert-True (-not [string]::IsNullOrWhiteSpace($result.Error)) 'invalid JSON did not report error'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Invoke-Test 'audit reports core items and never prints token values' {
    $testHomePath = New-TestHome
    try {
        $settings = @'
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "audit-secret-token-value",
    "DISABLE_TELEMETRY": "1"
  },
  "hooks": {"keep": true}
}
'@
        Set-Content -LiteralPath (Join-Path $testHomePath '.claude\settings.json') -Value $settings -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $testHomePath '.claude\.credentials.json') -Value '{"claudeAiOauth":{"accessToken":"audit-oauth-secret"}}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $testHomePath '.claude.json') -Value '{"userID":"12345678901234567890","oauthAccount":{"x":1}}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $testHomePath '.claude\projects'),(Join-Path $testHomePath '.claude\cache') -Force | Out-Null
        $items = @(Invoke-ClaudeCleanupAudit -UserHomePath $testHomePath -ExpectedZone '' -DesktopExpectation 'removed' -SlimmingExpected:$false)
        $ids = @($items.id)
        foreach ($id in @('settings-json','auth-token','claude-json-userid','claude-cli-cache','credential-file','credential-manager-legacy','credential-backups','desktop-app','active-processes','browser-profiles','external-identity')) {
            Assert-True ($ids -contains $id) "missing audit item: $id"
        }
        $serialized = $items | ConvertTo-Json -Depth 8
        Assert-True ($serialized -notmatch 'audit-secret-token-value') 'token value leaked in audit output'
        Assert-True ($serialized -notmatch 'audit-oauth-secret') 'OAuth credential value leaked in audit output'
        $tokenItem = $items | Where-Object id -eq 'auth-token'
        Assert-True ($tokenItem.evidence -eq 'present, value redacted') 'token presence was not reported safely'
    } finally { Remove-Item -LiteralPath $testHomePath -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n$($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -gt 0) { exit 1 }
