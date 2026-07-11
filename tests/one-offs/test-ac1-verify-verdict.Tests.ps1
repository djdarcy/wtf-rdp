<#
.SYNOPSIS
    AC1 verification-gate regression test (Pester 3.x). Guards Get-WtfRdpVerifyVerdict --
    the pure logic that decides whether a tscon reconnect actually HELD (vs. the false-positive
    where tscon exits 0 but a hardened LSM block decays the session back to Disconnected).
    Pure logic: no sessions, no tscon -- safe to run anywhere.
.EXAMPLE
    Invoke-Pester -Path .\tests\one-offs\test-ac1-verify-verdict.Tests.ps1
#>
Import-Module (Join-Path $PSScriptRoot '..\..\wtf_rdp\lib\WtfRdp.Sessions.psm1') -Force

Describe 'Get-WtfRdpVerifyVerdict (AC1 gate)' {
    It 'held: Active throughout -> Verified, recovered-held' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $true -VerifySec 20 -ObservedStates @('Active','Active','Active')
        $v.Verified | Should Be $true
        $v.Status   | Should Be 'recovered-held'
    }
    It 'decay: Active then Disconnected -> NOT verified, decayed (the false-positive we fixed)' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $true -VerifySec 20 -ObservedStates @('Active','Active','Disconnected')
        $v.Verified | Should Be $false
        $v.Decayed  | Should Be $true
        $v.Status   | Should Be 'decayed'
    }
    It 'decay-to-gone: Active then Gone (session reset out) -> decayed' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $true -VerifySec 20 -ObservedStates @('Active','Gone')
        $v.Status | Should Be 'decayed'
    }
    It 'never reached Active: stays Disconnected -> reconnect-not-observed' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $true -VerifySec 20 -ObservedStates @('Disconnected','Disconnected')
        $v.Verified | Should Be $false
        $v.Status   | Should Be 'reconnect-not-observed'
    }
    It 'tscon failed -> tscon-failed regardless of states' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $false -VerifySec 20 -ObservedStates @('Active','Active')
        $v.Verified | Should Be $false
        $v.Status   | Should Be 'tscon-failed'
    }
    It 'verification skipped (VerifySec 0) -> unverified, not falsely Verified' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $true -VerifySec 0 -ObservedStates @()
        $v.Verified | Should Be $false
        $v.Status   | Should Be 'unverified'
    }
    It 'Connected counts as reached-active and holds' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $true -VerifySec 20 -ObservedStates @('Connected','Connected')
        $v.Verified | Should Be $true
    }
    It 'transitional Connected -> Active holds' {
        $v = Get-WtfRdpVerifyVerdict -TsconOk $true -VerifySec 20 -ObservedStates @('Connected','Active','Active')
        $v.Verified | Should Be $true
    }
}
