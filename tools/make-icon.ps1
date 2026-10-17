# Draws the app icon (two stacked windows with a play sign) into assets\RobloxManager.ico.
#     powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
# Only needed when the icon changes; the .ico is kept in the repo.
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot "..\assets\RobloxManager.ico"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Max(0.5, 2 * $r)
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}
function Draw-Icon([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"; $g.PixelOffsetMode = "HighQuality"; $g.Clear([System.Drawing.Color]::Transparent)
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($s, $s)),
        [System.Drawing.Color]::FromArgb(255, 0x5B, 0x93, 0xFF), [System.Drawing.Color]::FromArgb(255, 0x2A, 0x5B, 0xD6))
    $g.FillPath($bg, (New-RoundRect 0 0 $s $s ($s * 0.22)))
    $r = [Math]::Max(1, $s * 0.06)
    $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(130, 255, 255, 255))), (New-RoundRect ($s * 0.36) ($s * 0.18) ($s * 0.46) ($s * 0.40) $r))   # the window behind
    $g.FillPath([System.Drawing.Brushes]::White, (New-RoundRect ($s * 0.16) ($s * 0.36) ($s * 0.50) ($s * 0.44) $r))                                                     # the window in front
    $cx = $s * 0.41; $cy = $s * 0.58; $t = $s * 0.12
    $tri = [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(($cx - $t * 0.8), ($cy - $t))), (New-Object System.Drawing.PointF(($cx - $t * 0.8), ($cy + $t))), (New-Object System.Drawing.PointF(($cx + $t), $cy)))
    $g.FillPolygon((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0x2F, 0x64, 0xE0))), $tri)
    $g.Dispose(); return $bmp
}
function Get-DibBytes($bmp) {
    # Classic icon image: header, BGRA rows bottom-up, then an empty AND mask (alpha does the work).
    $s = $bmp.Width
    $ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter($ms)
    $maskRow = [int][Math]::Ceiling($s / 32) * 4
    $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]($s * $s * 4 + $maskRow * $s)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $s - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $s; $x++) { $c = $bmp.GetPixel($x, $y); $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A) } }
    $bw.Write((New-Object byte[] ($maskRow * $s)))
    $bw.Flush(); return $ms.ToArray()
}
function Get-PngBytes($bmp) { $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); return $ms.ToArray() }

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = @(foreach ($s in $sizes) { $b = Draw-Icon $s; , $(if ($s -ge 256) { Get-PngBytes $b } else { Get-DibBytes $b }); $b.Dispose() })
$ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter($ms)
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $images[$i].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]$len); $bw.Write([int]$offset)
    $offset += $len
}
foreach ($img in $images) { $bw.Write([byte[]]$img) }
$bw.Flush()
[IO.File]::WriteAllBytes((Resolve-Path (Split-Path $out)).Path + "\RobloxManager.ico", $ms.ToArray())
"Wrote $out ($($ms.Length) bytes)"
