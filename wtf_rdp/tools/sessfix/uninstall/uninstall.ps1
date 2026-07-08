<#
.SYNOPSIS
    rdp uninstall (sessfix) — stop and remove the wtf-rdp watchdog service.
    Use -Purge to also delete the install directory.
#>
[CmdletBinding()]
param(
    [string] $ServiceName = 'wtf-rdp-sessfix',
    [string] $InstallDir  = 'C:\ProgramData\wtf-rdp',
    [switch] $Purge
)
$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[wtf-rdp] $m" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Administrator required (removing a service). Re-run from an elevated shell."
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
