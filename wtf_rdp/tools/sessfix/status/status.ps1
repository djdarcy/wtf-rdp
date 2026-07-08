<#
.SYNOPSIS
    rdp status (sessfix) — watchdog service state + recent rescues + live sessions.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Alias('h')][switch] $Help,
    [string] $ServiceName = 'wtf-rdp-sessfix',
    [string] $InstallDir  = 'C:\ProgramData\wtf-rdp',
    [switch] $Json,
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
if ($Help -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp status -- show the wtf-rdp watchdog service state + live sessions.

Usage: rdp status [-Json]

  -Json   emit machine-readable JSON instead of the human table

Shows: watchdog service state, the tail of its log, and the current
qwinsta session table. No admin required.
"@
    return
}

$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
$log = Join-Path $InstallDir 'watchdog.log'

if ($Json) {
    [pscustomobject]@{
        serviceInstalled = [bool]$svc
        serviceStatus    = if ($svc) { "$($svc.Status)" } else { $null }
        logPath          = if (Test-Path $log) { $log } else { $null }
    } | ConvertTo-Json
    return
}

if ($svc) { "Watchdog service : $($svc.Status)  ($ServiceName)" }
else      { "Watchdog service : NOT INSTALLED  (run 'rdp install')" }

if (Test-Path $log) {
    "`n--- recent watchdog log ---"
    Get-Content $log -Tail 8 -ErrorAction SilentlyContinue
}

"`n--- current sessions (qwinsta) ---"
qwinsta 2>&1
