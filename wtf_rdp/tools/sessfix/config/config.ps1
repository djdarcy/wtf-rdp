<#
.SYNOPSIS
    rdp config (sessfix) — show or change the watchdog service's runtime parameters
    (poll interval, wedge-confirm window, target user). Setting requires admin and
    restarts the service.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Alias('h')][switch] $Help,
    [string] $ServiceName     = 'wtf-rdp-sessfix',
    [string] $InstallDir      = 'C:\ProgramData\wtf-rdp',
    [int]    $PollIntervalSec = 0,    # >0 sets it
    [int]    $WedgeConfirmSec = 0,    # >0 sets it
    [string] $TargetUser      = '',   # non-empty sets it
    [switch] $ClearTargetUser,        # remove the target-user restriction (watch all)
    [switch] $Json,
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
if ($Help -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp config -- show or change the watchdog service parameters.

Usage: rdp config [-Json]                         (show current config)
       rdp config -PollIntervalSec <n>            (set + restart; admin)
       rdp config -WedgeConfirmSec <n>            (set + restart; admin)
       rdp config -TargetUser <name>              (restrict rescues to one user)
       rdp config -ClearTargetUser                (rescue any stranded session)

  -PollIntervalSec   watchdog poll interval, seconds
  -WedgeConfirmSec   how long a wedge must persist before rescue, seconds
  -TargetUser        only ever rescue this user's session
  -ClearTargetUser   remove the target-user restriction

With no setter flags this just prints the current config. Changing anything
requires an elevated shell and restarts the service.
"@
    return
}
$ErrorActionPreference = 'Stop'
function Fail($m){ Write-Host "[wtf-rdp] $m" -ForegroundColor Yellow; exit 1 }

$nssm = Join-Path $InstallDir 'nssm.exe'
if (-not (Test-Path $nssm)) { Fail "nssm.exe not found in $InstallDir -- run 'rdp install' first." }

function Get-AppParams {
    # nssm writes its output as UTF-16LE; when captured, the OEM console codepage
    # decodes each pair as char+NUL, so the raw string is riddled with `0 chars
    # ("w`0t`0f`0...") and every regex misses. Strip the NULs to recover the value.
    $raw = (& $nssm get $ServiceName AppParameters) -join ' '
    ($raw -replace "`0", '').Trim()
}
function Parse-Config($ap) {
    [pscustomobject]@{
        PollIntervalSec = if ($ap -match '-PollIntervalSec\s+(\d+)') { [int]$Matches[1] } else { $null }
        WedgeConfirmSec = if ($ap -match '-WedgeConfirmSec\s+(\d+)') { [int]$Matches[1] } else { $null }
        TargetUser      = if ($ap -match '-TargetUser\s+(\S+)')      { $Matches[1] }        else { $null }
    }
}

$ap = Get-AppParams
if (-not $ap) { Fail "Could not read AppParameters for '$ServiceName' -- is the service installed?" }

$wantSet = ($PollIntervalSec -gt 0) -or ($WedgeConfirmSec -gt 0) -or ($TargetUser) -or $ClearTargetUser

if (-not $wantSet) {
    $cfg = Parse-Config $ap
    if ($Json) { $cfg | ConvertTo-Json; return }
    Write-Host "wtf-rdp watchdog config ($ServiceName):"
    Write-Host ("  PollIntervalSec : {0}" -f ($(if ($null -ne $cfg.PollIntervalSec) { $cfg.PollIntervalSec } else { '(default)' })))
    Write-Host ("  WedgeConfirmSec : {0}" -f ($(if ($null -ne $cfg.WedgeConfirmSec) { $cfg.WedgeConfirmSec } else { '(default)' })))
    Write-Host ("  TargetUser      : {0}" -f ($(if ($cfg.TargetUser) { $cfg.TargetUser } else { '(any / unrestricted)' })))
    Write-Host "`nPass -PollIntervalSec / -WedgeConfirmSec / -TargetUser / -ClearTargetUser (admin) to change."
    return
}

# --- setting: requires admin, then restart ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Fail "Administrator required to change service config. Re-run from an elevated shell."
}

function Set-Param($ap, $flag, $value) {
    if ($ap -match "$flag\s+\S+") { return ($ap -replace "$flag\s+\S+", "$flag $value") }
    return "$ap $flag $value".Trim()
}

if ($PollIntervalSec -gt 0) { $ap = Set-Param $ap '-PollIntervalSec' $PollIntervalSec }
if ($WedgeConfirmSec -gt 0) { $ap = Set-Param $ap '-WedgeConfirmSec' $WedgeConfirmSec }
if ($ClearTargetUser)       { $ap = ($ap -replace '\s*-TargetUser\s+\S+', '').Trim() }
elseif ($TargetUser)        { $ap = Set-Param $ap '-TargetUser' $TargetUser }

& $nssm set $ServiceName AppParameters $ap | Out-Null
Write-Host "[wtf-rdp] Updated config; restarting service..."
# Restart via the SCM (not `nssm restart`, which reports through nssm's own status
# machinery and can surface transient SERVICE_PAUSED noise during the stop/start).
Restart-Service $ServiceName -Force -ErrorAction SilentlyContinue
Start-Sleep 2
$cfg = Parse-Config (Get-AppParams)
Write-Host "[wtf-rdp] Now: PollIntervalSec=$($cfg.PollIntervalSec) WedgeConfirmSec=$($cfg.WedgeConfirmSec) TargetUser=$(if ($cfg.TargetUser) { $cfg.TargetUser } else { '(any)' })"
Write-Host "[wtf-rdp] Service status: $((Get-Service $ServiceName -EA SilentlyContinue).Status)"
