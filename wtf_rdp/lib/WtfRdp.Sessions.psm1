<#
.SYNOPSIS
    Shared session machinery for wtf-rdp — WTS enumeration, wedge detection,
    and the non-destructive SYSTEM rescue (tscon reconnect + lock).

.DESCRIPTION
    One home for the logic the watchdog and the sessfix tools both use, so the
    rescue behaves identically whether it fires autonomously or via `rdp recover`.

    RUN AS SYSTEM. Cross-user `tscon` needs SeTcbPrivilege and locking another
    session needs WTSQueryUserToken — both are SYSTEM-only.
#>

# --- native interop (WTS enumeration + lock-a-session-from-SYSTEM) ---
if (-not ([System.Management.Automation.PSTypeName]'WtfRdp.Native').Type) {
Add-Type -Namespace WtfRdp -Name Native -MemberDefinition @'
    [DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern int WTSEnumerateSessions(IntPtr h, int r, int v, ref IntPtr ppSI, ref int c);
    [DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(IntPtr p);
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode)]
    public static extern bool WTSQuerySessionInformation(IntPtr h, int id, int cls, out IntPtr pp, out int cnt);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern bool WTSQueryUserToken(uint SessionId, out IntPtr phToken);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("userenv.dll", SetLastError=true)]
    public static extern bool CreateEnvironmentBlock(out IntPtr lpEnv, IntPtr hToken, bool bInherit);
    [DllImport("userenv.dll", SetLastError=true)] public static extern bool DestroyEnvironmentBlock(IntPtr lpEnv);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public uint dwPid; public uint dwTid; }

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessAsUser(IntPtr hToken, string app, string cmd,
        IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir,
        ref STARTUPINFO si, out PROCESS_INFORMATION pi);
'@
}

$script:WTS_STATE = @{ Active=0; Connected=1; ConnectQuery=2; Shadow=3; Disconnected=4; Idle=5; Listen=6; Reset=7; Down=8; Init=9 }

function Get-WtfRdpSession {
    <#.SYNOPSIS Enumerate sessions (Id/WinStation/User/State) via the WTS API.#>
    $ppSI=[IntPtr]::Zero; $count=0
    if (-not [WtfRdp.Native]::WTSEnumerateSessions([IntPtr]::Zero,0,1,[ref]$ppSI,[ref]$count)) {
        throw "WTSEnumerateSessions failed ($([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    $out=@(); $ptr=[IntPtr]::Size; $stride= if($ptr -eq 8){24}else{12}; $cur=$ppSI.ToInt64()
    for($i=0;$i -lt $count;$i++){
        $sid   =[Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]$cur)
        $pName =[Runtime.InteropServices.Marshal]::ReadIntPtr([IntPtr]($cur+$(if($ptr -eq 8){8}else{4})))
        $state =[Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]($cur+$(if($ptr -eq 8){16}else{8})))
        $name  =[Runtime.InteropServices.Marshal]::PtrToStringUni($pName)
        $pp=[IntPtr]::Zero;$cnt=0;$user=''
        if([WtfRdp.Native]::WTSQuerySessionInformation([IntPtr]::Zero,$sid,5,[ref]$pp,[ref]$cnt)){ # 5 = WTSUserName
            $user=[Runtime.InteropServices.Marshal]::PtrToStringUni($pp); [WtfRdp.Native]::WTSFreeMemory($pp)
        }
        $out += [pscustomobject]@{ Id=$sid; WinStation=$name; User=$user; State=$state
            StateName=($script:WTS_STATE.GetEnumerator()|Where-Object{$_.Value -eq $state}|Select-Object -First 1 -Expand Key) }
        $cur += $stride
    }
    [WtfRdp.Native]::WTSFreeMemory($ppSI)
    $out
}

function Get-WtfRdpWedgeEventSid {
    <#.SYNOPSIS SessionIds that logged an LSM Event 36 (CsrConnected->EvCsrInitialized transition
    failure — the dirty-disconnect wedge fingerprint) within the lookback window.#>
    param([int]$LookbackSec = 90)
    $start=(Get-Date).AddSeconds(-$LookbackSec)
    try {
        $ev = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id=36; StartTime=$start
        } -ErrorAction Stop
    } catch { return @() }
    $sids=@()
    foreach($e in $ev){ try { $xml=[xml]$e.ToXml()
        $sid=($xml.Event.EventData.Data|Where-Object{$_.Name -eq 'SessionId'}).'#text'
        if($null -ne $sid){ $sids += [int]$sid } } catch {} }
    ,($sids|Select-Object -Unique)
}

function Lock-WtfRdpSession {
    <#.SYNOPSIS Lock an interactive session from SYSTEM (runs LockWorkStation in the session
    via WTSQueryUserToken + CreateProcessAsUser). Returns $true on success.#>
    param([Parameter(Mandatory)][int]$SessionId)
    $tok=[IntPtr]::Zero
    if(-not [WtfRdp.Native]::WTSQueryUserToken([uint32]$SessionId,[ref]$tok)){
        return $false  # no interactive user token (e.g. session not logged on)
    }
    $envBlk=[IntPtr]::Zero
    try {
        [WtfRdp.Native]::CreateEnvironmentBlock([ref]$envBlk,$tok,$false) | Out-Null
        $si=New-Object WtfRdp.Native+STARTUPINFO
        $si.cb=[Runtime.InteropServices.Marshal]::SizeOf([type]([WtfRdp.Native+STARTUPINFO]))
        $si.lpDesktop='winsta0\default'
        $pi=New-Object WtfRdp.Native+PROCESS_INFORMATION
        $CREATE_UNICODE_ENVIRONMENT=0x00000400
        # NOTE: lpCurrentDirectory must be a valid path — passing $null marshals to an
        # empty string and CreateProcessAsUser fails with ERROR_INVALID_NAME (123).
        $ok=[WtfRdp.Native]::CreateProcessAsUser($tok,
            'C:\Windows\System32\rundll32.exe','rundll32.exe user32.dll,LockWorkStation',
            [IntPtr]::Zero,[IntPtr]::Zero,$false,$CREATE_UNICODE_ENVIRONMENT,$envBlk,'C:\Windows\System32',[ref]$si,[ref]$pi)
        if($ok){ [WtfRdp.Native]::CloseHandle($pi.hProcess)|Out-Null; [WtfRdp.Native]::CloseHandle($pi.hThread)|Out-Null }
        return [bool]$ok
    } finally {
        if($envBlk -ne [IntPtr]::Zero){ [WtfRdp.Native]::DestroyEnvironmentBlock($envBlk)|Out-Null }
        [WtfRdp.Native]::CloseHandle($tok)|Out-Null
    }
}

function Invoke-WtfRdpRescue {
    <#.SYNOPSIS Non-destructively rescue a stranded session: reconnect it to the console with
    tscon, then LOCK it so the box is never left open. Returns a result object.#>
    param(
        [Parameter(Mandatory)][int]$SessionId,
        [switch]$NoLock
    )
    $out = & tscon.exe $SessionId /dest:console 2>&1
    $tsconOk = ($LASTEXITCODE -eq 0)
    $locked = $false
    if ($tsconOk -and -not $NoLock) {
        Start-Sleep -Milliseconds 800   # let the session finish attaching before we lock it
        $locked = Lock-WtfRdpSession -SessionId $SessionId
    }
    [pscustomobject]@{
        SessionId = $SessionId
        Reconnected = $tsconOk
        Locked = $locked
        TsconOutput = ("$out").Trim()
    }
}

Export-ModuleMember -Function Get-WtfRdpSession, Get-WtfRdpWedgeEventSid, Lock-WtfRdpSession, Invoke-WtfRdpRescue
