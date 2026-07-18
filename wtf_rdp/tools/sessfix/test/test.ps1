<#
.SYNOPSIS
    rdp test (sessfix) -- reproduce, detect, and VISUALLY VERIFY the LSM console-session
    arbitration block. THREE modes:

      rdp test client -RdpHost <server> -TargetUser <console-owner> ...
                                  run on a CLIENT: reproduce the block with the confirmed recipe,
                                  read the verdict on the server over WinRM (if -HostUser), and
                                  visually verify + screenshot the block screen (unless -NoVerify).
      rdp test verify -RdpHost <server> -TargetUser <user> [-PasswordFile <f>]
                                  NON-DESTRUCTIVE spot-check: connect once, capture the session
                                  window, and report Blocked=True/False from the pixel signature
                                  (saves a PNG). Never clicks "Yes" (which would sign out the block).
      rdp test server [-Watch]    run on the SERVER (the RDP host): detect via the local LSM log.

    The block = a stuck LSM arbitration (Operational Id=41 with no completing Id=42). NOT Event 36.

    RECIPE (client): a console-owner admin account (SUSPECTED necessary -- not yet confirmed with the
    new tooling; see NOTE) + mstsc /admin + overlapping establish (no loss) + a SILENT packet blackhole
    (clumsy 100% drop) so connections time out with error 0x800705F9 mid-arbitration + NEVER kill the
    client. The block itself is reproduced on demand; the repro is timing-sensitive (retry). Loopback unsupported.

    PIXEL VERIFY: the block message is rendered in the REMOTE RDP framebuffer (a bitmap, not a Win32
    control), so we capture the session window's client area and score it: near-black below the title
    bar + white text in the lower half == the LSM block screen. Calibrated: blocked meanLum~6 vs a
    live desktop ~65.

.DANGER  client mode strands -TargetUser's session (reboot/logoff-only). Needs clumsy.exe (winget
    install Jagt.Clumsy) and an elevated shell.

.NOTES  -SignOut clears a confirmed block destructively: -SignOutMethod winrm (server-side logoff) is
    PROVEN; -SignOutMethod input (keyboard Tab/Enter into the session) and -Auto are EXPERIMENTAL and
    NOT YET VALIDATED against a real block. The block screen is a remote framebuffer, so the earlier
    BM_CLICK approach does not work; the input method sends real keystrokes instead (unconfirmed).

.VERSION 0.4.0 (tool).
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string] $Mode = '',
    [Alias('h')][switch] $Help,
    # shared
    [string] $RdpHost      = '',
    [string] $TargetUser   = '',
    [string] $PasswordFile = '',
    [string] $HostUser     = '',
    [string] $HostPasswordFile = '',
    [string] $ClumsyPath   = '',
    [switch] $Json,
    # client
    [int]    $N            = 10,
    [int]    $Waves        = 2,
    [int]    $EstablishSec = 12,
    [int]    $BlackholeSec = 90,
    [int]    $SettleSec    = 25,
    [int]    $ClickSec     = 8,
    [switch] $StopGuard,
    [switch] $NoVerify,       # client: skip the visual block-screen verify at the end
    [switch] $Force,          # client: proceed even if the pre-storm baseline shows the session is ALREADY blocked (run is detect-only)
    [switch] $SignOut,        # client/verify: OPT-IN DESTRUCTIVE clear of a verify-CONFIRMED block (destroys the session's state). Never default. See -SignOutMethod.
    [switch] $Auto,           # client: [EXPERIMENTAL/UNVALIDATED] hands-off CREATE proof -- if pre-blocked, sign out FIRST for a CLEAN baseline, then storm+verify (implies -Force). DESTRUCTIVE. Depends on -SignOut input, which is unproven.
    [ValidateSet('input','winrm')][string] $SignOutMethod = 'input',  # 'winrm'=server-side logoff (PROVEN; needs -HostUser/WinRM). 'input'=[EXPERIMENTAL/UNVALIDATED] keyboard Tab/Enter into the RDP session (no server config; not yet confirmed to clear a real block).
    # verify
    [string] $OutDir       = '',
    [int]    $VerifyWaitSec = 24,
    # server
    [switch] $Watch,
    [int]    $LookbackMin  = 10,
    [string] $ModulePath   = '',
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
$ErrorActionPreference = 'Stop'
function Fail($m){ Write-Host "[wtf-rdp] $m" -ForegroundColor Yellow; exit 1 }
function Say($m){ if (-not $Json) { Write-Host $m } }

if ($Help -or $Mode -in @('-h','--help','/?','help') -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp test -- reproduce + detect + visually verify the LSM session-arbitration block.

Usage:
  rdp test client -RdpHost <server> -TargetUser <console-owner> [-PasswordFile <f>]
                  [-HostUser <winrm-acct> -HostPasswordFile <f>]  read the server verdict via WinRM
                  [-N 10] [-Waves 2] [-BlackholeSec 90] [-StopGuard] [-NoVerify]
  rdp test verify -RdpHost <server> -TargetUser <user> [-PasswordFile <f>] [-OutDir <dir>]
                  NON-DESTRUCTIVE: connect once, capture the session window, report Blocked + save PNG.
  rdp test server [-Watch] [-LookbackMin 10] [-Json]              run ON the RDP host

client: console-OWNER account + mstsc /admin + overlapping establish (no loss) + silent blackhole
  (clumsy 100% drop) so connections time out (0x800705F9) mid-arbitration -- never killing the client.
  Reads the host verdict over WinRM (-HostUser) and visually verifies the block screen (unless -NoVerify).

verify: fires one /admin connect, grabs the session window, and scores the pixels (near-black + white
  text == blocked). Saves a PNG. Never clicks "Yes" (that signs out the block). Good for spot-checks.

DANGER: client mode strands -TargetUser (reboot/logoff-only). clumsy.exe + elevated shell required.
"@
    return
}

# ================================ shared: clicker + capture (Win32) ================================
if (-not ([System.Management.Automation.PSTypeName]'WtfRdpTest.Ui').Type) {
Add-Type -ReferencedAssemblies System -TypeDefinition @"
using System; using System.Text; using System.Diagnostics; using System.Runtime.InteropServices;
namespace WtfRdpTest { public class Ui {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  const uint BM_CLICK = 0x00F5;
  static string T(IntPtr h){ var s=new StringBuilder(512); GetWindowText(h,s,512); return s.ToString(); }
  static string C(IntPtr h){ var s=new StringBuilder(256); GetClassName(h,s,256); return s.ToString(); }
  // click the FIRST button whose text starts with any of bt, in any visible mstsc window
  public static string ClickIn(string proc, string[] bt){ string r=null;
    EnumWindows((h,x)=>{ if(!IsWindowVisible(h)) return true; uint pid; GetWindowThreadProcessId(h,out pid);
      try{ if(!string.Equals(Process.GetProcessById((int)pid).ProcessName,proc,StringComparison.OrdinalIgnoreCase)) return true; }catch{ return true; }
      IntPtr f=IntPtr.Zero; string ft=null;
      EnumChildWindows(h,(c,y)=>{ if(C(c)=="Button"){ string ct=T(c).Replace("&","").Trim(); foreach(var b in bt){ if(ct.StartsWith(b,StringComparison.OrdinalIgnoreCase)){ f=c; ft=ct; return false; } } } return true; },IntPtr.Zero);
      if(f!=IntPtr.Zero){ SendMessage(f,BM_CLICK,IntPtr.Zero,IntPtr.Zero); r="clicked ["+ft+"]"; return false; } return true; },IntPtr.Zero); return r; }
  // find the mstsc window whose title contains sub (the session window title has the host; the
  // security-warning / connecting windows do not)
  public static IntPtr FindByTitle(string sub){ IntPtr found=IntPtr.Zero; string s=sub.ToLower();
    EnumWindows((h,x)=>{ if(!IsWindowVisible(h)) return true; uint pid; GetWindowThreadProcessId(h,out pid);
      try{ if(!string.Equals(Process.GetProcessById((int)pid).ProcessName,"mstsc",StringComparison.OrdinalIgnoreCase)) return true; }catch{ return true; }
      if(T(h).ToLower().Contains(s)){ found=h; return false; } return true; },IntPtr.Zero); return found; }
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  // Send keystrokes INTO the focused window -> forwarded to the RDP SESSION. The LSM block screen is a remote
  // framebuffer (no local Win32 button for BM_CLICK), so we reach its on-screen sign-out control with real
  // keyboard input: Tab to move focus to the button, Enter to activate. Client-side; needs no server config.
  public static void SendTabEnter(IntPtr h, int tabs){ SetForegroundWindow(h); System.Threading.Thread.Sleep(400);
    for(int i=0;i<tabs;i++){ keybd_event(0x09,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(90); keybd_event(0x09,0,2,IntPtr.Zero); System.Threading.Thread.Sleep(140); }
    keybd_event(0x0D,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(90); keybd_event(0x0D,0,2,IntPtr.Zero); System.Threading.Thread.Sleep(140); }
} }
"@
}

# ================================ shared: module + WinRM ================================
function Resolve-Module {
    if ($ModulePath -and (Test-Path $ModulePath)) { return $ModulePath }
    $c = @('C:\ProgramData\wtf-rdp\WtfRdp.Sessions.psm1', (Join-Path $PSScriptRoot '..\..\..\lib\WtfRdp.Sessions.psm1'))
    $c | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$HostDetectSb = {
    param($mins)
    $lo = (Get-Date).AddMinutes(-$mins)
    $ev = Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -EA SilentlyContinue |
          Where-Object { $_.TimeCreated -ge $lo }
    $b = @($ev | Where-Object { $_.Id -eq 41 }).Count
    $e = @($ev | Where-Object { $_.Id -eq 42 }).Count
    $stuck = [Math]::Max(0, $b - $e)
    $errTimeouts = @($ev | Where-Object { $_.Id -eq 40 -and $_.Message -match '2147942521|0x800705F9' }).Count
    $liveSibs = @(((qwinsta 2>&1 | Out-String) -split "`r?`n") | Where-Object { $_ -match 'rdp-tcp#' }).Count
    [pscustomobject]@{ Begin=$b; End=$e; Stuck=$stuck; ErrTimeouts=$errTimeouts; LiveSiblings=$liveSibs }
}
function New-HostSession {
    if (-not $HostUser) { return $null }
    if (-not $HostPasswordFile -or -not (Test-Path $HostPasswordFile)) { Fail "-HostPasswordFile required (and must exist) when -HostUser is set." }
    $pw = (Get-Content $HostPasswordFile -Raw).Trim()
    $cred = New-Object System.Management.Automation.PSCredential($HostUser, (ConvertTo-SecureString $pw -AsPlainText -Force))
    $pw = $null
    $opt = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 25000 -CancelTimeout 5000
    New-PSSession -ComputerName $RdpHost -Credential $cred -SessionOption $opt -ErrorAction Stop
}

# ================================ shared: cred + small windowed /admin .rdp ================================
function Set-TargetCred {
    cmdkey /delete:TERMSRV/$RdpHost 2>$null | Out-Null
    if ($PasswordFile) {
        if (-not (Test-Path $PasswordFile)) { Fail "PasswordFile not found: $PasswordFile" }
        $tp = (Get-Content $PasswordFile -Raw).Trim()
        cmdkey /generic:TERMSRV/$RdpHost /user:$TargetUser /pass:$tp | Out-Null; $tp = $null
    }
}
function New-AdminRdp {
    $p = Join-Path $env:TEMP ("wtfrdp_test_{0}.rdp" -f ($TargetUser -replace '[\\/:]','_'))
    # screen mode id:i:1 = WINDOWED + a small fixed desktop so mstsc does NOT take over the screen
    # (much friendlier for a tester watching many spawns) and the block screen is a capturable window
    @("full address:s:$RdpHost","username:s:$TargetUser","authentication level:i:0","prompt for credentials:i:0",
      "administrative session:i:1","screen mode id:i:1","desktopwidth:i:800","desktopheight:i:600") -join "`r`n" |
      Set-Content $p -Encoding Ascii
    $p
}

# ================================ shared: pixel block-screen verify (non-destructive) ================================
# Fires one /admin connect, clicks ONLY 'Connect' (never 'Yes' -- that signs out the block), grabs the
# session window by title, screen-captures its client area, and scores the LSM block signature. Returns
# an object; saves a PNG. Requires the caller to have set the TERMSRV cred + built the .rdp.
function Invoke-BlockScreenVerify {
    param([string]$RdpFile, [string]$OutPng)
    Add-Type -AssemblyName System.Drawing
    Get-Process mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 1
    Start-Process mstsc.exe -ArgumentList "`"$RdpFile`""
    $h = [IntPtr]::Zero
    $dl = (Get-Date).AddSeconds($VerifyWaitSec)
    while ((Get-Date) -lt $dl) {
        [WtfRdpTest.Ui]::ClickIn('mstsc', @('Connect')) | Out-Null
        $cand = [WtfRdpTest.Ui]::FindByTitle($RdpHost)
        if ($cand -ne [IntPtr]::Zero) { $h = $cand; break }
        Start-Sleep -Milliseconds 400
    }
    if ($h -eq [IntPtr]::Zero) {
        Get-Process mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        return [pscustomobject]@{ Blocked=$false; Inconclusive=$true; PureBlackPct='n/a'; LowerBrightPct='n/a'; Png=$null; Note='no session window (never connected / connected to desktop and closed) -- state UNKNOWN, NOT a confirmed clear' }
    }
    Start-Sleep 5   # let the black block screen fully paint (window lives ~t=3-12s before mstsc exits on a block)
    [void][WtfRdpTest.Ui]::SetWindowPos($h, [IntPtr](-1), 0,0,0,0, (0x1 -bor 0x2 -bor 0x40))   # HWND_TOPMOST
    [void][WtfRdpTest.Ui]::SetForegroundWindow($h); Start-Sleep -Milliseconds 600
    $cr = New-Object WtfRdpTest.Ui+RECT; [void][WtfRdpTest.Ui]::GetClientRect($h,[ref]$cr)
    $w = $cr.R-$cr.L; $ht = $cr.B-$cr.T
    $blocked=$false; $meanUp='n/a'; $lowerPct='n/a'
    if ($w -gt 0 -and $ht -gt 0) {
        $pt = New-Object WtfRdpTest.Ui+POINT; [void][WtfRdpTest.Ui]::ClientToScreen($h,[ref]$pt)
        $bmp = New-Object System.Drawing.Bitmap($w,$ht)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($pt.X,$pt.Y,0,0,(New-Object System.Drawing.Size($w,$ht))); $g.Dispose()
        # ROBUST statistical signature: PURE-BLACK COVERAGE. The LSM block screen is a large near-pure-
        # black field (>=70% of pixels below the title bar have lum<15) with white text in the lower
        # half. A dark editor (Sublime / VS Code) is dark-GREY, not pure black -- only ~0-5% of its
        # pixels are lum<15 -- so it cannot reach the 70% threshold no matter how dark its theme.
        # Calibrated: block pureBlack~97%, dark desktop ~0-0.2%. This is a ratio guard, not an absolute cutoff.
        $top=[int]($ht*0.12); $lowerY=[int]($ht*0.50)
        $pb=0; $nAll=0; $lb=0; $lt=0
        for ($y=$top; $y -lt $ht; $y+=3) { for ($x=0; $x -lt $w; $x+=6) {
            $c=$bmp.GetPixel($x,$y); $l=(0.299*$c.R+0.587*$c.G+0.114*$c.B); $nAll++
            if ($l -lt 15) { $pb++ }
            if ($y -ge $lowerY) { $lt++; if ($l -gt 180) { $lb++ } } } }
        $meanUp=[math]::Round(100.0*$pb/[math]::Max(1,$nAll),1)   # pure-black coverage %
        $lowerPct=[math]::Round(100.0*$lb/[math]::Max(1,$lt),3)
        # verdict via the exported (unit-tested) module fn; inline fallback keeps client mode self-contained
        if (-not (Get-Command Get-WtfRdpBlockScreenVerdict -EA SilentlyContinue)) {
            $mp = Resolve-Module; if ($mp) { Import-Module $mp -Force -EA SilentlyContinue }
        }
        $blocked = if (Get-Command Get-WtfRdpBlockScreenVerdict -EA SilentlyContinue) {
            Get-WtfRdpBlockScreenVerdict -PureBlackPct $meanUp -LowerBrightPct $lowerPct
        } else { ($meanUp -ge 70 -and $lowerPct -gt 0.1) }
        if ($OutPng) { $bmp.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png) }
        $bmp.Dispose()
    }
    Get-Process mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    [pscustomobject]@{ Blocked=$blocked; Inconclusive=$false; PureBlackPct=$meanUp; LowerBrightPct=$lowerPct; Png=$OutPng; Note=$null }
}

# DESTRUCTIVE sign-out clear (shared by client + verify; caller must confirm the block AND the operator's
# explicit -SignOut). Connects and clicks the block's "sign out" -> "Yes" to LOG THE SESSION OFF, which
# releases the block without a reboot but PERMANENTLY DISCARDS its state. Uses the script-scope creds/host.
function Invoke-SignOutClear {
    param([ValidateSet('input','winrm')][string]$Method = 'input')
    if ($Method -eq 'winrm') {
        # RELIABLE, but requires WinRM configured on the host -- NOT assumable for an MSRC repro. Server-side logoff.
        if (-not $HostUser -or -not $HostPasswordFile) { Say "[wtf-rdp] -SignOutMethod winrm needs -HostUser/-HostPasswordFile."; return }
        $hsx = New-HostSession
        if (-not $hsx) { Say "[wtf-rdp] winrm sign-out: could not open a host session."; return }
        try {
            $u = ($TargetUser -split '\\')[-1]
            $r = Invoke-Command -Session $hsx -ArgumentList $u {
                param($u)
                $q = (qwinsta 2>&1 | Out-String) -split "`r?`n"
                $row = $q | Where-Object { $_ -match "\b$u\b" } | Select-Object -First 1
                if ($row -and $row -match '\s(\d+)\s+(Active|Disc|Conn)') { logoff $matches[1] 2>&1 | Out-Null; "logged off session $($matches[1])" } else { "no session found for $u" }
            }
            Say "[wtf-rdp] winrm sign-out: $r"
        } finally { Remove-PSSession $hsx }
        return
    }
    # DEFAULT client-side clear (needs NO server config): connect, then send real keyboard Tab/Enter INTO the
    # session to reach the block screen's sign-out control (a remote-framebuffer button -- BM_CLICK can't hit it).
    Set-TargetCred
    $soRdp = New-AdminRdp
    try {
        Get-Process mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 1
        Start-Process mstsc.exe -ArgumentList "`"$soRdp`""
        $h = [IntPtr]::Zero; $dl = (Get-Date).AddSeconds($VerifyWaitSec)
        while ((Get-Date) -lt $dl) {
            [WtfRdpTest.Ui]::ClickIn('mstsc', @('Connect')) | Out-Null   # get past the connect dialog only (never 'Yes' here)
            $c = [WtfRdpTest.Ui]::FindByTitle($RdpHost); if ($c -ne [IntPtr]::Zero) { $h = $c; break }
            Start-Sleep -Milliseconds 400
        }
        if ($h -ne [IntPtr]::Zero) {
            Start-Sleep 4   # let the block screen paint
            foreach ($t in 0,1,2,3) { [WtfRdpTest.Ui]::SendTabEnter($h, $t); Start-Sleep 2 }   # try a few Tab counts to land on the button
        } else { Say "[wtf-rdp] sign-out(input): no session window appeared to send keys to." }
        Get-Process mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 3
    } finally {
        cmdkey /delete:TERMSRV/$RdpHost 2>$null | Out-Null
        if (Test-Path $soRdp) { Remove-Item $soRdp -Force -EA SilentlyContinue }
    }
}

# ================================ SERVER MODE ================================
if ($Mode -ieq 'server') {
    $mp = Resolve-Module
    if (-not $mp) { Fail "WtfRdp.Sessions module not found -- run 'rdp install' first, or pass -ModulePath." }
    Import-Module $mp -Force
    do {
        $d = Get-WtfRdpArbitrationBlock -LookbackMin $LookbackMin
        if ($Json) { $d | ConvertTo-Json -Depth 4 }
        else {
            $tag = if ($d.Blocked) { "[X] BLOCKED" } else { "[OK] clear" }
            $col = if ($d.Blocked) { 'Red' } else { 'Green' }
            Write-Host ("{0}  confidence={1}  stuckArb={2}  siblings={3} [{4}]" -f $tag,$d.Confidence,$d.StuckArbitrations,$d.SiblingCount,$d.SiblingSessionIds) -ForegroundColor $col
        }
        if ($Watch) { Start-Sleep 3 }
    } while ($Watch)
    return
}

# ================================ VERIFY MODE (non-destructive spot-check) ================================
if ($Mode -ieq 'verify') {
    if (-not $RdpHost)    { Fail "-RdpHost <server> is required." }
    if (-not $TargetUser) { Fail "-TargetUser <user> is required." }
    if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'wtfrdp-verify' }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory $OutDir -Force | Out-Null }
    $png = Join-Path $OutDir ("blockscreen_{0}_{1}.png" -f ($TargetUser -replace '[\\/:]','_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Set-TargetCred
    $rdpFile = New-AdminRdp
    try { $v = Invoke-BlockScreenVerify -RdpFile $rdpFile -OutPng $png }
    finally { cmdkey /delete:TERMSRV/$RdpHost 2>$null | Out-Null; if (Test-Path $rdpFile) { Remove-Item $rdpFile -Force -EA SilentlyContinue } }
    if ($Json) { $v | ConvertTo-Json -Depth 4; return }
    $tag = if ($v.Blocked) { "[X] BLOCKED" } elseif ($v.Inconclusive) { "[?] INCONCLUSIVE" } else { "[OK] not blocked" }
    $col = if ($v.Blocked) { 'Red' } elseif ($v.Inconclusive) { 'Yellow' } else { 'Green' }
    Write-Host ("{0}  ({1}@{2})  pureBlack%={3}  lowerText%={4}" -f $tag,$TargetUser,$RdpHost,$v.PureBlackPct,$v.LowerBrightPct) -ForegroundColor $col
    if ($v.Note) { Write-Host "  note: $($v.Note)" -ForegroundColor DarkGray }
    if ($v.Png)  { Write-Host "  screenshot: $($v.Png)" -ForegroundColor DarkGray }
    # OPT-IN sign-out clear -- ONLY on a verify-CONFIRMED block. Verify always runs first (above) so we
    # never send sign-out clicks at a healthy session (that would log off real work). If not blocked, refuse.
    if ($SignOut -and ($v.Blocked -or $NoVerify)) {
        Write-Host ""
        if ($NoVerify -and -not $v.Blocked) {
            Write-Host "  [!!] -NoVerify + -SignOut: FORCING sign-out WITHOUT a confirmed block (you accept the bad-click risk)." -ForegroundColor Red
        } else {
            Write-Host "  [!!] -SignOut: block CONFIRMED -- DESTRUCTIVE CLEAR: signing '$TargetUser' out to release it." -ForegroundColor Yellow
        }
        Write-Host "       Its session state (open apps, unsaved work) will be PERMANENTLY LOST." -ForegroundColor Yellow
        Invoke-SignOutClear -Method $SignOutMethod
        Write-Host "  [!!] sign-out ($SignOutMethod) attempted. Re-run 'rdp test verify -RdpHost $RdpHost -TargetUser $TargetUser' to confirm it cleared." -ForegroundColor Yellow
    } elseif ($SignOut -and $v.Inconclusive) {
        Write-Host "  [?] -SignOut skipped: verify was INCONCLUSIVE (could not connect/capture) -- not signing out an unknown state. Retry, or -NoVerify to force." -ForegroundColor Yellow
    } elseif ($SignOut) {
        Write-Host "  [OK] -SignOut ignored: session is NOT blocked -- refusing to sign out a healthy session. Use -NoVerify to force." -ForegroundColor Green
    }
    return
}

# ================================ CLIENT MODE ================================
if ($Mode -ine 'client') { Fail "specify a mode: 'rdp test client|verify|server ...'. See -h." }
if (-not $RdpHost)    { Fail "-RdpHost <server> is required for client mode (a real host, not localhost)." }
if (-not $TargetUser) { Fail "-TargetUser <account> is required (SUSPECTED to need to own the console session for a persistent block -- not yet confirmed)." }
if ($RdpHost -in @('localhost','127.0.0.1','::1',$env:COMPUTERNAME)) { Fail "-RdpHost must be a REMOTE host. Loopback is unsupported (shortcuts the TCP stack; unverified for this bug)." }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Fail "Administrator required (the storm + failsafe need it). Re-run from an elevated shell."
}
if (-not $ClumsyPath) {
    $cc = @((Get-Command clumsy.exe -EA SilentlyContinue | Select-Object -Expand Source -First 1),
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Jagt.Clumsy_Microsoft.Winget.Source_8wekyb3d8bbwe\clumsy.exe")
    $ClumsyPath = $cc | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $ClumsyPath -or -not (Test-Path $ClumsyPath)) { Fail "clumsy.exe not found. Install: winget install Jagt.Clumsy (or pass -ClumsyPath)." }

Say "[wtf-rdp] NOTE: a PERSISTENT block is SUSPECTED to need -TargetUser to OWN the host's console session (not yet confirmed with the new tooling); a non-owner may only flicker transiently."
Set-TargetCred
$rdpFile = New-AdminRdp

# PRE-STORM BASELINE: is the session ALREADY blocked? If so, a storm can only DETECT the existing block,
# it CANNOT prove THIS run created it. Alert + abort (or -Force to proceed detect-only). Without this you
# conflate "our storm created the block" with "the block was already there and we merely re-detected it".
$preBlocked = $false
if (-not $NoVerify) {
    Say "[wtf-rdp] pre-storm baseline: checking whether $TargetUser is ALREADY blocked (non-destructive)..."
    $vdir0 = Join-Path $env:TEMP 'wtfrdp-verify'; if (-not (Test-Path $vdir0)) { New-Item -ItemType Directory $vdir0 -Force | Out-Null }
    $preP = Join-Path $vdir0 ("baseline_{0}_{1}.png" -f ($TargetUser -replace '[\\/:]','_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $preV = Invoke-BlockScreenVerify -RdpFile $rdpFile -OutPng $preP
    $preBlocked = [bool]$preV.Blocked
    if ($preBlocked) {
        Say "[wtf-rdp] *** $TargetUser is ALREADY BLOCKED before the storm (pureBlack%=$($preV.PureBlackPct)). ***"
        Say "[wtf-rdp] This run can only DETECT the existing block -- it CANNOT prove the storm created it."
        Say "[wtf-rdp] To prove CREATION: log off the session so the baseline reads CLEAR (see -SignOut), then re-run."
        if ($Auto) {
            Say "[wtf-rdp] -Auto: clearing the existing block (sign-out) FIRST to get a CLEAN baseline before the storm..."
            Invoke-SignOutClear
            Start-Sleep 5
            Set-TargetCred
            $preV = Invoke-BlockScreenVerify -RdpFile $rdpFile -OutPng $preP
            $preBlocked = [bool]$preV.Blocked
            if ($preBlocked) { Say "[wtf-rdp] -Auto: WARNING sign-out did NOT clear the block -- proceeding DETECT-ONLY." }
            else { Say "[wtf-rdp] -Auto: baseline now CLEAR -> a post-storm block proves CREATION." }
        } elseif ($Force) {
            Say "[wtf-rdp] -Force set: proceeding anyway (results are DETECT-ONLY, not proof of creation)."
        } else {
            $ans = Read-Host "[wtf-rdp] Continue anyway? Run will be DETECT-ONLY (y/N)"
            if ($ans -notmatch '^(y|yes)$') {
                cmdkey /delete:TERMSRV/$RdpHost 2>$null | Out-Null
                if (Test-Path $rdpFile) { Remove-Item $rdpFile -Force -EA SilentlyContinue }
                Fail "aborted: session already blocked. Clear it first (-SignOut, or log off) to prove creation, or pass -Force to run detect-only."
            }
        }
    } else {
        Say "[wtf-rdp] baseline: $TargetUser is NOT blocked (clear). A block AFTER the storm => CREATED by this run."
    }
}

$total = $EstablishSec * [Math]::Max(1,$Waves) + $BlackholeSec + $SettleSec
$fsAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -Command `"Stop-Process -Name clumsy,mstsc -Force -ErrorAction SilentlyContinue`""
$fsTrg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds($total + 150))
Register-ScheduledTask -TaskName 'WtfRdpTestFailsafe' -Action $fsAct -Trigger $fsTrg -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

$hs = $null; $clProc = $null; $stoppedGuard = $false; $result = $null; $visual = $null
try {
    $hs = New-HostSession
    if ($hs -and $StopGuard) {
        $st = Invoke-Command -Session $hs { Stop-Service wtf-rdp-sessfix -Force -EA SilentlyContinue; (Get-Service wtf-rdp-sessfix -EA SilentlyContinue).Status }
        $stoppedGuard = $true; Say "[wtf-rdp] server watchdog stopped for the run -> $st"
    } elseif ($StopGuard -and -not $hs) { Say "[wtf-rdp] -StopGuard needs -HostUser/-HostPasswordFile (WinRM); guard left as-is." }
    if ($hs) { $b = Invoke-Command -Session $hs $HostDetectSb -ArgumentList 3; Say "[wtf-rdp] baseline: begin=$($b.Begin) end=$($b.End) stuck=$($b.Stuck) errTimeouts=$($b.ErrTimeouts)" }

    Get-Process mstsc,clumsy -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 2
    for ($w = 1; $w -le [Math]::Max(1,$Waves); $w++) {
        Say "[wtf-rdp] establish wave $w/$([Math]::Max(1,$Waves)): $N mstsc /admin (no loss -> connect + arbitrate)..."
        1..$N | ForEach-Object { Start-Process mstsc.exe -ArgumentList "`"$rdpFile`"" }
        # Click 'Connect'/'Yes' on the unsigned-.rdp publisher + reconnect dialogs for the WHOLE establish
        # window. N concurrent mstsc stagger their "connect anyway?" dialogs in over several seconds, so an
        # 8s pump left later ones unclicked -> those connections never established -> weaker arbitration
        # pressure. Pumping the full window maximizes established+arbitrating connections (higher repro rate).
        $dl = (Get-Date).AddSeconds([Math]::Max($ClickSec, $EstablishSec))
        while ((Get-Date) -lt $dl) { [WtfRdpTest.Ui]::ClickIn('mstsc',@('Connect','Yes','OK','Reconnect')) | Out-Null; Start-Sleep -Milliseconds 250 }
    }
    Say "[wtf-rdp] SILENT BLACKHOLE on (clumsy 100% drop): connections hang + time out (0x800705F9) mid-arbitration..."
    $clArgs = "--filter `"tcp.DstPort == 3389 or tcp.SrcPort == 3389`" --drop on --drop-inbound on --drop-outbound on --drop-chance 100"
    $clProc = Start-Process -FilePath $ClumsyPath -ArgumentList $clArgs -PassThru -WindowStyle Hidden
    Start-Sleep $BlackholeSec
    if ($clProc) { Stop-Process -Id $clProc.Id -Force -EA SilentlyContinue }
    Get-Process clumsy -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Say "[wtf-rdp] blackhole lifted; settling ${SettleSec}s (timeouts finish)..."
    Start-Sleep $SettleSec
    Get-Process mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 3

    $host_ = if ($hs) { Invoke-Command -Session $hs $HostDetectSb -ArgumentList 6 } else { $null }
    $stuck = if ($host_) { $host_.Stuck } else { 0 }
    $errT  = if ($host_) { $host_.ErrTimeouts } else { 0 }
    $hostBlocked = ($host_ -and $stuck -gt 0 -and $errT -gt 0)

    # non-destructive VISUAL verify + MSRC screenshot (unless -NoVerify)
    if (-not $NoVerify) {
        Say "[wtf-rdp] visual verify: connecting once to capture the block screen (non-destructive)..."
        $vdir = Join-Path $env:TEMP 'wtfrdp-verify'; if (-not (Test-Path $vdir)) { New-Item -ItemType Directory $vdir -Force | Out-Null }
        $png = Join-Path $vdir ("blockscreen_{0}_{1}.png" -f ($TargetUser -replace '[\\/:]','_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $visual = Invoke-BlockScreenVerify -RdpFile $rdpFile -OutPng $png
        # Retry an AMBIGUOUS first capture: right after the storm the fresh connect can catch a transitional
        # canvas or a still-clearing "connect anyway?" dialog (PureBlackPct='n/a'), or the host reports blocked
        # while the block screen hasn't fully painted yet. A clean re-verify a few seconds later resolves it
        # (observed: standalone 'rdp test verify' a minute later scored the same block 95.6% pure-black).
        $vtry = 1
        while (-not $visual.Blocked -and ($visual.PureBlackPct -eq 'n/a' -or $hostBlocked) -and $vtry -lt 3) {
            Start-Sleep 6
            Say "[wtf-rdp] visual verify: retry $vtry (first capture ambiguous; letting the block paint)..."
            $visual = Invoke-BlockScreenVerify -RdpFile $rdpFile -OutPng $png
            $vtry++
        }
    }
    # the VISUAL result (function test: did a fresh connect actually hit the block screen?) is the
    # DECIDER; the host-side stuck/errTimeouts corroborate but the begin-end imbalance over-reports
    # residual arbitration churn (it flagged "blocked" on a run whose fresh connect reached the desktop).
    $blocked = if ($null -ne $visual) { [bool]$visual.Blocked } else { $hostBlocked }
    $result = [pscustomobject]@{
        Blocked=$blocked; PreBlocked=$preBlocked; HostBlocked=$hostBlocked; HostStuck=$stuck; HostErrTimeouts=$errT
        VisualBlocked=$(if($visual){$visual.Blocked}else{'skipped'}); VisualPureBlackPct=$(if($visual){$visual.PureBlackPct}else{'n/a'}); Screenshot=$(if($visual){$visual.Png}else{$null})
        RdpHost=$RdpHost; TargetUser=$TargetUser; DetectedVia=$(if($hs){'WinRM host-side'}else{'no WinRM (host verdict skipped)'})
    }
}
finally {
    if ($clProc) { Stop-Process -Id $clProc.Id -Force -EA SilentlyContinue }
    Get-Process clumsy,mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    cmdkey /delete:TERMSRV/$RdpHost 2>$null | Out-Null
    if (Test-Path $rdpFile) { Remove-Item $rdpFile -Force -EA SilentlyContinue }
    Unregister-ScheduledTask -TaskName 'WtfRdpTestFailsafe' -Confirm:$false -EA SilentlyContinue
    if ($hs) {
        if ($stoppedGuard) { $st = Invoke-Command -Session $hs { Start-Service wtf-rdp-sessfix -EA SilentlyContinue; (Get-Service wtf-rdp-sessfix -EA SilentlyContinue).Status }; Say "[wtf-rdp] server watchdog restored -> $st" }
        Remove-PSSession $hs
    }
}

if ($Json) { $result | ConvertTo-Json -Depth 4; return }
Say ""
Say "==================== rdp test (client) verdict ===================="
if ($result.Blocked) {
    if ($result.PreBlocked) {
        Write-Host "  [!] BLOCK DETECTED on $RdpHost ('$TargetUser') -- but it was ALREADY blocked before the storm." -ForegroundColor Yellow
        Write-Host "      DETECT-ONLY: this run did NOT prove creation (clear the session and re-run to prove the storm creates it)." -ForegroundColor Yellow
    } else {
        Write-Host "  [X] BLOCK CREATED on $RdpHost ('$TargetUser') -- baseline was CLEAR, blocked after the storm." -ForegroundColor Red
    }
} else {
    Write-Host "  [OK] no persistent block detected this run." -ForegroundColor Green
}
Write-Host "      host: stuck=$($result.HostStuck) errTimeouts(0x800705F9)=$($result.HostErrTimeouts) blocked=$($result.HostBlocked)  (via $($result.DetectedVia))"
Write-Host "      visual: blocked=$($result.VisualBlocked) pureBlack%=$($result.VisualPureBlackPct)  (function test -- the decider)"
if ($result.Screenshot) { Write-Host "      screenshot: $($result.Screenshot)" -ForegroundColor DarkGray }
if (-not $result.Blocked) { Write-Host "      (retry; the 0x800705F9 timeout must coincide with a pending arbitration -- a retry loop is planned.)" -ForegroundColor DarkGray }
Say "==================================================================="

# OPT-IN DESTRUCTIVE CLEAR (-SignOut only; never automatic). Releases the block WITHOUT a reboot but
# PERMANENTLY DISCARDS the session's state. Uses the SAME shared Invoke-SignOutClear as verify mode
# (client + verify must not diverge). Only fires on a verify-confirmed block above.
if ($result.Blocked -and $SignOut) {
    Write-Host ""
    Write-Host "  [!!] -SignOut ($SignOutMethod): DESTRUCTIVE CLEAR -- signing '$TargetUser' out to release the block." -ForegroundColor Yellow
    Write-Host "       Its session state (open apps, unsaved work) will be PERMANENTLY LOST." -ForegroundColor Yellow
    Invoke-SignOutClear -Method $SignOutMethod
    Write-Host "  [!!] sign-out ($SignOutMethod) attempted. Confirm with: rdp test verify -RdpHost $RdpHost -TargetUser $TargetUser ..." -ForegroundColor Yellow
}
