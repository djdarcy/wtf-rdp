<#
.SYNOPSIS
    rdp recover (sessfix) — manual one-shot safe rescue: reconnect + LOCK a stranded
    session now (no waiting for the watchdog). Self-elevates to SYSTEM (the rescue
    needs SeTcbPrivilege + WTSQueryUserToken).
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Alias('h')][switch] $Help,
    [string] $TargetUser  = '',
    [int]    $SessionId   = 0,
    [string] $ModulePath  = '',
    [switch] $AsSystem,        # internal: the SYSTEM-elevated pass
    [string] $ResultFile  = '',
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
if ($Help -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp recover -- manually reconnect + lock a stranded RDP session now.

Usage: rdp recover [-TargetUser <name>] [-SessionId <id>]

  -TargetUser   only consider this user's stranded session
  -SessionId    recover this specific session id (else the single stranded one)

Finds the stranded (disconnected) user session, reconnects it to the console
via tscon, and LOCKS it. Self-elevates to SYSTEM. Requires an elevated shell.
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
if (-not $ModulePath) { Fail "WtfRdp.Sessions module not found -- run 'rdp install' first." }
if (-not (Test-Path $ModulePath)) { Fail "module not found at: $ModulePath" }
Import-Module $ModulePath -Force

function Find-Stranded {
    $st = @(Get-WtfRdpSession | Where-Object { $_.User -and $_.StateName -eq 'Disconnected' -and $_.WinStation -ne 'services' })
    if ($TargetUser) { $st = @($st | Where-Object { $_.User -ieq $TargetUser }) }
    $st
}

# --- SYSTEM-elevated pass: do the actual rescue ---
if ($AsSystem) {
    if ($SessionId -le 0) { $st = Find-Stranded; if ($st.Count -eq 1) { $SessionId = $st[0].Id } }
    if ($SessionId -le 0) { '{"error":"no unambiguous stranded session"}' | Set-Content $ResultFile; return }
    (Invoke-WtfRdpRescue -SessionId $SessionId | ConvertTo-Json) | Set-Content $ResultFile
    return
}

# --- user/admin pass: resolve the target, then elevate to SYSTEM via a one-shot task ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Fail "Administrator required (the rescue runs as SYSTEM). Re-run from an elevated shell."
}
if ($SessionId -le 0) {
    $st = Find-Stranded
    if ($st.Count -eq 0) { Write-Host "[wtf-rdp] No stranded (disconnected) user session to recover."; return }
    if ($st.Count -gt 1) { Write-Host "[wtf-rdp] Multiple stranded sessions: $(($st.User) -join ', '). Pass -SessionId or -TargetUser."; return }
    $SessionId = $st[0].Id
}
Write-Host "[wtf-rdp] Recovering session $SessionId (reconnect + lock) as SYSTEM..."
$rf   = Join-Path $env:TEMP ("wtfrdp_recover_{0}.json" -f [guid]::NewGuid().ToString('N'))
$self = $PSCommandPath
$argstr = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -AsSystem -SessionId $SessionId -ModulePath `"$ModulePath`" -ResultFile `"$rf`""
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argstr
Register-ScheduledTask -TaskName 'WtfRdpRecover' -Action $act -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'WtfRdpRecover'
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not (Test-Path $rf)) { Start-Sleep -Milliseconds 400 }
Start-Sleep 1
Unregister-ScheduledTask -TaskName 'WtfRdpRecover' -Confirm:$false
if (Test-Path $rf) {
    $res = Get-Content $rf -Raw | ConvertFrom-Json
    [System.IO.File]::Delete($rf)
    if ($res.Reconnected) { Write-Host "[wtf-rdp] Recovered session $($res.SessionId): reconnected, locked=$($res.Locked)." }
    else { Write-Host "[wtf-rdp] Recovery failed: $($res.error)$($res.TsconOutput)" }
} else {
    Write-Host "[wtf-rdp] Recovery timed out (no result from the SYSTEM task)."
}
