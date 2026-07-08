<#
.SYNOPSIS
    rdp logs (sessfix) — view the watchdog log (or the NSSM service stdout/stderr).
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Alias('h')][switch] $Help,
    [string] $InstallDir = 'C:\ProgramData\wtf-rdp',
    [int]    $Tail       = 40,
    [switch] $Follow,
    [switch] $Full,
    [switch] $Service,   # show the NSSM service stdout/stderr instead of watchdog.log
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
if ($Help -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp logs -- view the wtf-rdp watchdog log.

Usage: rdp logs [-Tail <n>] [-Follow] [-Full] [-Service]

  -Tail <n>   show the last n lines (default 40)
  -Follow     stream new lines as they are written (Ctrl-C to stop)
  -Full       print the entire log instead of the tail
  -Service    show the NSSM service stdout/stderr logs instead of watchdog.log

Read-only; no admin required.
"@
    return
}
$ErrorActionPreference = 'Stop'

if ($Service) {
    foreach ($f in 'service-stdout.log','service-stderr.log') {
        $p = Join-Path $InstallDir $f
        Write-Host "===== $f ====="
        if (Test-Path $p) { Get-Content $p -Tail $Tail -ErrorAction SilentlyContinue }
        else { Write-Host "(not present)" }
        Write-Host ""
    }
    return
}

$log = Join-Path $InstallDir 'watchdog.log'
if (-not (Test-Path $log)) {
    Write-Host "[wtf-rdp] No watchdog log at $log (is the service installed and has it run yet? 'rdp status')."
    return
}

if ($Full) {
    Get-Content $log
} elseif ($Follow) {
    Write-Host "[wtf-rdp] Following $log (Ctrl-C to stop)..."
    Get-Content $log -Tail $Tail -Wait
} else {
    Get-Content $log -Tail $Tail
}
