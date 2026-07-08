<#
.SYNOPSIS
    rdp install (sessfix) — deploy the wtf-rdp watchdog + shared module and register
    it as an NSSM LocalSystem service. Downloads a checksum-verified NSSM if needed.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Alias('h')][switch] $Help,
    [string] $InstallDir      = 'C:\ProgramData\wtf-rdp',
    [string] $ServiceName     = 'wtf-rdp-sessfix',
    [string] $TargetUser      = '',
    [int]    $PollIntervalSec = 15,
    [int]    $WedgeConfirmSec = 45,
    [string] $NssmPath        = '',   # use this nssm.exe instead of downloading
    # Default = the known-good SHA256 of the official nssm-2.24.zip, so downloads are
    # verified out of the box. Pass -NssmSha256 '' to skip, or another hash to override.
    [string] $NssmSha256      = '727D1E42275C605E0F04ABA98095C38A8E1E46DEF453CDFFCE42869428AA6743',
    [string] $AssetDir        = '',   # override where Watch-RdpSession.ps1 lives
    [string] $ModulePath      = '',   # override where WtfRdp.Sessions.psm1 lives
    [switch] $NoStart,
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
if ($Help -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp install -- install the wtf-rdp watchdog as an NSSM LocalSystem service.

Usage: rdp install [-TargetUser <name>] [-NssmPath <path>] [-NssmSha256 <hash>]
                   [-PollIntervalSec <n>] [-WedgeConfirmSec <n>] [-NoStart]

  -TargetUser       only ever rescue this user's stranded session (recommended)
  -NssmPath         use this nssm.exe instead of downloading it
  -NssmSha256       pin the nssm-2.24.zip SHA256 for a verified download
  -PollIntervalSec  watchdog poll interval, seconds (default 15)
  -WedgeConfirmSec  how long a wedge must persist before rescue (default 45)
  -InstallDir       install location (default C:\ProgramData\wtf-rdp)
  -NoStart          register the service but do not start it

Requires an elevated (Administrator) shell.
"@
    return
}
$ErrorActionPreference = 'Stop'
function Info($m){ Write-Host "[wtf-rdp] $m" }
# Clean exit for anticipated user errors (no PowerShell stack trace).
function Fail($m){ Write-Host "[wtf-rdp] $m" -ForegroundColor Yellow; exit 1 }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Fail "Administrator required (installing a LocalSystem service). Re-run from an elevated shell."
}

# --- locate the assets to deploy (watchdog + shared module) ---
if (-not $AssetDir)   { $AssetDir   = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\assets')).Path }
if (-not $ModulePath) { $ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\lib\WtfRdp.Sessions.psm1')).Path }
$watchdog = Join-Path $AssetDir 'Watch-RdpSession.ps1'
if (-not (Test-Path $watchdog))   { Fail "watchdog not found: $watchdog (broken install?)" }
if (-not (Test-Path $ModulePath)) { Fail "module not found: $ModulePath (broken install?)" }

New-Item -ItemType Directory -Force $InstallDir | Out-Null

# --- pre-cleanup: stop + remove any existing service FIRST, before we (re)deploy.
# A running service holds a write lock on its own nssm.exe, so a reinstall/reconfigure
# would fail overwriting it unless we stop the service first. Use the already-cached
# nssm if present, else sc.exe; swallow "service doesn't exist" stderr noise. ---
$cachedNssm = Join-Path $InstallDir 'nssm.exe'
if (Test-Path $cachedNssm) {
    try { & $cachedNssm stop   $ServiceName         2>&1 | Out-Null } catch {}
    try { & $cachedNssm remove $ServiceName confirm 2>&1 | Out-Null } catch {}
} else {
    try { & sc.exe stop   $ServiceName 2>&1 | Out-Null } catch {}
    try { & sc.exe delete $ServiceName 2>&1 | Out-Null } catch {}
}
Start-Sleep -Milliseconds 800   # let the SCM release the nssm.exe file handle

# --- obtain nssm.exe: provided path, cached, or download (verified) ---
function Get-Nssm {
    $cached = Join-Path $InstallDir 'nssm.exe'
    if ($NssmPath -and (Test-Path $NssmPath)) { Copy-Item $NssmPath $cached -Force; Info "Using provided NSSM."; return $cached }
    if (Test-Path $cached) { Info "Using cached NSSM."; return $cached }
    Info "Downloading NSSM (nssm.cc/release/nssm-2.24.zip) ..."
    $zip = Join-Path $env:TEMP 'nssm-2.24.zip'
    try {
        Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip -UseBasicParsing
    } catch {
        Fail "Could not download NSSM from nssm.cc ($($_.Exception.Message)). Retry, or pass -NssmPath <nssm.exe>."
    }
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($NssmSha256) {
        if ($hash -ne $NssmSha256) { Fail "NSSM checksum mismatch: got $hash, expected $NssmSha256 (refusing to install)." }
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

# --- register the LocalSystem service (any pre-existing service was removed above) ---
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
