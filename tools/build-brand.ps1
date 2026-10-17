# Draws every BloxKit brand asset from one set of shapes:
#   assets\brand\*.svg        editable vectors (mascot expressions, emblem, logos, monochrome)
#   assets\brand\*.png        transparent renders
#   assets\brand\BloxKit.Art.xaml   the same art for the app (WPF DrawingImages)
#   assets\BloxKit.ico        the app icon (16-256 px; a simpler drawing for the small sizes)
#     powershell -ExecutionPolicy Bypass -File tools\build-brand.ps1
# Shapes are built with WPF's geometry engine, so the SVG, PNG, ICO and in-app art match exactly.
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = "Stop"
$IC = [Globalization.CultureInfo]::InvariantCulture
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Out = Join-Path $Root "assets\brand"
New-Item -ItemType Directory -Force $Out | Out-Null

# ---- palette (the official five, plus tints of them) ----
$C = @{
    Blue = "#3B82F6"; Violet = "#8B5CF6"; Cloud = "#F8FAFC"; Slate = "#1F2937"; Midnight = "#0B0F14"
    BlueLight = "#93C5FD"; EyeCore = "#DBEAFE"; HoodShade = "#D6DEEC"; Rim = "#C5D0E3"; Sleeve = "#E8EEF8"
}

# ---- geometry helpers ----
$GM = [System.Windows.Media.GeometryCombineMode]
function P([string]$d) { [System.Windows.Media.Geometry]::Parse($d) }
function E([double]$cx, [double]$cy, [double]$rx, [double]$ry) { New-Object System.Windows.Media.EllipseGeometry((New-Object System.Windows.Point($cx, $cy)), $rx, $ry) }
function Poly([double[]]$p) { $s = "M $($p[0]),$($p[1])"; for ($i = 2; $i -lt $p.Count; $i += 2) { $s += " L $($p[$i]),$($p[$i+1])" }; P "$s Z" }
function RR([double]$x, [double]$y, [double]$w, [double]$h, [double]$tl, [double]$tr, [double]$br, [double]$bl) {
    # Rectangle with its own radius per corner (top-left, top-right, bottom-right, bottom-left).
    $s = "M $($x+$tl),$y L $($x+$w-$tr),$y"
    if ($tr) { $s += " A $tr,$tr 0 0 1 $($x+$w),$($y+$tr)" }
    $s += " L $($x+$w),$($y+$h-$br)"
    if ($br) { $s += " A $br,$br 0 0 1 $($x+$w-$br),$($y+$h)" }
    $s += " L $($x+$bl),$($y+$h)"
    if ($bl) { $s += " A $bl,$bl 0 0 1 $x,$($y+$h-$bl)" }
    $s += " L $x,$($y+$tl)"
    if ($tl) { $s += " A $tl,$tl 0 0 1 $($x+$tl),$y" }
    P "$s Z"
}
function U { $g = $args[0]; foreach ($b in $args[1..($args.Count - 1)]) { $g = [System.Windows.Media.Geometry]::Combine($g, $b, $GM::Union, $null) }; $g }
function Cut($a, $b) { [System.Windows.Media.Geometry]::Combine($a, $b, $GM::Exclude, $null) }
function Both($a, $b) { [System.Windows.Media.Geometry]::Combine($a, $b, $GM::Intersect, $null) }
function Tx($g, $t) { [System.Windows.Media.Geometry]::Combine($g, [System.Windows.Media.Geometry]::Empty, $GM::Union, $t) }   # bakes the transform in
function Shift($g, [double]$dx, [double]$dy) { Tx $g (New-Object System.Windows.Media.TranslateTransform($dx, $dy)) }
function Turn($g, [double]$deg, [double]$cx, [double]$cy) { Tx $g (New-Object System.Windows.Media.RotateTransform($deg, $cx, $cy)) }
function Mirror($g) { Tx $g (New-Object System.Windows.Media.ScaleTransform(-1, 1, 256, 0)) }   # across the mascot's middle (x = 256)
function Lines($paths, [double]$w) { $g = $null; foreach ($p in $paths) { $s = Line $p $w; $g = $(if ($g) { U $g $s } else { $s }) }; $g }   # each one outlined on its own, then joined
function Line($g, [double]$w, [switch]$Flat) {
    $pen = New-Object System.Windows.Media.Pen([System.Windows.Media.Brushes]::Black, $w)
    if (-not $Flat) { $pen.StartLineCap = "Round"; $pen.EndLineCap = "Round"; $pen.LineJoin = "Round" }
    $g.GetWidenedPathGeometry($pen).GetOutlinedPathGeometry()
}

# ---- fills: "#hex", @{ L = x1,y1,x2,y2; S = stops } (linear), @{ R = cx,cy,r; S = stops } (radial), all relative to the shape ----
function Lin([double[]]$v, $stops) { @{ L = $v; S = $stops } }
function Rad([double[]]$v, $stops) { @{ R = $v; S = $stops } }
function Layer($g, $fill, [double]$opacity = 1) { @{ G = $g; F = $fill; O = $opacity } }

# =================================================================== MASCOT ==
# A 512 x 512 canvas. A hooded robot companion holding a cube.
$HoodPath = "M 300,20 C 332,38 358,58 380,84 C 420,128 438,186 436,246 C 434,302 414,344 392,370 C 352,392 160,392 120,370 C 98,344 78,302 78,246 C 78,160 128,92 208,60 C 240,48 272,38 300,20 Z"
$FoldLeft = "M 300,20 C 272,38 240,48 208,60 C 128,92 78,160 78,246 C 78,302 98,344 120,370 C 134,378 148,382 164,386 C 128,350 110,302 110,250 C 110,172 154,106 228,74 C 254,62 280,44 300,20 Z"
$FoldRight = "M 380,84 C 420,128 438,186 436,246 C 434,302 414,344 392,370 C 384,374 376,378 366,382 C 396,346 410,302 410,252 C 410,192 396,142 368,102 Z"
function Get-Hood { P $HoodPath }
function Get-Face { P "M 160,188 C 164,152 192,134 228,132 L 322,130 C 360,130 384,152 388,188 L 394,270 C 396,306 372,328 336,330 L 190,332 C 152,332 132,310 134,274 Z" }
$EyeL = 222; $EyeR = 310; $EyeY = 244

function Get-Eyes([string]$kind) {
    $l = @()
    $glow = { param($a) Layer (U (E $EyeL ($EyeY + 2) 58 48) (E $EyeR ($EyeY + 2) 58 48)) (Rad @(0.5, 0.5, 0.5) @(@(0, "#B03B82F6"), @(0.55, "#403B82F6"), @(1, "#003B82F6"))) $a }
    $arcs = { param($w, $up, $down) , @((P "M $($EyeL-$w),$($EyeY+$down) C $($EyeL-$w*0.7),$($EyeY-$up) $($EyeL+$w*0.7),$($EyeY-$up) $($EyeL+$w),$($EyeY+$down)"), (P "M $($EyeR-$w),$($EyeY+$down) C $($EyeR-$w*0.7),$($EyeY-$up) $($EyeR+$w*0.7),$($EyeY-$up) $($EyeR+$w),$($EyeY+$down)")) }
    switch ($kind) {
        "happy" {   # ^ ^
            $arc = & $arcs 28 26 16
            $l += & $glow 1
            $l += Layer (Lines $arc 24) $C.Blue
            $l += Layer (Lines $arc 10) $C.EyeCore
        }
        "closed" {  # resting: gentle downward curves, dimmer
            $arc = & $arcs 22 -14 0
            $l += & $glow 0.4
            $l += Layer (Lines $arc 11) $C.BlueLight
        }
        "narrow" {  # focused
            $l += & $glow 0.8
            $l += Layer (U (RR ($EyeL-24) ($EyeY) 48 17 8.5 8.5 8.5 8.5) (RR ($EyeR-24) ($EyeY) 48 17 8.5 8.5 8.5 8.5)) $C.Blue
            $l += Layer (U (RR ($EyeL-14) ($EyeY+6) 28 6 3 3 3 3) (RR ($EyeR-14) ($EyeY+6) 28 6 3 3 3 3)) $C.EyeCore
        }
        "worried" { # concerned, not alarming: the inner corners lift
            $lidL = Poly @(180, 170, 268, 170, 268, 226, 180, 250)
            $lidR = Poly @(352, 170, 264, 170, 264, 226, 352, 250)
            $l += & $glow 0.7
            $l += Layer (U (Cut (E $EyeL ($EyeY + 4) 21 26) $lidL) (Cut (E $EyeR ($EyeY + 4) 21 26) $lidR)) $C.Blue
            $l += Layer (U (Cut (E $EyeL ($EyeY + 10) 11 14) $lidL) (Cut (E $EyeR ($EyeY + 10) 11 14) $lidR)) $C.EyeCore
        }
        "wide" {    # alert
            $l += & $glow 1
            $l += Layer (U (E $EyeL $EyeY 25 30) (E $EyeR $EyeY 25 30)) $C.Blue
            $l += Layer (U (E $EyeL ($EyeY - 1) 13 17) (E $EyeR ($EyeY - 1) 13 17)) $C.EyeCore
            $l += Layer (U (E ($EyeL - 8) ($EyeY - 12) 5 5) (E ($EyeR - 8) ($EyeY - 12) 5 5)) "#FFFFFF"
        }
        default {   # "oval": the neutral, friendly look
            $l += & $glow 0.9
            $l += Layer (U (E $EyeL $EyeY 21 27) (E $EyeR $EyeY 21 27)) $C.Blue
            $l += Layer (U (E $EyeL ($EyeY - 1) 11 16) (E $EyeR ($EyeY - 1) 11 16)) $C.EyeCore
            $l += Layer (U (E ($EyeL - 7) ($EyeY - 10) 4.5 4.5) (E ($EyeR - 7) ($EyeY - 10) 4.5 4.5)) "#FFFFFF"
        }
    }
    return $l
}

function Get-Head([string]$eyes) {
    $hood = Get-Hood; $face = Get-Face
    $l = @()
    $l += Layer $hood (Lin @(0.2, 0, 0.8, 1) @(@(0, "#FFFFFF"), @(0.6, $C.Cloud), @(1, $C.HoodShade)))
    # the hood's folds: blue-to-violet on the left, a violet edge on the right, light on the peak
    $l += Layer (Both $hood (P $FoldLeft)) (Lin @(0, 0, 0.4, 1) @(@(0, "#60A5FA"), @(0.5, $C.Blue), @(1, $C.Violet)))
    $l += Layer (Both $hood (P $FoldRight)) (Lin @(0, 0, 0, 1) @(@(0, "#A78BFA"), @(1, $C.Violet))) 0.85
    $l += Layer (Both $hood (P "M 300,20 C 332,38 358,58 380,84 C 346,62 312,54 276,56 C 288,44 296,32 300,20 Z")) "#FFFFFF"
    $l += Layer (Line $face 18) (Lin @(0, 0, 0, 1) @(@(0, $C.Rim), @(1, "#AEB9CF")))
    $l += Layer $face (Lin @(0, 0, 0, 1) @(@(0, "#182132"), @(1, "#06080C")))
    $l += Layer (Line (P "M 176,190 C 180,166 198,154 224,152") 7) "#FFFFFF" 0.14     # visor gloss
    $l += Get-Eyes $eyes
    return $l
}

function Get-Arm([string]$side, [switch]$Raised, [double]$turn = 0) {
    # A white sleeve with a blue cuff and a dark mitt. Drawn on the left, mirrored for the right.
    if ($Raised) {
        $sleeve = Line (P "M 360,380 C 392,368 416,342 426,306") 38
        $cuff = Both $sleeve (Poly @(396, 300, 460, 300, 460, 330, 396, 330))
        $mitt = E 430 292 25 28
        $glint = E 422 282 9 7
    } else {
        $sleeve = Line (P "M 152,384 C 140,410 148,432 174,442") 38
        $cuff = Both $sleeve (Poly @(126, 414, 196, 414, 196, 430, 126, 430))
        $mitt = E 180 440 25 29
        $glint = E 172 428 10 7
        if ($side -eq "right") { $sleeve = Mirror $sleeve; $cuff = Mirror $cuff; $mitt = Mirror $mitt; $glint = Mirror $glint }
    }
    if ($turn) { $sleeve = Turn $sleeve $turn 360 380; $cuff = Turn $cuff $turn 360 380; $mitt = Turn $mitt $turn 360 380; $glint = Turn $glint $turn 360 380 }
    return @{ Back = @((Layer $sleeve (Lin @(0, 0, 1, 1) @(@(0, "#FFFFFF"), @(1, $C.Sleeve)))), (Layer $cuff (Lin @(0, 0, 1, 1) @(@(0, $C.Blue), @(1, $C.Violet)))))
              Mitt = @((Layer $mitt (Rad @(0.4, 0.35, 0.7) @(@(0, "#374151"), @(1, "#111827")))), (Layer $glint "#FFFFFF" 0.2)) }
}

function Get-Cube {
    $top = Poly @(256, 338, 336, 374, 256, 410, 176, 374)
    $left = Poly @(176, 374, 256, 410, 256, 500, 176, 464)
    $right = Poly @(256, 410, 336, 374, 336, 464, 256, 500)
    # A straight inset square on the front face (not tilted, so it isn't anyone else's logo).
    $mark = Poly @(280, 426.2, 312, 411.8, 312, 447.8, 280, 462.2)
    return @(
        (Layer $left (Lin @(0, 0, 1, 1) @(@(0, "#F1F5FB"), @(1, "#C3CFE6")))),
        (Layer $right (Lin @(0, 0, 1, 1) @(@(0, "#A5C0FA"), @(1, "#7C83F0")))),
        (Layer $top (Lin @(0, 0, 1, 1) @(@(0, "#EEF2FF"), @(1, "#C7D2FE")))),
        (Layer (Line (P "M 176,374 L 256,410 L 336,374") 3) "#FFFFFF" 0.8),
        (Layer $mark $C.Midnight 0.88)
    )
}

function Get-Dashes {
    $d = U (Line (P "M 34,202 L 60,220") 13) (Line (P "M 20,256 L 52,258") 13) (Line (P "M 32,312 L 58,296") 13)
    return @((Layer $d (Lin @(0, 0, 1, 1) @(@(0, $C.Blue), @(1, $C.Violet)))), (Layer (Mirror $d) (Lin @(0, 0, 1, 1) @(@(0, $C.Violet), @(1, $C.Blue)))))
}
function Get-Badge([string]$mark) {
    $l = @((Layer (E 410 92 36 36) $C.Midnight), (Layer (E 410 92 29 29) (Lin @(0, 0, 1, 1) @(@(0, $C.Blue), @(1, $C.Violet)))))
    if ($mark -eq "check") { $l += Layer (Line (P "M 396,92 L 406,102 L 424,82") 8) "#FFFFFF" }
    else { $l += Layer (U (RR 405.5 72 9 26 4.5 4.5 4.5 4.5) (E 410 107 5 5)) "#FFFFFF" }
    return $l
}
function Get-Confetti {
    $bits = @(@(150, 70, 25, $C.Blue), @(96, 132, -20, $C.Violet), @(400, 116, 15, "#FFFFFF"), @(214, 22, -30, $C.Violet), @(360, 30, 35, $C.Blue), @(470, 170, -10, $C.Violet), @(44, 166, 40, "#FFFFFF"))
    return @(foreach ($b in $bits) { Layer (Turn (RR ($b[0] - 8) ($b[1] - 6) 16 12 2 2 2 2) $b[2] $b[0] $b[1]) $b[3] 0.95 })
}

function Get-Mascot([string]$expr) {
    $eyes = @{ default = "oval"; happy = "happy"; working = "narrow"; success = "happy"; attention = "wide"; idle = "closed"; error = "worried"; wave1 = "happy"; wave2 = "happy"; celebrate = "happy" }[$expr]
    $l = @()
    $l += Layer (P "M 0,0 L 512,0 L 512,512 L 0,512 Z") "#00000000"   # keeps every expression the same size
    if ($expr -eq "celebrate") { $l += Get-Confetti }
    if (@("happy", "celebrate") -contains $expr) { $l += Get-Dashes }
    if ($expr -eq "working") { $l += Layer (E 256 430 150 100) (Rad @(0.5, 0.5, 0.5) @(@(0, "#908B5CF6"), @(1, "#008B5CF6"))) }
    $l += Layer (P "M 140,356 C 120,404 128,464 164,498 C 200,514 312,514 348,498 C 384,464 392,404 372,356 Z") (Lin @(0, 0, 1, 1) @(@(0, $C.Blue), @(1, $C.Violet)))   # the body, a blue-violet cape
    $l += Get-Head $eyes
    $left = Get-Arm "left"
    $right = $(if ($expr -like "wave*") { Get-Arm "right" -Raised -turn $(if ($expr -eq "wave2") { -16 } else { 0 }) } else { Get-Arm "right" })
    $l += $left.Back + $right.Back
    $l += Get-Cube
    $l += $left.Mitt + $right.Mitt
    if ($expr -like "wave*") { $l += Layer (U (Line (P "M 466,266 L 490,252") 11) (Line (P "M 468,306 L 494,312") 11)) (Lin @(0, 0, 1, 1) @(@(0, $C.Blue), @(1, $C.Violet))) }
    if ($expr -eq "success") { $l += Get-Badge "check" }
    if ($expr -eq "attention") { $l += Get-Badge "bang" }
    return $l
}

# =============================================================== EMBLEMS ==
$EmblemBox = "M 74,16 L 440,16 L 440,382 L 74,382 Z"   # 366 x 366 around the head
function Get-Emblem([string]$eyes = "happy") { @(Layer (P $EmblemBox) "#00000000") + (Get-Head $eyes) }
function Get-EmblemSimple([switch]$Tiny) {
    # For 16-32 px: the silhouette, the visor and two thick eyes; nothing finer than a pixel or two.
    $arc = @((P "M 188,262 C 196,216 248,216 256,262"), (P "M 276,262 C 284,216 336,216 344,262"))
    @((Layer (P $EmblemBox) "#00000000"),
      (Layer (Get-Hood) $C.Cloud),
      (Layer (Both (Get-Hood) (P $FoldLeft)) $C.Blue),
      (Layer (Get-Face) $C.Midnight),
      $(if ($Tiny) { Layer (U (E 212 250 26 32) (E 320 250 26 32)) "#60A5FA" } else { Layer (Lines $arc 36) "#60A5FA" }))
}
function Get-EmblemMono([string]$ink) {
    $hole = U (Get-Face) (Line (Get-Face) 18)
    $arc = @((P "M 196,258 C 203,222 241,222 248,258"), (P "M 284,258 C 291,222 329,222 336,258"))
    @((Layer (P $EmblemBox) "#00000000"), (Layer (Cut (Get-Hood) $hole) $ink), (Layer (Lines $arc 24) $ink))
}
function Get-AppIcon([switch]$Small, [switch]$Tiny) {
    # Rounded Midnight tile with the emblem; the tile keeps it readable on light and dark taskbars.
    $tile = RR 16 16 480 480 108 108 108 108
    $l = @((Layer $tile (Lin @(0, 0, 0, 1) @(@(0, "#141B27"), @(1, $C.Midnight)))))
    if (-not $Small) { $l += Layer (Cut $tile (RR 26 26 460 460 98 98 98 98)) (Lin @(0, 0, 1, 1) @(@(0, $C.Blue), @(1, $C.Violet))) 0.9 }
    $art = $(if ($Small) { Get-EmblemSimple -Tiny:$Tiny } else { Get-Emblem "happy" })
    $k = $(if ($Small) { 1.38 } else { 1.08 })
    $t = New-Object System.Windows.Media.TransformGroup
    $t.Children.Add((New-Object System.Windows.Media.TranslateTransform(-257, -205))); $t.Children.Add((New-Object System.Windows.Media.ScaleTransform($k, $k))); $t.Children.Add((New-Object System.Windows.Media.TranslateTransform(256, $(if ($Small) { 276 } else { 266 }))))
    foreach ($a in ($art | Select-Object -Skip 1)) { $l += Layer (Tx $a.G $t) $a.F $a.O }
    return $l
}

# ============================================================== WORDMARK ==
# A heavy geometric wordmark built from rounded blocks: cap height 100, x-height 72.
function Get-Glyphs {
    $B = Cut (Cut (U (RR 0 0 84 54 6 24 18 0) (RR 0 46 90 54 0 18 26 6)) (RR 28 21 30 15 2 6 6 2)) (RR 28 60 34 19 2 7 7 2)
    $l = RR 0 0 28 100 6 6 6 6
    $o = Cut (RR 0 28 84 72 24 24 24 24) (RR 28 50 28 28 6 6 6 6)
    $x = U (Poly @(0, 28, 35, 28, 90, 100, 55, 100)) (Poly @(55, 28, 90, 28, 35, 100, 0, 100))
    $K = Both (U (RR 0 0 28 100 6 6 6 6) (Poly @(22, 52, 60, 0, 95, 0, 52, 58)) (Poly @(40, 42, 95, 100, 60, 100, 22, 64))) (Poly @(0, 0, 95, 0, 95, 100, 0, 100))
    $i = U (RR 0 28 28 72 6 6 6 6) (RR 0 0 28 20 6 6 6 6)
    $t = U (RR 12 4 28 96 6 6 6 6) (RR 0 28 58 21 4 4 4 4) (RR 12 79 46 21 0 4 6 6)
    $gap = 9; $at = 0; $blox = $null; $kit = $null
    foreach ($g in @(@($B, 90, 1), @($l, 28, 1), @($o, 84, 1), @($x, 90, 1), @($K, 95, 2), @($i, 28, 2), @($t, 58, 2))) {
        $m = Shift $g[0] $at 0
        if ($g[2] -eq 1) { $blox = $(if ($blox) { U $blox $m } else { $m }) } else { $kit = $(if ($kit) { U $kit $m } else { $m }) }
        $at += $g[1] + $gap
    }
    return @{ Blox = $blox; Kit = $kit; Width = $at - $gap }
}
function Get-Wordmark([double]$x, [double]$y, [double]$scale, [string]$bloxInk = $C.Cloud, $kitInk = $null) {
    $w = Get-Glyphs
    $t = New-Object System.Windows.Media.TransformGroup
    $t.Children.Add((New-Object System.Windows.Media.ScaleTransform($scale, $scale))); $t.Children.Add((New-Object System.Windows.Media.TranslateTransform($x, $y)))
    $kitFill = $(if ($kitInk) { $kitInk } else { Lin @(0, 0, 1, 1) @(@(0, $C.Blue), @(1, $C.Violet)) })
    return @{ Layers = @((Layer (Tx $w.Blox $t) $bloxInk), (Layer (Tx $w.Kit $t) $kitFill)); Width = $w.Width * $scale }
}
function Get-Logo {
    # Mascot above the wordmark. Canvas 600 x 700.
    $l = @(Layer (P "M 0,0 L 600,0 L 600,700 L 0,700 Z") "#00000000")
    $t = New-Object System.Windows.Media.TranslateTransform(44, 0)
    foreach ($a in (Get-Mascot "happy" | Select-Object -Skip 1)) { $l += Layer (Tx $a.G $t) $a.F $a.O }
    $wm = Get-Wordmark 0 540 1
    $off = (600 - $wm.Width) / 2
    foreach ($a in $wm.Layers) { $l += Layer (Shift $a.G $off 0) $a.F $a.O }
    return $l
}
function Get-LogoH([string]$mode = "color") {
    # Emblem + wordmark side by side. Canvas 980 x 300.
    $l = @(Layer (P "M 0,0 L 980,0 L 980,300 L 0,300 Z") "#00000000")
    $art = $(switch ($mode) { "light" { Get-EmblemMono $C.Cloud } "dark" { Get-EmblemMono $C.Midnight } default { Get-Emblem "happy" } })
    $t = New-Object System.Windows.Media.TransformGroup
    $t.Children.Add((New-Object System.Windows.Media.TranslateTransform(-74, -16))); $t.Children.Add((New-Object System.Windows.Media.ScaleTransform(0.78, 0.78))); $t.Children.Add((New-Object System.Windows.Media.TranslateTransform(4, 6)))
    foreach ($a in ($art | Select-Object -Skip 1)) { $l += Layer (Tx $a.G $t) $a.F $a.O }
    $ink = $(switch ($mode) { "light" { @($C.Cloud, $C.Cloud) } "dark" { @($C.Midnight, $C.Midnight) } "onlight" { @($C.Midnight, $null) } default { @($C.Cloud, $null) } })
    $wm = Get-Wordmark 312 82 1.3 $ink[0] $ink[1]
    $l += $wm.Layers
    return $l
}

# ================================================================ OUTPUT ==
function Fmt([double]$v) { [Math]::Round($v, 2).ToString($IC) }
function PathData($g) {
    $s = [System.Windows.Media.PathGeometry]::CreateFromGeometry($g).ToString($IC)
    $s = $s -replace '^F[01]', ''
    return [regex]::Replace($s, '-?\d+\.\d+(E-?\d+)?', { param($m) Fmt ([double]::Parse($m.Value, $IC)) })
}
function Hex8([string]$h) { if ($h.Length -eq 9) { $h } else { "#FF" + $h.Substring(1) } }
function New-Brush($f, [double]$o) {
    $b = $(if ($f -is [string]) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString((Hex8 $f))) }
           elseif ($f.L) { $lg = New-Object System.Windows.Media.LinearGradientBrush; $lg.StartPoint = New-Object System.Windows.Point($f.L[0], $f.L[1]); $lg.EndPoint = New-Object System.Windows.Point($f.L[2], $f.L[3]); $lg }
           else { $rg = New-Object System.Windows.Media.RadialGradientBrush; $rg.Center = New-Object System.Windows.Point($f.R[0], $f.R[1]); $rg.GradientOrigin = $rg.Center; $rg.RadiusX = $f.R[2]; $rg.RadiusY = $f.R[2]; $rg })
    if ($f -isnot [string]) { foreach ($s in $f.S) { $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString((Hex8 $s[1]))), $s[0])) } }
    $b.Opacity = $o
    return $b
}
function To-Drawing($layers) {
    $dg = New-Object System.Windows.Media.DrawingGroup
    foreach ($a in $layers) { $dg.Children.Add((New-Object System.Windows.Media.GeometryDrawing((New-Brush $a.F $a.O), $null, $a.G))) }
    return $dg
}
function Svg-Color([string]$h) { $h = Hex8 $h; @{ C = "#" + $h.Substring(3); A = [Math]::Round([Convert]::ToInt32($h.Substring(1, 2), 16) / 255, 3) } }
function To-Svg($layers, [double[]]$vb, [string]$title) {
    $defs = @(); $body = @(); $n = 0
    foreach ($a in ($layers | Where-Object { -not ($_.F -is [string] -and $_.F -eq "#00000000") })) {
        $fill = ""
        if ($a.F -is [string]) { $c = Svg-Color $a.F; $fill = "fill=`"$($c.C)`"" + $(if ($c.A -lt 1) { " fill-opacity=`"$($c.A)`"" } else { "" }) }
        else {
            $n++; $id = "g$n"
            $stops = ($a.F.S | ForEach-Object { $c = Svg-Color $_[1]; "<stop offset=`"$(Fmt $_[0])`" stop-color=`"$($c.C)`"" + $(if ($c.A -lt 1) { " stop-opacity=`"$($c.A)`"" } else { "" }) + "/>" }) -join ""
            if ($a.F.L) { $defs += "<linearGradient id=`"$id`" x1=`"$(Fmt $a.F.L[0])`" y1=`"$(Fmt $a.F.L[1])`" x2=`"$(Fmt $a.F.L[2])`" y2=`"$(Fmt $a.F.L[3])`">$stops</linearGradient>" }
            else { $defs += "<radialGradient id=`"$id`" cx=`"$(Fmt $a.F.R[0])`" cy=`"$(Fmt $a.F.R[1])`" r=`"$(Fmt $a.F.R[2])`">$stops</radialGradient>" }
            $fill = "fill=`"url(#$id)`""
        }
        $op = $(if ($a.O -lt 1) { " opacity=`"$(Fmt $a.O)`"" } else { "" })
        $body += "  <path d=`"$(PathData $a.G)`" $fill$op/>"
    }
    "<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"$($vb -join ' ')`" width=`"$($vb[2])`" height=`"$($vb[3])`">`n  <title>$title</title>`n  <defs>$($defs -join '')</defs>`n$($body -join "`n")`n</svg>`n"
}
function To-Xaml($layers, [string]$key) {
    $items = foreach ($a in $layers) {
        $geo = "F1 " + (PathData $a.G)
        if ($a.F -is [string]) { "      <GeometryDrawing Geometry=`"$geo`"><GeometryDrawing.Brush><SolidColorBrush Color=`"$(Hex8 $a.F)`" Opacity=`"$(Fmt $a.O)`"/></GeometryDrawing.Brush></GeometryDrawing>" }
        else {
            $stops = ($a.F.S | ForEach-Object { "<GradientStop Offset=`"$(Fmt $_[0])`" Color=`"$(Hex8 $_[1])`"/>" }) -join ""
            $br = $(if ($a.F.L) { "<LinearGradientBrush StartPoint=`"$(Fmt $a.F.L[0]),$(Fmt $a.F.L[1])`" EndPoint=`"$(Fmt $a.F.L[2]),$(Fmt $a.F.L[3])`" Opacity=`"$(Fmt $a.O)`">$stops</LinearGradientBrush>" }
                     else { "<RadialGradientBrush Center=`"$(Fmt $a.F.R[0]),$(Fmt $a.F.R[1])`" GradientOrigin=`"$(Fmt $a.F.R[0]),$(Fmt $a.F.R[1])`" RadiusX=`"$(Fmt $a.F.R[2])`" RadiusY=`"$(Fmt $a.F.R[2])`" Opacity=`"$(Fmt $a.O)`">$stops</RadialGradientBrush>" })
            "      <GeometryDrawing Geometry=`"$geo`"><GeometryDrawing.Brush>$br</GeometryDrawing.Brush></GeometryDrawing>"
        }
    }
    "  <DrawingImage x:Key=`"$key`" po:Freeze=`"True`"><DrawingImage.Drawing><DrawingGroup>`n$($items -join "`n")`n  </DrawingGroup></DrawingImage.Drawing></DrawingImage>"
}
function Render($layers, [double[]]$vb, [int]$w, [int]$h) {
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $k = [Math]::Min($w / $vb[2], $h / $vb[3])
    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform((($w - $vb[2] * $k) / 2), (($h - $vb[3] * $k) / 2))))
    $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform($k, $k)))
    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform(-$vb[0], -$vb[1])))
    $dc.DrawDrawing((To-Drawing $layers))
    $dc.Close()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    return $bmp
}
function Save-Png($bmp, [string]$path) {
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($path); $enc.Save($fs); $fs.Close()
}
function Get-DibBytes($bmp) {
    # A classic icon image: header, straight-alpha BGRA rows bottom-up, then an empty AND mask.
    $s = $bmp.PixelWidth
    $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($bmp, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $px = New-Object byte[] ($s * $s * 4); $conv.CopyPixels($px, $s * 4, 0)
    $ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter($ms)
    $maskRow = [int][Math]::Ceiling($s / 32) * 4
    $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]($s * $s * 4 + $maskRow * $s)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $s - 1; $y -ge 0; $y--) { $bw.Write($px, $y * $s * 4, $s * 4) }
    $bw.Write((New-Object byte[] ($maskRow * $s)))
    $bw.Flush(); return $ms.ToArray()
}
function Save-Ico([string]$path) {
    $sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
    $images = foreach ($s in $sizes) {
        $art = $(if ($s -le 24) { Get-AppIcon -Small -Tiny } elseif ($s -le 32) { Get-AppIcon -Small } else { Get-AppIcon })
        $bmp = Render $art @(0, 0, 512, 512) $s $s
        if ($s -ge 256) { $ms = New-Object IO.MemoryStream; $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp)); $enc.Save($ms); , $ms.ToArray() }
        else { , (Get-DibBytes $bmp) }
    }
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
    $bw.Flush(); [IO.File]::WriteAllBytes($path, $ms.ToArray())
}

# ---- everything ----
$Expressions = "default", "happy", "working", "success", "attention", "idle", "error", "wave1", "wave2", "celebrate"
$assets = [ordered]@{}
foreach ($e in $Expressions) { $assets["mascot-$e"] = @{ L = (Get-Mascot $e); VB = @(0, 0, 512, 512); Key = "Bk.Mascot." + (Get-Culture).TextInfo.ToTitleCase($e); Px = @(512, 512) } }
$assets["emblem"] = @{ L = (Get-Emblem "happy"); VB = @(74, 16, 366, 366); Key = "Bk.Emblem"; Px = @(366, 366) }
$assets["emblem-default"] = @{ L = (Get-Emblem "oval"); VB = @(74, 16, 366, 366); Key = "Bk.Emblem.Default"; Px = @(366, 366) }
$assets["emblem-mono-light"] = @{ L = (Get-EmblemMono $C.Cloud); VB = @(74, 16, 366, 366); Key = "Bk.Emblem.MonoLight"; Px = @(366, 366) }
$assets["emblem-mono-dark"] = @{ L = (Get-EmblemMono $C.Midnight); VB = @(74, 16, 366, 366); Key = "Bk.Emblem.MonoDark"; Px = @(366, 366) }
$assets["app-icon"] = @{ L = (Get-AppIcon); VB = @(0, 0, 512, 512); Key = "Bk.AppIcon"; Px = @(512, 512) }
$assets["app-icon-small"] = @{ L = (Get-AppIcon -Small); VB = @(0, 0, 512, 512); Key = "Bk.AppIcon.Small"; Px = @(64, 64) }
$wm = Get-Wordmark 0 0 1
$assets["wordmark"] = @{ L = (@(Layer (P "M 0,-4 L $($wm.Width),-4 L $($wm.Width),104 L 0,104 Z") "#00000000") + $wm.Layers); VB = @(0, -4, $wm.Width, 108); Key = "Bk.Wordmark"; Px = @([int]($wm.Width * 2), 216) }
$assets["logo"] = @{ L = (Get-Logo); VB = @(0, 0, 600, 700); Key = "Bk.Logo"; Px = @(600, 700) }
$assets["logo-horizontal"] = @{ L = (Get-LogoH); VB = @(0, 0, 980, 300); Key = "Bk.LogoHorizontal"; Px = @(980, 300) }
$assets["logo-horizontal-on-light"] = @{ L = (Get-LogoH "onlight"); VB = @(0, 0, 980, 300); Key = "Bk.LogoHorizontal.OnLight"; Px = @(980, 300) }
$assets["logo-horizontal-mono-light"] = @{ L = (Get-LogoH "light"); VB = @(0, 0, 980, 300); Key = "Bk.LogoHorizontal.MonoLight"; Px = @(980, 300) }
$assets["logo-horizontal-mono-dark"] = @{ L = (Get-LogoH "dark"); VB = @(0, 0, 980, 300); Key = "Bk.LogoHorizontal.MonoDark"; Px = @(980, 300) }

$xamlParts = @()
foreach ($name in $assets.Keys) {
    $a = $assets[$name]
    [IO.File]::WriteAllText((Join-Path $Out "$name.svg"), (To-Svg $a.L $a.VB "BloxKit $name"))
    Save-Png (Render $a.L $a.VB $a.Px[0] $a.Px[1]) (Join-Path $Out "$name.png")
    if (($name -notlike "*mono*" -and $name -notlike "*on-light*" -and $name -notlike "logo*") -or $name -eq "emblem-mono-light") { $xamlParts += To-Xaml $a.L $a.Key }
}
$dict = "<ResourceDictionary xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" xmlns:x=`"http://schemas.microsoft.com/winfx/2006/xaml`"`n" +
        "                    xmlns:po=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation/options`">`n" +
        "  <!-- Generated by tools\build-brand.ps1. Don't edit by hand: change the shapes there and run it again. -->`n" + ($xamlParts -join "`n") + "`n</ResourceDictionary>`n"
[IO.File]::WriteAllText((Join-Path $Out "BloxKit.Art.xaml"), $dict, (New-Object Text.UTF8Encoding $false))
Save-Ico (Join-Path $Root "assets\BloxKit.ico")

# A contact sheet to check everything at a glance (also used in the README).
$sheet = New-Object System.Windows.Media.DrawingVisual
$dc = $sheet.RenderOpen()
$dc.DrawRectangle((New-Brush $C.Midnight 1), $null, (New-Object System.Windows.Rect(0, 0, 1600, 900)))
$i = 0
foreach ($e in $Expressions) {
    $x = 20 + ($i % 5) * 230; $y = 20 + [Math]::Floor($i / 5) * 250
    $dc.DrawImage((Render (Get-Mascot $e) @(0, 0, 512, 512) 220 220), (New-Object System.Windows.Rect($x, $y, 220, 220)))
    $ft = New-Object System.Windows.Media.FormattedText($e, $IC, "LeftToRight", (New-Object System.Windows.Media.Typeface("Segoe UI")), 16, (New-Brush "#94A3B8" 1), 1.0)
    $dc.DrawText($ft, (New-Object System.Windows.Point(($x + 90), ($y + 222))))
    $i++
}
$dc.DrawImage((Render (Get-LogoH) @(0, 0, 980, 300) 460 141), (New-Object System.Windows.Rect(1160, 30, 420, 129)))
$dc.DrawImage((Render (Get-Logo) @(0, 0, 600, 700) 300 350), (New-Object System.Windows.Rect(1230, 190, 280, 327)))
$x = 1160
foreach ($s in 16, 24, 32, 48, 64) { $dc.DrawImage((Render $(if ($s -le 24) { Get-AppIcon -Small -Tiny } elseif ($s -le 32) { Get-AppIcon -Small } else { Get-AppIcon }) @(0, 0, 512, 512) $s $s), (New-Object System.Windows.Rect($x, 560, $s, $s))); $x += $s + 18 }
$dc.DrawImage((Render (Get-LogoH "light") @(0, 0, 980, 300) 400 122), (New-Object System.Windows.Rect(1160, 660, 400, 122)))
$dc.DrawRectangle((New-Brush $C.Cloud 1), $null, (New-Object System.Windows.Rect(1160, 790, 420, 100)))
$dc.DrawImage((Render (Get-LogoH "dark") @(0, 0, 980, 300) 300 92), (New-Object System.Windows.Rect(1170, 794, 300, 92)))
$dc.Close()
$bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(1600, 900, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32); $bmp.Render($sheet)
Save-Png $bmp (Join-Path $Out "brand-sheet.png")
"Wrote $($assets.Count) assets to $Out, BloxKit.Art.xaml and assets\BloxKit.ico."
