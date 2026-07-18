<#
.SYNOPSIS
    Score saved capture PNGs to calibrate the ROBUST block-screen signature that separates the LSM
    console-arbitration block (near-PURE-black upper region + white text) from a dark desktop
    (dark-grey, content everywhere -- no pure-black region). Pass -Png paths; prints metrics + the
    verdict. Mirrors the production signature in wtf_rdp/tools/sessfix/test/test.ps1 (Invoke-BlockScreenVerify)
    and lib/WtfRdp.Sessions.psm1 (Get-WtfRdpBlockScreenVerdict): pureBlack% >= 70 AND lowerText% > 0.1.
    Generic -- no host/user/machine specifics; safe for the public repo.
#>
param([string[]]$Png)
Add-Type -AssemblyName System.Drawing
foreach ($p in $Png) {
    if (-not (Test-Path $p)) { "MISSING: $p"; continue }
    $bmp = New-Object System.Drawing.Bitmap($p)
    $W=$bmp.Width; $H=$bmp.Height
    $top=[int]($H*0.12)
    $u1=[int]($H*0.15); $u2=[int]($H*0.45)   # upper-middle region (block screen: pure black here)
    $lowerY=[int]($H*0.50)
    $sumAll=0.0; $nAll=0; $sumUp=0.0; $nUp=0; $pureBlack=0; $lb=0; $lt=0
    for ($y=$top; $y -lt $H; $y+=2) { for ($x=0; $x -lt $W; $x+=4) {
        $c=$bmp.GetPixel($x,$y); $l=(0.299*$c.R+0.587*$c.G+0.114*$c.B)
        $sumAll+=$l; $nAll++
        if ($l -lt 15) { $pureBlack++ }
        if ($y -ge $u1 -and $y -lt $u2) { $sumUp+=$l; $nUp++ }
        if ($y -ge $lowerY) { $lt++; if ($l -gt 180) { $lb++ } } } }
    $meanAll=[math]::Round($sumAll/[math]::Max(1,$nAll),1)
    $meanUp=[math]::Round($sumUp/[math]::Max(1,$nUp),1)
    $pureBlackPct=[math]::Round(100.0*$pureBlack/[math]::Max(1,$nAll),1)
    $lowerBrightPct=[math]::Round(100.0*$lb/[math]::Max(1,$lt),3)
    # ROBUST block signature: >=70% PURE-black coverage (a dark editor is ~0-5%) + white text below
    $blocked = ($pureBlackPct -ge 70 -and $lowerBrightPct -gt 0.1)
    $bmp.Dispose()
    "{0}`n  {1}x{2}  meanAll={3}  meanUpper={4}  pureBlack%={5}  lowerText%={6}  -> Blocked={7}" -f `
        (Split-Path $p -Leaf), $W, $H, $meanAll, $meanUp, $pureBlackPct, $lowerBrightPct, $blocked
}
