<#
.SYNOPSIS
    wtf-rdp `rdp sessfix status` — watchdog service state + recent rescues + live sessions.
#>
[CmdletBinding()]
param([switch]$Json)

$svc = Get-Service RdpWatchdog -ErrorAction SilentlyContinue
$log = 'C:\ProgramData\RdpWatchdog\watchdog.log'

if ($Json) {
    [pscustomobject]@{
        serviceInstalled = [bool]$svc
        serviceStatus    = if ($svc) { "$($svc.Status)" } else { $null }
        logPath          = if (Test-Path $log) { $log } else { $null }
    } | ConvertTo-Json
    return
}

if ($svc) { "Watchdog service : $($svc.Status)" }
else      { "Watchdog service : NOT INSTALLED  (run 'rdp sessfix install')" }

if (Test-Path $log) {
    "`n--- recent watchdog log ---"
    Get-Content $log -Tail 8 -ErrorAction SilentlyContinue
}

"`n--- current sessions (qwinsta) ---"
qwinsta 2>&1
