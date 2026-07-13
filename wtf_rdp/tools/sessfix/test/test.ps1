<#
.SYNOPSIS
    rdp test (sessfix) -- reproduce and detect the LSM session-arbitration block across the
    network. TWO modes, because the test is inherently two-machine:

      rdp test client -RdpHost <server> ...   run on a CLIENT: storm the server with overlapping
                                              reconnects, then detect the block ON the server
                                              (via WinRM if -HostUser given) and report.
      rdp test server [-Watch]                run on the SERVER (the RDP host): detect whether
                                              THIS box is currently in the arbitration block
                                              (local LSM log + refused-probe). No WinRM needed.

    The block = a stuck LSM arbitration (Operational Id=41 "Begin session arbitration" with no
    completing Id=42) from a violent OVERLAPPING reconnect storm. NOT Event 36. Detection never
    trusts qwinsta "Active" (a blocked session masquerades as Active).

    Loopback/localhost is deliberately NOT supported as a "local self-test" -- it shortcuts the
    full TCP/IP stack and is unverified for this bug. Use a real host on the network.

    STATUS: WIP -- reliable PERSISTENT reproduction is still being finalized (the storm triggers
    the block, but sustaining it for a 100%-repeatable strand is in progress; see l#22).

.DANGER  client mode strands the -TargetUser session on the server (reboot/logoff-only without
    the guard). Use a THROWAWAY account. clumsy.exe supplies the loss (winget install Jagt.Clumsy).

.VERSION 0.1.0 (tool); ships with wtf-rdp -- see 'rdp --version'.
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Position=0)][string] $Mode = '',
    [Alias('h')][switch] $Help,
    # --- client mode ---
    [string] $RdpHost      = '',
    [string] $TargetUser   = '',
    [string] $PasswordFile = '',
    [string] $HostUser     = '',      # WinRM account on the server for host-side detection (optional)
    [string] $HostPasswordFile = '',
    [int]    $N            = 12,
    [int]    $Rounds       = 1,        # >1 = sustained (re-fire to accumulate the colliding field)
    [int]    $DropChance   = 50,
    [int]    $HoldSec      = 30,
    [int]    $ClickSec     = 12,
    [int]    $RoundGapSec  = 6,
    [string] $ClumsyPath   = '',
    [switch] $StopGuard,               # stop the server watchdog for the run (restored after)
    # --- server mode ---
    [switch] $Watch,
    [int]    $LookbackMin  = 10,
    [string] $ModulePath   = '',
    [switch] $Json,
    [Parameter(ValueFromRemainingArguments=$true)] $Rest
)
$ErrorActionPreference = 'Stop'
function Fail($m){ Write-Host "[wtf-rdp] $m" -ForegroundColor Yellow; exit 1 }
function Say($m){ if (-not $Json) { Write-Host $m } }

if ($Help -or $Mode -in @('-h','--help','/?','help') -or ($Rest | Where-Object { $_ -match '^(--?help|/\?)$' })) {
    Write-Host @"
rdp test -- reproduce + detect the LSM session-arbitration block (two-machine).

Usage:
  rdp test client -RdpHost <server> -TargetUser <throwaway> [-PasswordFile <f>]
                  [-HostUser <winrm-acct> -HostPasswordFile <f>]   detect on the server via WinRM
                  [-N 12] [-Rounds 1] [-DropChance 50] [-HoldSec 30] [-ClickSec 12] [-StopGuard]
  rdp test server [-Watch] [-LookbackMin 10] [-Json]               run ON the RDP host

client: run on a CLIENT machine. Fires N concurrent mstsc /admin reconnects at -RdpHost while a
  packet loss keeps them half-open (the overlap that collides the session table). With -HostUser
  it reads the server's verdict over WinRM; without, run 'rdp test server' on the host yourself.
  -StopGuard stops the server's wtf-rdp watchdog for the run (restored after) to test the raw box.

server: run ON the RDP host. Reports whether this box is in the arbitration block right now
  (stuck Id=41 + sibling sessions). -Watch loops. No WinRM needed.

DANGER: client mode strands -TargetUser (reboot/logoff-only without the guard). Throwaway account
  only. Needs clumsy.exe on the client (winget install Jagt.Clumsy) and an elevated shell.
"@
    return
}

# ============================ shared: module + WinRM ============================
function Resolve-Module {
    if ($ModulePath -and (Test-Path $ModulePath)) { return $ModulePath }
    $c = @('C:\ProgramData\wtf-rdp\WtfRdp.Sessions.psm1', (Join-Path $PSScriptRoot '..\..\..\lib\WtfRdp.Sessions.psm1'))
    $c | Where-Object { Test-Path $_ } | Select-Object -First 1
}
# Self-contained host-side arbitration read, sent over WinRM so the server needs no module deployed.
# Counts siblings from BOTH the live session table (rdp-tcp# sessions) and the LSM log -- the log
# text alone undercounts (a storm piles up sessions the messages never name).
$HostDetectSb = {
    param($mins)
    $lo = (Get-Date).AddMinutes(-$mins)
    $ev = Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -EA SilentlyContinue |
          Where-Object { $_.TimeCreated -ge $lo }
    $b = @($ev | Where-Object { $_.Id -eq 41 } | Sort-Object TimeCreated)
    $e = @($ev | Where-Object { $_.Id -eq 42 })
    $stuck = 0
    foreach ($a in $b) { if (-not ($e | Where-Object { $_.TimeCreated -gt $a.TimeCreated -and $_.TimeCreated -le $a.TimeCreated.AddSeconds(120) })) { $stuck++ } }
    $q = (qwinsta 2>&1 | Out-String) -split "`r?`n"
    $liveSibs = @($q | Where-Object { $_ -match 'rdp-tcp#' }).Count
    [pscustomobject]@{ Begin=$b.Count; End=$e.Count; Stuck=$stuck; LiveSiblings=$liveSibs }
}
function New-HostSession {
    if (-not $HostUser) { return $null }
    if (-not $HostPasswordFile -or -not (Test-Path $HostPasswordFile)) { Fail "-HostPasswordFile required (and must exist) when -HostUser is set." }
    $pw = (Get-Content $HostPasswordFile -Raw).Trim()
    $cred = New-Object System.Management.Automation.PSCredential($HostUser, (ConvertTo-SecureString $pw -AsPlainText -Force))
    $pw = $null
    $opt = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 25000 -CancelTimeout 5000   # never hang
    New-PSSession -ComputerName $RdpHost -Credential $cred -SessionOption $opt -ErrorAction Stop
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

# ================================ CLIENT MODE ================================
if ($Mode -ine 'client') { Fail "specify a mode: 'rdp test client -RdpHost <server> ...' or 'rdp test server'. See -h." }
if (-not $RdpHost)    { Fail "-RdpHost <server> is required for client mode (a real host on your network, not localhost)." }
if (-not $TargetUser) { Fail "-TargetUser <throwaway account> is required." }
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

# RdpClicker (proven BM_CLICK approach from harness.ps1 / Invoke-RdpConnect.ps1)
if (-not ([System.Management.Automation.PSTypeName]'WtfRdpTest.Clicker').Type) {
Add-Type -ReferencedAssemblies System -TypeDefinition @"
using System; using System.Text; using System.Diagnostics; using System.Runtime.InteropServices;
namespace WtfRdpTest { public class Clicker {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  delegate bool EnumProc(IntPtr h, IntPtr p); const uint BM_CLICK = 0x00F5;
  static string T(IntPtr h){ var s=new StringBuilder(512); GetWindowText(h,s,512); return s.ToString(); }
  static string C(IntPtr h){ var s=new StringBuilder(256); GetClassName(h,s,256); return s.ToString(); }
  public static string ClickIn(string proc, string[] bt){ string r=null;
    EnumWindows((h,x)=>{ if(!IsWindowVisible(h)) return true; uint pid; GetWindowThreadProcessId(h,out pid);
      try{ if(!string.Equals(Process.GetProcessById((int)pid).ProcessName,proc,StringComparison.OrdinalIgnoreCase)) return true; }catch{ return true; }
      IntPtr f=IntPtr.Zero; string ft=null;
      EnumChildWindows(h,(c,y)=>{ if(C(c)=="Button"){ string ct=T(c).Replace("&","").Trim(); foreach(var b in bt){ if(ct.StartsWith(b,StringComparison.OrdinalIgnoreCase)){ f=c; ft=ct; return false; } } } return true; },IntPtr.Zero);
      if(f!=IntPtr.Zero){ SendMessage(f,BM_CLICK,IntPtr.Zero,IntPtr.Zero); r="clicked ["+ft+"]"; return false; } return true; },IntPtr.Zero); return r; }
  // scan mstsc windows + child controls for the block message (function-level 'refused' signal)
  public static bool HasBlockDialog(){ bool[] hit={false};
    EnumWindows((h,x)=>{ if(!IsWindowVisible(h)) return true; uint pid; GetWindowThreadProcessId(h,out pid);
      try{ if(!string.Equals(Process.GetProcessById((int)pid).ProcessName,"mstsc",StringComparison.OrdinalIgnoreCase)) return true; }catch{ return true; }
      if(T(h).ToLowerInvariant().Contains("blocked")){ hit[0]=true; return false; }
      EnumChildWindows(h,(c,y)=>{ string t=T(c).ToLowerInvariant(); if(t.Contains("blocked")||t.Contains("local session manager")){ hit[0]=true; return false; } return true; },IntPtr.Zero);
      if(hit[0]) return false; return true; },IntPtr.Zero);
    return hit[0]; }
} }
"@
}

# build cred + .rdp
cmdkey /delete:TERMSRV/$RdpHost 2>$null | Out-Null
if ($PasswordFile) {
    if (-not (Test-Path $PasswordFile)) { Fail "PasswordFile not found: $PasswordFile" }
    $tp = (Get-Content $PasswordFile -Raw).Trim()
    cmdkey /generic:TERMSRV/$RdpHost /user:$TargetUser /pass:$tp | Out-Null; $tp = $null
}
$rdpFile = Join-Path $env:TEMP ("wtfrdp_test_{0}.rdp" -f ($TargetUser -replace '[\\/:]','_'))
@("full address:s:$RdpHost","username:s:$TargetUser","authentication level:i:0","prompt for credentials:i:0","administrative session:i:1") -join "`r`n" |
  Set-Content $rdpFile -Encoding Ascii

# failsafe: kill the storm + loss after the run even if this dies (NO 30-minute hangs)
$failsafeSec = ($HoldSec + $ClickSec) * [Math]::Max(1,$Rounds) + 120
$fsCmd = "Stop-Process -Name clumsy,mstsc -Force -ErrorAction SilentlyContinue"
$fsAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -Command `"$fsCmd`""
$fsTrg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds($failsafeSec))
Register-ScheduledTask -TaskName 'WtfRdpTestFailsafe' -Action $fsAct -Trigger $fsTrg -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

$hs = $null; $clProc = $null; $stoppedGuard = $false; $result = $null; $probeRefused = $false
try {
    $hs = New-HostSession
    if ($hs -and $StopGuard) {
        $st = Invoke-Command -Session $hs { Stop-Service wtf-rdp-sessfix -Force -EA SilentlyContinue; (Get-Service wtf-rdp-sessfix -EA SilentlyContinue).Status }
        $stoppedGuard = $true; Say "[wtf-rdp] server watchdog stopped for the run -> $st"
    } elseif ($StopGuard -and -not $hs) { Say "[wtf-rdp] -StopGuard needs -HostUser/-HostPasswordFile (WinRM); guard left as-is." }
    if ($hs) { $b = Invoke-Command -Session $hs $HostDetectSb -ArgumentList 3; Say "[wtf-rdp] baseline: begin=$($b.Begin) end=$($b.End) stuck=$($b.Stuck) liveSiblings=$($b.LiveSiblings)" }

    Get-Process mstsc,clumsy -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 2
    $clArgs = "--filter `"tcp.DstPort == 3389 or tcp.SrcPort == 3389`" --drop on --drop-inbound on --drop-outbound on --drop-chance $DropChance"
    $clProc = Start-Process -FilePath $ClumsyPath -ArgumentList $clArgs -PassThru -WindowStyle Hidden
    Say "[wtf-rdp] clumsy $DropChance% drop on"; Start-Sleep 1

    for ($r = 1; $r -le [Math]::Max(1,$Rounds); $r++) {
        1..$N | ForEach-Object { Start-Process mstsc.exe -ArgumentList "`"$rdpFile`"" }
        Say "[wtf-rdp] round $r/$([Math]::Max(1,$Rounds)): fired $N mstsc; clicking Connect for ${ClickSec}s..."
        $dl = (Get-Date).AddSeconds($ClickSec)
        while ((Get-Date) -lt $dl) { [WtfRdpTest.Clicker]::ClickIn('mstsc',@('Connect','Yes','OK','Reconnect')) | Out-Null; Start-Sleep -Milliseconds 300 }
        if ($Rounds -gt 1 -and $r -lt $Rounds) { Start-Sleep $RoundGapSec }
    }
    Say "[wtf-rdp] holding the storm ${HoldSec}s..."
    Start-Sleep $HoldSec

    if ($clProc) { Stop-Process -Id $clProc.Id -Force -EA SilentlyContinue }
    Get-Process clumsy -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Say "[wtf-rdp] loss lifted; settling..."; Start-Sleep 8

    # fresh-connect probe (function test): clean reconnect -- refused (block dialog)?
    Get-Process mstsc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 1
    Start-Process mstsc.exe -ArgumentList "`"$rdpFile`""
    $pdl = (Get-Date).AddSeconds(22)
    while ((Get-Date) -lt $pdl) {
        [WtfRdpTest.Clicker]::ClickIn('mstsc',@('Connect','Yes','OK','Reconnect')) | Out-Null
        if ([WtfRdpTest.Clicker]::HasBlockDialog()) { $probeRefused = $true; break }
        Start-Sleep -Milliseconds 700
    }

    $host_ = if ($hs) { Invoke-Command -Session $hs $HostDetectSb -ArgumentList 6 } else { $null }
    $stuck = if ($host_) { $host_.Stuck } else { 0 }
    $sib   = if ($host_) { $host_.LiveSiblings } else { 0 }
    $blocked = $probeRefused -or ($host_ -and $stuck -gt 0 -and $host_.Begin -gt $host_.End -and $sib -ge 3)
    $result = [pscustomobject]@{
        Blocked=$blocked; ProbeRefused=$probeRefused
        HostStuck=$stuck; HostLiveSiblings=$sib
        HostBegin=$(if($host_){$host_.Begin}else{'n/a'}); HostEnd=$(if($host_){$host_.End}else{'n/a'})
        RdpHost=$RdpHost; TargetUser=$TargetUser; DetectedVia=$(if($hs){'WinRM host-side'}else{'client probe only (run: rdp test server on the host)'})
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
    Write-Host "  [X] BLOCK REPRODUCED on $RdpHost ('$TargetUser')." -ForegroundColor Red
    Write-Host "      probeRefused=$($result.ProbeRefused)  hostStuck=$($result.HostStuck)  hostBegin/end=$($result.HostBegin)/$($result.HostEnd)  liveSiblings=$($result.HostLiveSiblings)"
    Write-Host "      Detected via: $($result.DetectedVia)"
} else {
    Write-Host "  [OK] no persistent block this run." -ForegroundColor Green
    Write-Host "      probeRefused=$($result.ProbeRefused)  hostStuck=$($result.HostStuck)  hostBegin/end=$($result.HostBegin)/$($result.HostEnd)  liveSiblings=$($result.HostLiveSiblings)"
    Write-Host "      Detected via: $($result.DetectedVia)"
    if (-not $HostUser) { Write-Host "      (no -HostUser: client-probe only. For the real verdict run 'rdp test server' on $RdpHost, or pass -HostUser/-HostPasswordFile.)" -ForegroundColor DarkGray }
}
Say "==================================================================="
