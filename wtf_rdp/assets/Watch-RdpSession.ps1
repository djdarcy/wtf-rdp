<#
.SYNOPSIS
    RDP Session-Rescue Watchdog (v0.2) — detects a genuinely wedged console session
    and non-destructively reconnects the stranded user session via `tscon`.

.DESCRIPTION
    Windows client editions can leave a session flagged "blocked by Local Session
    Manager" after an ungraceful RDP disconnect. The only recovery Windows offers
    destroys the session. This watchdog instead reconnects the stranded session:
        tscon <stranded-session-id> /dest:console   (run as SYSTEM)
    which both reconnects the stranded session AND clears the console wedge
    (validated on the real target 2026-07-07).

    DETECTION (v0.2, grounded in real incident-log data):
      A console session in a *connecting* state is NOT enough — a normal idle login
      screen looks identical. So we require CORROBORATION + PERSISTENCE:
        (1) console session state in {Connected, ConnectQuery}, AND
        (2) a recent LSM Event 36 (CsrConnected->EvCsrInitialized transition
            failure, 0x800708CA) — the fingerprint of a dirty-disconnect wedge, AND
        (3) the condition persists past a confirm window (self-recovering
            transitions clear on their own and are ignored).
      Only then do we rescue the stranded (Disconnected, has-user) session.

    RUN AS SYSTEM (host via NSSM as LocalSystem). Cross-user `tscon` requires
    SeTcbPrivilege, which only SYSTEM holds — an elevated admin token does NOT.

.NOTES
    Project: windows-rdp-nonsense.  Design of record:
    private/claude/2026-07-07__18-16-29__(rdp-lsm-block-prevention).md
#>
[CmdletBinding()]
param(
    [int]    $PollIntervalSec      = 15,
    # Wedge must persist this long (console connecting + recent Event 36) before we act.
    [int]    $WedgeConfirmSec      = 45,
    # Optional: only ever rescue THIS user's stranded session. Empty => single-disconnected-user
    # heuristic (refuses to act if ambiguous).
    [string] $TargetUser           = '',
    # Don't re-fire for the same session within this window (anti-thrash).
    [int]    $ReconnectCooldownSec = 120,
    # Observe and log only; never issue tscon.
    [switch] $DryRun,
    # One pass and exit (for testing); default loops forever.
    [switch] $Once,
    # TEST HOOK: if this file exists, treat the wedge as corroborated (bypasses the
    # Event 36 requirement) so the autonomous loop can be validated deterministically.
    # Production leaves this empty and keys only on real Event 36.
    [string] $SimulateWedgeFile = '',
    [string] $LogPath = 'C:\ProgramData\RdpWatchdog\watchdog.log'
)

# --- WTS API session enumeration (robust; avoids qwinsta text parsing) ---
if (-not ([System.Management.Automation.PSTypeName]'Wts.Api').Type) {
Add-Type -Namespace Wts -Name Api -MemberDefinition @'
    [DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern int WTSEnumerateSessions(IntPtr h, int r, int v, ref IntPtr ppSI, ref int c);
    [DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(IntPtr p);
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode)]
    public static extern bool WTSQuerySessionInformation(IntPtr h, int id, int cls, out System.IntPtr pp, out int cnt);
'@
}
$WTS = @{ Active=0; Connected=1; ConnectQuery=2; Shadow=3; Disconnected=4; Idle=5; Listen=6; Reset=7; Down=8; Init=9 }

function Get-WtsSessions {
    $ppSI = [IntPtr]::Zero; $count = 0
    if (-not [Wts.Api]::WTSEnumerateSessions([IntPtr]::Zero, 0, 1, [ref]$ppSI, [ref]$count)) {
        throw "WTSEnumerateSessions failed ($([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    $sessions = @()
    $ptrSize = [IntPtr]::Size
    $structSize = if ($ptrSize -eq 8) { 24 } else { 12 }
    $cur = $ppSI.ToInt64()
    for ($i = 0; $i -lt $count; $i++) {
        $sid   = [Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]$cur)
        $pName = [Runtime.InteropServices.Marshal]::ReadIntPtr([IntPtr]($cur + $(if($ptrSize -eq 8){8}else{4})))
        $state = [Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]($cur + $(if($ptrSize -eq 8){16}else{8})))
        $name  = [Runtime.InteropServices.Marshal]::PtrToStringUni($pName)
        $pp=[IntPtr]::Zero; $cnt=0; $user=''
        if ([Wts.Api]::WTSQuerySessionInformation([IntPtr]::Zero, $sid, 5, [ref]$pp, [ref]$cnt)) { # 5 = WTSUserName
            $user = [Runtime.InteropServices.Marshal]::PtrToStringUni($pp); [Wts.Api]::WTSFreeMemory($pp)
        }
        $sessions += [pscustomobject]@{ Id=$sid; WinStation=$name; User=$user; State=$state
            StateName = ($WTS.GetEnumerator() | Where-Object { $_.Value -eq $state } | Select-Object -First 1 -Expand Key) }
        $cur += $structSize
    }
    [Wts.Api]::WTSFreeMemory($ppSI)
    $sessions
}

# LSM Event 36 = CsrConnected->EvCsrInitialized transition failure (dirty-disconnect wedge fingerprint).
# Returns the SessionIds that logged a transition failure within the lookback window.
function Get-RecentWedgeEventSids([int]$lookbackSec) {
    $start = (Get-Date).AddSeconds(-$lookbackSec)
    $ev = $null
    try {
        $ev = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id=36; StartTime=$start
        } -ErrorAction Stop
    } catch { return @() }   # "No events were found" -> empty
    $sids = @()
    foreach ($e in $ev) {
        try { $xml=[xml]$e.ToXml()
              $sid = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'SessionId' }).'#text'
              if ($null -ne $sid) { $sids += [int]$sid } } catch {}
    }
    ,($sids | Select-Object -Unique)
}

function Write-Log([string]$msg, [string]$level='INFO') {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    try { $dir = Split-Path $LogPath; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
          Add-Content -Path $LogPath -Value $line } catch {}
    Write-Output $line
}

$script:wedgeSince    = $null
$script:lastReconnect = @{}

function Invoke-WatchdogPass {
    $s = Get-WtsSessions
    $console = $s | Where-Object { $_.WinStation -eq 'console' } | Select-Object -First 1
    if (-not $console) { $script:wedgeSince = $null; return }

    # (1) console must be in a connecting state
    if ($console.State -notin @($WTS.Connected, $WTS.ConnectQuery)) {
        if ($script:wedgeSince) { Write-Log "console recovered to '$($console.StateName)'; clearing wedge watch." }
        $script:wedgeSince = $null; return
    }

    # (2) corroborate with a recent transition-failure event (distinguishes a real wedge
    #     from a benign idle login screen, which is ALSO in a connecting state)
    $lookback = $WedgeConfirmSec + $PollIntervalSec + 30
    $wedgeSids = @(Get-RecentWedgeEventSids $lookback)
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

    # --- confirmed wedge: choose the stranded user session to reconnect ---
    $stranded = @($s | Where-Object { $_.User -and $_.State -eq $WTS.Disconnected -and $_.WinStation -ne 'services' })
    if ($TargetUser) { $stranded = @($stranded | Where-Object { $_.User -ieq $TargetUser }) }
    if ($stranded.Count -eq 0) { Write-Log "wedge confirmed ${stuckSec}s but no stranded user session to reconnect; no-op." 'WARN'; return }
    if ($stranded.Count -gt 1) { Write-Log "wedge confirmed but MULTIPLE stranded sessions ($(($stranded.User) -join ', ')); ambiguous -> set -TargetUser; no-op." 'WARN'; return }
    $t = $stranded[0]

    $last = $script:lastReconnect[$t.Id]
    if ($last -and ((Get-Date) - $last).TotalSeconds -lt $ReconnectCooldownSec) { return }

    Write-Log "RESCUE: wedge confirmed ${stuckSec}s; reconnecting stranded session $($t.Id) ($($t.User)) -> console." 'ACTION'
    if ($DryRun) { Write-Log "[DryRun] would run: tscon $($t.Id) /dest:console" 'ACTION'; return }

    $out = & tscon.exe $t.Id /dest:console 2>&1
    $script:lastReconnect[$t.Id] = Get-Date
    if ($LASTEXITCODE -eq 0) { Write-Log "tscon OK: session $($t.Id) ($($t.User)) reconnected to console." 'ACTION'; $script:wedgeSince = $null }
    else { Write-Log "tscon FAILED (exit $LASTEXITCODE): $out" 'ERROR' }
}

# --- run ---
Write-Log ("RDP Session-Rescue Watchdog v0.2 starting. identity={0} poll={1}s confirm={2}s dryrun={3} target='{4}'" -f `
    [Security.Principal.WindowsIdentity]::GetCurrent().Name, $PollIntervalSec, $WedgeConfirmSec, $DryRun.IsPresent, $TargetUser)
do {
    try { Invoke-WatchdogPass } catch { Write-Log "pass error: $($_.Exception.Message)" 'ERROR' }
    if (-not $Once) { Start-Sleep -Seconds $PollIntervalSec }
} while (-not $Once)
