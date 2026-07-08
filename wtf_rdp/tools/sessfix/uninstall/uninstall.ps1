<#
.SYNOPSIS
    rdp uninstall (sessfix) — stop and remove the wtf-rdp watchdog service.
    Use -Purge to also delete the install directory.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Alias('h')][switch] $Help,
    [string] $ServiceName = 'wtf-rdp-sessfix',
    [string] $InstallDir  = 'C:\ProgramData\wtf-rdp',
    [switch] $Purge,
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
if ($Help -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp uninstall -- stop and remove the wtf-rdp watchdog service.

Usage: rdp uninstall [-Purge]

  -Purge   also delete the install dir (C:\ProgramData\wtf-rdp)

Requires an elevated (Administrator) shell.
"@
    return
}
$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[wtf-rdp] $m" }
function Fail($m){ Write-Host "[wtf-rdp] $m" -ForegroundColor Yellow; exit 1 }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Fail "Administrator required (removing a service). Re-run from an elevated shell."
}

$nssm = Join-Path $InstallDir 'nssm.exe'
if (Test-Path $nssm) {
    & $nssm stop   $ServiceName         2>$null | Out-Null
    & $nssm remove $ServiceName confirm 2>$null | Out-Null
    Info "Removed service '$ServiceName' (nssm)."
} elseif (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    & sc.exe stop   $ServiceName 2>$null | Out-Null
    & sc.exe delete $ServiceName 2>$null | Out-Null
    Info "Removed service '$ServiceName' (sc)."
} else {
    Info "Service '$ServiceName' not found (nothing to remove)."
}

if ($Purge -and (Test-Path $InstallDir)) {
    try { [System.IO.Directory]::Delete($InstallDir, $true); Info "Deleted $InstallDir." }
    catch { Info "Could not delete $InstallDir ($($_.Exception.Message)) -- a file may be in use." }
}
Info "Done."
