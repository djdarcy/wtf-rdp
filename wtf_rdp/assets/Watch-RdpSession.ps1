<#
.SYNOPSIS
    wtf-rdp session-rescue watchdog (v0.3) — detects a wedged console session and
    non-destructively reconnects + LOCKS the stranded user session.

.DESCRIPTION
    Hosted by NSSM as a LocalSystem service (`rdp setup sessfix`). The rescue logic
    lives in the shared WtfRdp.Sessions module (colocated at install), so the
    watchdog and `rdp recover` behave identically.

    Detection (event-driven + state-confirm): a console session in a *connecting*
    state, corroborated by a recent LSM Event 36 (dirty-disconnect wedge), that
    persists past a confirm window. Rescue = `tscon` reconnect + lock (never signs
    the session out). Runs as SYSTEM (SeTcbPrivilege for cross-user tscon;
    WTSQueryUserToken for the lock).
#>
[CmdletBinding()]
param(
    [int]    $PollIntervalSec      = 15,
    [int]    $WedgeConfirmSec      = 45,
    [string] $TargetUser           = '',
    [int]    $ReconnectCooldownSec = 120,
    [switch] $DryRun,
    [switch] $Once,
    # TEST HOOK: if this file exists, treat the wedge as corroborated (bypasses the
    # Event 36 requirement) for deterministic testing. Empty in production.
    [string] $SimulateWedgeFile    = '',
    [string] $LogPath              = 'C:\ProgramData\wtf-rdp\watchdog.log',
    # Shared session module; defaults to a copy colocated with this script.
    [string] $ModulePath           = ''
)

if (-not $ModulePath) { $ModulePath = Join-Path $PSScriptRoot 'WtfRdp.Sessions.psm1' }
Import-Module $ModulePath -Force

function Write-Log([string]$msg, [string]$level='INFO') {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    try { $dir = Split-Path $LogPath; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
          Add-Content -Path $LogPath -Value $line } catch {}
    Write-Output $line
}

$script:wedgeSince    = $null
$script:lastReconnect = @{}

function Invoke-WatchdogPass {
    $s = Get-WtfRdpSession
    $console = $s | Where-Object { $_.WinStation -eq 'console' } | Select-Object -First 1
    if (-not $console) { $script:wedgeSince = $null; return }

    # (1) console must be in a connecting state
    if ($console.StateName -notin @('Connected','ConnectQuery')) {
        if ($script:wedgeSince) { Write-Log "console recovered to '$($console.StateName)'; clearing wedge watch." }
        $script:wedgeSince = $null; return
    }

    # (2) corroborate with a recent LSM transition-failure event (distinguishes a real
    #     wedge from a benign idle login screen, which is ALSO in a connecting state)
    $lookback = $WedgeConfirmSec + $PollIntervalSec + 30
    $wedgeSids = @(Get-WtfRdpWedgeEventSid -LookbackSec $lookback)
    if ($SimulateWedgeFile -and (Test-Path $SimulateWedgeFile)) {
        if ($wedgeSids.Count -eq 0) { Write-Log "[TEST] SimulateWedgeFile present -> corroborating a synthetic wedge." 'WARN' }
        $wedgeSids = @(-1) + $wedgeSids
    }
    if ($wedgeSids.Count -eq 0) {
        if ($script:wedgeSince) { Write-Log "console connecting but no recent Event 36 -> benign; clearing wedge watch." }
        $script:wedgeSince = $null; return
    }

    # (3) persistence / confirm window
    if (-not $script:wedgeSince) {
        $script:wedgeSince = Get-Date
        Write-Log "WEDGE CANDIDATE: console (sid $($console.Id), '$($console.StateName)') + recent Event 36 (sids: $($wedgeSids -join ','))." 'WARN'
    }
    $stuckSec = [int]((Get-Date) - $script:wedgeSince).TotalSeconds
    if ($stuckSec -lt $WedgeConfirmSec) { return }

    # --- confirmed wedge: choose the stranded user session ---
    $stranded = @($s | Where-Object { $_.User -and $_.StateName -eq 'Disconnected' -and $_.WinStation -ne 'services' })
    if ($TargetUser) { $stranded = @($stranded | Where-Object { $_.User -ieq $TargetUser }) }
    if ($stranded.Count -eq 0) { Write-Log "wedge confirmed ${stuckSec}s but no stranded user session; no-op." 'WARN'; return }
    if ($stranded.Count -gt 1) { Write-Log "wedge confirmed but MULTIPLE stranded sessions ($(($stranded.User) -join ', ')); ambiguous -> set -TargetUser; no-op." 'WARN'; return }
    $t = $stranded[0]

    $last = $script:lastReconnect[$t.Id]
    if ($last -and ((Get-Date) - $last).TotalSeconds -lt $ReconnectCooldownSec) { return }

    Write-Log "RESCUE: wedge confirmed ${stuckSec}s; reconnecting + locking stranded session $($t.Id) ($($t.User))." 'ACTION'
    if ($DryRun) { Write-Log "[DryRun] would run: Invoke-WtfRdpRescue -SessionId $($t.Id)" 'ACTION'; return }

    $res = Invoke-WtfRdpRescue -SessionId $t.Id
    $script:lastReconnect[$t.Id] = Get-Date
    if ($res.Verified) {
        Write-Log "RESCUE OK: session $($t.Id) ($($t.User)) reconnected and HELD $($res.VerifySec)s; locked=$($res.Locked)." 'ACTION'
        if (-not $res.Locked) { Write-Log "WARNING: reconnected but lock failed -- session may be exposed." 'WARN' }
        $script:wedgeSince = $null   # clear the wedge watch only when the reconnect actually held
    } elseif ($res.Reconnected -and $res.Status -eq 'decayed') {
        Write-Log "RESCUE INEFFECTIVE: session $($t.Id) reconnected but DECAYED back to disconnected -- hardened LSM block (tscon cannot clear it; needs reboot/prevention). Will retry after cooldown." 'ERROR'
    } elseif ($res.Reconnected) {
        Write-Log "RESCUE UNCONFIRMED: session $($t.Id) tscon ok but not verified (status=$($res.Status), final=$($res.FinalState))." 'WARN'
    } else {
        Write-Log "RESCUE FAILED (tscon): $($res.TsconOutput)" 'ERROR'
    }
}

Write-Log ("wtf-rdp watchdog v0.3 starting. identity={0} poll={1}s confirm={2}s dryrun={3} target='{4}'" -f `
    [Security.Principal.WindowsIdentity]::GetCurrent().Name, $PollIntervalSec, $WedgeConfirmSec, $DryRun.IsPresent, $TargetUser)
do {
    try { Invoke-WatchdogPass } catch { Write-Log "pass error: $($_.Exception.Message)" 'ERROR' }
    if (-not $Once) { Start-Sleep -Seconds $PollIntervalSec }
} while (-not $Once)
