<#
.SYNOPSIS
    rdp query (sessfix) — enumerate RDP/console sessions and flag wedge/stranded
    candidates, using the same session machinery the watchdog uses. Read-only.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Alias('h')][switch] $Help,
    [string] $ModulePath       = '',
    [int]    $WedgeLookbackMin = 30,
    [switch] $Json,
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
if ($Help -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp query -- enumerate sessions and flag stranded / wedge candidates.

Usage: rdp query [-WedgeLookbackMin <n>] [-Json]

  -WedgeLookbackMin  how far back to scan for LSM Event 36 wedge signals (default 30)
  -Json              emit machine-readable JSON

Shows every session (id / winstation / user / state) and marks:
  Stranded     a disconnected session that still owns a logged-on user
  WedgeSignal  a console/connecting session corroborated by a recent LSM Event 36

Read-only; no admin required (wedge-event scan may be limited without admin).
"@
    return
}
$ErrorActionPreference = 'Stop'
function Fail($m){ Write-Host "[wtf-rdp] $m" -ForegroundColor Yellow; exit 1 }

if (-not $ModulePath) {
    $cands = @('C:\ProgramData\wtf-rdp\WtfRdp.Sessions.psm1',
               (Join-Path $PSScriptRoot '..\..\..\lib\WtfRdp.Sessions.psm1'))
    $ModulePath = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $ModulePath) { Fail "WtfRdp.Sessions module not found -- run 'rdp install' first, or pass -ModulePath." }
if (-not (Test-Path $ModulePath)) { Fail "module not found at: $ModulePath" }
Import-Module $ModulePath -Force

$sessions = @(Get-WtfRdpSession)
try { $wedgeSids = @(Get-WtfRdpWedgeEventSid -LookbackSec ($WedgeLookbackMin * 60)) } catch { $wedgeSids = @() }

$rows = foreach ($s in $sessions) {
    $stranded = [bool]($s.User -and $s.StateName -eq 'Disconnected' -and $s.WinStation -ne 'services')
    $wedge    = [bool](($wedgeSids -contains $s.Id) -and ($s.StateName -in @('Connected','ConnectQuery','Init')))
    [pscustomobject]@{
        Id          = $s.Id
        WinStation  = $s.WinStation
        User        = $s.User
        State       = $s.StateName
        Stranded    = $stranded
        WedgeSignal = $wedge
    }
}

if ($Json) {
    [pscustomobject]@{
        sessions      = $rows
        wedgeEventSids = $wedgeSids
        lookbackMin   = $WedgeLookbackMin
    } | ConvertTo-Json -Depth 4
    return
}

$rows | Format-Table Id, WinStation, User, State, Stranded, WedgeSignal -AutoSize | Out-String | Write-Host

$strandedCt = @($rows | Where-Object Stranded).Count
$wedgeCt     = @($rows | Where-Object WedgeSignal).Count
if ($wedgeCt -gt 0) {
    Write-Host "[wtf-rdp] $wedgeCt session(s) show a wedge signal -- run 'rdp recover' (admin) to reconnect + lock."
} elseif ($strandedCt -gt 0) {
    Write-Host "[wtf-rdp] $strandedCt stranded (disconnected) session(s); none show a wedge signal (this is normal)."
} else {
    Write-Host "[wtf-rdp] No stranded or wedged sessions detected."
}
