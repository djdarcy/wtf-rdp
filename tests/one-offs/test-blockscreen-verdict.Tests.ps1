<#
.SYNOPSIS
    Pester tests for Get-WtfRdpBlockScreenVerdict -- the pure verdict behind the CLIENT-SIDE visual
    block check in 'rdp test client|verify'. Correlates 1:1 with the production signature in
    wtf_rdp/tools/sessfix/test/test.ps1 (Invoke-BlockScreenVerify) and the generic scorer
    tests/one-offs/analyze-png.ps1. Pure inputs (two numbers) -> unit-testable, no capture needed.

    Run:  Invoke-Pester -Path tests/one-offs/test-blockscreen-verdict.Tests.ps1
#>
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path $here '..\..\wtf_rdp\lib\WtfRdp.Sessions.psm1'
Import-Module (Resolve-Path $module) -Force

Describe 'Get-WtfRdpBlockScreenVerdict' {

    It 'flags the LSM block screen (near-pure-black + white text)' {
        # calibrated live: block ~97% pure black + text in the lower half
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 97 -LowerBrightPct 2.0 | Should Be $true
    }

    It 'does NOT flag a dark editor (Sublime / VS Code) -- dark GREY, not pure black' {
        # dark theme is ~0-5% pure black; can never reach 70 no matter how dark
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 4 -LowerBrightPct 1.0 | Should Be $false
    }

    It 'does NOT flag a live desktop (bright, little pure black)' {
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 0.2 -LowerBrightPct 5.0 | Should Be $false
    }

    It 'does NOT flag a black transitional/connecting canvas (black but NO text)' {
        # the real test-1 miss: pureBlack 83.2% but no white text in the lower half -> not the block
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 83.2 -LowerBrightPct 0.0 | Should Be $false
    }

    It 'requires BOTH conditions: pure black alone is not enough' {
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 90 -LowerBrightPct 0.05 | Should Be $false
    }

    It 'requires BOTH conditions: text alone (bright screen) is not enough' {
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 30 -LowerBrightPct 3.0 | Should Be $false
    }

    It 'holds at the default boundary (>=70 pure black AND >0.1 text)' {
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 70   -LowerBrightPct 0.11 | Should Be $true
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 69.9 -LowerBrightPct 5.0  | Should Be $false
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 95   -LowerBrightPct 0.1  | Should Be $false  # strictly > 0.1
    }

    It 'honors custom thresholds' {
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 60 -LowerBrightPct 0.2 -MinPureBlack 55 -MinLowerText 0.1 | Should Be $true
        Get-WtfRdpBlockScreenVerdict -PureBlackPct 60 -LowerBrightPct 0.2 -MinPureBlack 65 -MinLowerText 0.1 | Should Be $false
    }
}
