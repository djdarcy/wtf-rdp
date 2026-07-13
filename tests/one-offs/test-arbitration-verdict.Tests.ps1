<#
.SYNOPSIS
    Arbitration-block detector regression test (Pester 3.x). Guards Get-WtfRdpArbitrationVerdict --
    the pure logic that decides whether the box is in the REAL reboot/logoff-only LSM
    session-arbitration block (a stuck Id=41 "Begin session arbitration" with no completing
    Id=42), corroborated by a colliding session table and/or a refused fresh-connection probe.
    This is NOT Event 36 (that is a separate, recoverable stage-1 wedge).

    Pure logic: no events, no sessions, no UI -- safe to run anywhere. The live/evtx wrapper
    (Get-WtfRdpArbitrationBlock) is verified against the STAGE2 capture separately (AC-D1).
.EXAMPLE
    Invoke-Pester -Path .\tests\one-offs\test-arbitration-verdict.Tests.ps1
#>
Import-Module (Join-Path $PSScriptRoot '..\..\wtf_rdp\lib\WtfRdp.Sessions.psm1') -Force

Describe 'Get-WtfRdpArbitrationVerdict (arbitration-block detector)' {
    It 'real block: stuck arbitration + sibling pileup -> Blocked, high confidence' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 1 -SiblingCount 3
        $v.Blocked    | Should Be $true
        $v.Confidence | Should Be 'high'
    }
    It 'ground truth: 2 siblings (the real STAGE2 window) still flags Blocked (MinSiblings=2)' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 1 -SiblingCount 2
        $v.Blocked    | Should Be $true
        $v.Confidence | Should Be 'high'
    }
    It 'function-confirmed: stuck arbitration + refused fresh-connection probe -> confirmed' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 1 -SiblingCount 2 -ProbeRefused $true
        $v.Blocked    | Should Be $true
        $v.Confidence | Should Be 'confirmed'
    }
    It 'lone stuck arbitration (no siblings, no probe) -> suspected, NOT Blocked (historical-Id=41 safeguard)' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 1 -SiblingCount 1
        $v.Blocked    | Should Be $false
        $v.Confidence | Should Be 'suspected'
    }
    It 'siblings churning but NO stuck arbitration (normal reconnect activity) -> not Blocked, none' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 0 -SiblingCount 5
        $v.Blocked    | Should Be $false
        $v.Confidence | Should Be 'none'
    }
    It 'calm system (nothing stuck, no siblings) -> not Blocked' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 0 -SiblingCount 1
        $v.Blocked    | Should Be $false
        $v.Confidence | Should Be 'none'
    }
    It 'probe attaches (function verified OK) despite a stuck arbitration -> not Blocked' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 1 -SiblingCount 1 -ProbeRefused $false
        $v.Blocked    | Should Be $false
        $v.Confidence | Should Be 'suspected'
    }
    It 'refused probe alone (stuck present, no sibling pileup) is enough to flag Blocked' {
        $v = Get-WtfRdpArbitrationVerdict -StuckArbitrations 1 -SiblingCount 1 -ProbeRefused $true
        $v.Blocked | Should Be $true
    }
}
