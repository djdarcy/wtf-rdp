<#
.SYNOPSIS
    Launch an .rdp file and auto-click the "Connect" button on the Remote Desktop
    Connection security-warning dialog (and any follow-up Yes/OK prompts), so the
    test harness can establish RDP sessions deterministically without a human click.

.DESCRIPTION
    The "Remote Desktop Connection security warning" ("Unknown remote connection")
    dialog defaults its focus to *Cancel*, so sending Enter would cancel. This tool
    enumerates windows owned by the mstsc process, finds the button whose text starts
    with Connect/Yes/OK, and posts BM_CLICK directly to that button handle.

.EXAMPLE
    Invoke-RdpConnect.ps1 -RdpFile C:\path\rdptest.rdp -TimeoutSec 20
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RdpFile,
    [int]      $TimeoutSec  = 20,
    [string[]] $ButtonText  = @('Connect','Yes','OK'),
    [string]   $ProcessName = 'mstsc',
    # If set, don't launch mstsc — only click on already-open dialogs.
    [switch]   $NoLaunch
)

Add-Type -ReferencedAssemblies System -TypeDefinition @"
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
public class RdpClicker {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  delegate bool EnumProc(IntPtr h, IntPtr p);
  const uint BM_CLICK = 0x00F5;

  static string Text(IntPtr h){ var sb=new StringBuilder(256); GetWindowText(h,sb,256); return sb.ToString(); }
  static string Cls(IntPtr h){ var sb=new StringBuilder(256); GetClassName(h,sb,256); return sb.ToString(); }

  public static string ClickIn(string procName, string[] btnText){
    string result = null;
    EnumWindows((h,p)=>{
      if(!IsWindowVisible(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      try { if(!string.Equals(Process.GetProcessById((int)pid).ProcessName, procName, StringComparison.OrdinalIgnoreCase)) return true; }
      catch { return true; }
      IntPtr found=IntPtr.Zero; string ftext=null; string wtitle=Text(h);
      EnumChildWindows(h,(c,p2)=>{
        if(Cls(c)=="Button"){
          string ct = Text(c).Replace("&","").Trim();
          foreach(var b in btnText){
            if(ct.StartsWith(b, StringComparison.OrdinalIgnoreCase)){ found=c; ftext=ct; return false; }
          }
        }
        return true;
      }, IntPtr.Zero);
      if(found!=IntPtr.Zero){
        SendMessage(found, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
        result = "clicked ['"+ftext+"'] in window ['"+wtitle+"']";
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return result;
  }
}
"@

if (-not $NoLaunch) {
    if (-not (Test-Path $RdpFile)) { throw "RDP file not found: $RdpFile" }
    Start-Process mstsc.exe -ArgumentList "`"$RdpFile`""
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$clicks = 0
while ((Get-Date) -lt $deadline) {
    $r = [RdpClicker]::ClickIn($ProcessName, $ButtonText)
    if ($r) { "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $r; $clicks++; Start-Sleep -Milliseconds 800 }
    else    { Start-Sleep -Milliseconds 400 }
}
"done; total clicks = $clicks"
