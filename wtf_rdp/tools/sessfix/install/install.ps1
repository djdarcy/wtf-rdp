<#
.SYNOPSIS
    rdp install (sessfix) — deploy the wtf-rdp watchdog + shared module and register
    it as an NSSM LocalSystem service. Downloads a checksum-verified NSSM if needed.
#>
[CmdletBinding()]
param(
    [string] $InstallDir      = 'C:\ProgramData\wtf-rdp',
    [string] $ServiceName     = 'wtf-rdp-sessfix',
    [string] $TargetUser      = '',
    [int]    $PollIntervalSec = 15,
    [int]    $WedgeConfirmSec = 45,
    [string] $NssmPath        = '',   # use this nssm.exe instead of downloading
    [string] $NssmSha256      = '',   # pin the nssm-2.24.zip SHA256 for verified installs
    [string] $AssetDir        = '',   # override where Watch-RdpSession.ps1 lives
    [string] $ModulePath      = '',   # override where WtfRdp.Sessions.psm1 lives
    [switch] $NoStart
)
$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[wtf-rdp] $m" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Administrator required (installing a LocalSystem service). Re-run from an elevated shell."
}

# --- locate the assets to deploy (watchdog + shared module) ---
if (-not $AssetDir)   { $AssetDir   = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\assets')).Path }
if (-not $ModulePath) { $ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\lib\WtfRdp.Sessions.psm1')).Path }
$watchdog = Join-Path $AssetDir 'Watch-RdpSession.ps1'
if (-not (Test-Path $watchdog))   { throw "watchdog not found: $watchdog" }
if (-not (Test-Path $ModulePath)) { throw "module not found: $ModulePath" }

New-Item -ItemType Directory -Force $InstallDir | Out-Null

# --- obtain nssm.exe: provided path, cached, or download (verified) ---
function Get-Nssm {
    $cached = Join-Path $InstallDir 'nssm.exe'
    if ($NssmPath -and (Test-Path $NssmPath)) { Copy-Item $NssmPath $cached -Force; Info "Using provided NSSM."; return $cached }
    if (Test-Path $cached) { Info "Using cached NSSM."; return $cached }
    Info "Downloading NSSM (nssm.cc/release/nssm-2.24.zip) ..."
    $zip = Join-Path $env:TEMP 'nssm-2.24.zip'
    Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($NssmSha256) {
        if ($hash -ne $NssmSha256) { throw "NSSM checksum mismatch: got $hash, expected $NssmSha256" }
        Info "NSSM checksum verified."
    } else {
        Info "NSSM SHA256 = $hash  (pin via -NssmSha256 for verified installs)."
    }
    $ex = Join-Path $env:TEMP 'nssm-2.24-extract'
    Expand-Archive $zip -DestinationPath $ex -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
    Copy-Item (Join-Path $ex "nssm-2.24\$arch\nssm.exe") $cached -Force
    return $cached
}
$nssm = Get-Nssm

# --- deploy (colocate watchdog + module so the watchdog's Import-Module resolves) ---
Copy-Item $watchdog   (Join-Path $InstallDir 'Watch-RdpSession.ps1') -Force
Copy-Item $ModulePath (Join-Path $InstallDir 'WtfRdp.Sessions.psm1')  -Force
Info "Deployed watchdog + module to $InstallDir"

# --- register the LocalSystem service ---
# Pre-cleanup: ignore "service doesn't exist" (nssm writes to stderr, which is
# terminating under ErrorActionPreference=Stop -- swallow it).
try { & $nssm stop   $ServiceName         2>&1 | Out-Null } catch {}
try { & $nssm remove $ServiceName confirm 2>&1 | Out-Null } catch {}
$ps   = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$args = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\Watch-RdpSession.ps1`" -PollIntervalSec $PollIntervalSec -WedgeConfirmSec $WedgeConfirmSec"
if ($TargetUser) { $args += " -TargetUser $TargetUser" }
& $nssm install $ServiceName $ps                                     | Out-Null
& $nssm set $ServiceName AppParameters $args                         | Out-Null
& $nssm set $ServiceName AppDirectory  $InstallDir                   | Out-Null
& $nssm set $ServiceName ObjectName    LocalSystem                   | Out-Null
& $nssm set $ServiceName Start         SERVICE_AUTO_START            | Out-Null
& $nssm set $ServiceName Description    "wtf-rdp session-rescue watchdog" | Out-Null
& $nssm set $ServiceName AppStdout     (Join-Path $InstallDir 'service-stdout.log') | Out-Null
& $nssm set $ServiceName AppStderr     (Join-Path $InstallDir 'service-stderr.log') | Out-Null
Info "Registered '$ServiceName' as LocalSystem (auto-start)."

if (-not $NoStart) {
    & $nssm start $ServiceName | Out-Null
    Start-Sleep 2
    Info "Service status: $((Get-Service $ServiceName -EA SilentlyContinue).Status)"
}
Info "Done. Run 'rdp status' to check, or 'rdp recover' for a manual one-shot rescue."
