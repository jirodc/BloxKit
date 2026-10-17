# Checks how Roblox Manager reads Roblox's graphics settings and turns load measurements into advice.
#     powershell -ExecutionPolicy Bypass -File tools\check-load.ps1
# No app window; made-up measurements.
. (Join-Path $PSScriptRoot "..\RobloxManager.ps1") -TestOnly

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}
function Titles($f) { (@($f) | ForEach-Object { $_.Title }) -join " | " }

try {
    # ---- Roblox's own graphics settings (GlobalBasicSettings_13.xml, shared by every client) ----
    $xml = '<roblox><Item class="UserGameSettings"><Properties><int name="FramerateCap">-1</int><int name="GraphicsQualityLevel">21</int><token name="SavedQualityLevel">10</token></Properties></Item></roblox>'
    $r = Read-RobloxGraphics $xml
    Check "reads the graphics quality (10 = highest) and frame rate cap (-1 = Roblox's default)" ($r.Quality -eq 10 -and $r.FpsCap -eq -1)
    $r = Read-RobloxGraphics '<roblox><token name="SavedQualityLevel">0</token><int name="FramerateCap">30</int></roblox>'
    Check "quality 0 is 'Automatic'; a 30 FPS cap is read" ($r.Quality -eq 0 -and $r.FpsCap -eq 30)
    Check "a file it can't read gives 'unknown', not a guess" ($null -eq (Read-RobloxGraphics "not xml").Quality)

    # ---- comparing two readings ----
    # 10 s apart, 16 threads; times in ms; system times in 100 ns like GetSystemTimes.
    $luid = "0x00000000_0x0000da19"
    $a = @{ Ms = 0; Threads = 16; RamTotalMB = 16384; RamFreeMB = 4096; PagesRaw = 1000
            Sys = @{ Idle = 0; Kernel = 0; User = 0 }
            Procs = @{ 11 = @{ Kind = "roblox"; CpuMs = 0; MemMB = 1500 }; 12 = @{ Kind = "roblox"; CpuMs = 0; MemMB = 1700 }
                       21 = @{ Kind = "chrome"; CpuMs = 0; MemMB = 300 }; 22 = @{ Kind = "chrome"; CpuMs = 0; MemMB = 200 }; 31 = @{ Kind = "manager"; CpuMs = 0; MemMB = 190 } }
            Gpu = @{ "pid_11_luid_${luid}_phys_0_eng_0_engtype_3D" = @{ Raw = 0; Time = 0 }; "pid_12_luid_${luid}_phys_0_eng_0_engtype_3D" = @{ Raw = 0; Time = 0 } } }
    $b = @{ Ms = 10000; Threads = 16; RamTotalMB = 16384; RamFreeMB = 3072; PagesRaw = 6000
            Sys = @{ Idle = 40000000; Kernel = 100000000; User = 60000000 }   # 160 s of thread time, 40 s idle -> 75% busy
            Procs = @{ 11 = @{ Kind = "roblox"; CpuMs = 16000; MemMB = 1600 }; 12 = @{ Kind = "roblox"; CpuMs = 8000; MemMB = 1800 }
                       21 = @{ Kind = "chrome"; CpuMs = 1600; MemMB = 300 }; 22 = @{ Kind = "chrome"; CpuMs = 0; MemMB = 250 }; 31 = @{ Kind = "manager"; CpuMs = 160; MemMB = 191 } }
            Gpu = @{ "pid_11_luid_${luid}_phys_0_eng_0_engtype_3D" = @{ Raw = 3000000; Time = 100000000 }; "pid_12_luid_${luid}_phys_0_eng_0_engtype_3D" = @{ Raw = 2000000; Time = 100000000 } } }
    $c = Compare-LoadReadings $a $b
    Check "each client: CPU share, memory, GPU" (@($c.Clients).Count -eq 2 -and [Math]::Round(($c.Clients | Where-Object { $_.Pid -eq 11 }).CpuPct, 1) -eq 10 -and ($c.Clients | Where-Object { $_.Pid -eq 11 }).MemMB -eq 1600 -and [Math]::Round(($c.Clients | Where-Object { $_.Pid -eq 11 }).GpuPct, 1) -eq 3)
    Check "totals: whole CPU 75% busy, 3 GB free, 500 pages/s" ([Math]::Round($c.CpuTotalPct) -eq 75 -and $c.RamFreeGB -eq 3 -and [Math]::Round($c.PagesPerSec) -eq 500)
    Check "Chrome and Roblox Manager are counted separately" ($c.Chrome.Count -eq 2 -and $c.Chrome.MemMB -eq 550 -and [Math]::Round($c.Chrome.CpuPct, 1) -eq 1 -and [Math]::Round($c.Manager.CpuPct, 1) -eq 0.1)
    Check "graphics chip total and how many clients are on it" ([Math]::Round($c.GpuByAdapter[$luid].BusyPct, 1) -eq 5 -and $c.GpuByAdapter[$luid].RobloxCount -eq 2)
    $a.Gpu = $null
    Check "no GPU counters: GPU is 'not available', not 0" ($null -eq (Compare-LoadReadings $a $b).GpuByAdapter -and $null -eq ((Compare-LoadReadings $a $b).Clients | Select-Object -First 1).GpuPct)

    # ---- summing up a measurement (several comparisons) ----
    $L1 = "0x00000000_0x0000da19"; $L2 = "0x00000000_0x0000ee68"
    $ads = @{ $L1 = @{ Name = "NVIDIA GeForce RTX 3060 Laptop GPU"; VramMB = 6144 }; $L2 = @{ Name = "AMD Radeon(TM) Graphics"; VramMB = 512 } }
    $c1 = @{ Clients = @(@{ Pid = 1; CpuPct = 10; MemMB = 1500; GpuPct = 20; Luid = $L1 }, @{ Pid = 2; CpuPct = 6; MemMB = 1700; GpuPct = 30; Luid = $L2 })
             CpuTotalPct = 80; RamTotalGB = 16; RamFreeGB = 3; PagesPerSec = 100; Manager = @{ CpuPct = 0.2 }; GpuByAdapter = @{ $L1 = @{ BusyPct = 60; RobloxCount = 1 }; $L2 = @{ BusyPct = 90; RobloxCount = 1 } } }
    $c2 = @{ Clients = @(@{ Pid = 1; CpuPct = 14; MemMB = 1600; GpuPct = 40; Luid = $L1 }, @{ Pid = 2; CpuPct = 8; MemMB = 1800; GpuPct = 50; Luid = $L2 })
             CpuTotalPct = 90; RamTotalGB = 16; RamFreeGB = 1; PagesPerSec = 900; Manager = @{ CpuPct = 0.4 }; GpuByAdapter = @{ $L1 = @{ BusyPct = 80; RobloxCount = 1 }; $L2 = @{ BusyPct = 100; RobloxCount = 1 } } }
    $s = ConvertTo-LoadFacts @($c1, $c2) $ads @{ Quality = 10; FpsCap = -1 } $true
    Check "averages: whole CPU 85%, Roblox Manager 0.3%" ($s.Facts.CpuTotalPct -eq 85 -and [Math]::Round($s.Facts.ManagerCpuPct, 1) -eq 0.3)
    Check "worst moments: lowest free memory (1 GB), most swapping (900/s)" ($s.Facts.RamFreeGB -eq 1 -and $s.Facts.PagesPerSec -eq 900)
    Check "each graphics chip: name, average busy, built-in or not" (($s.Facts.Adapters | Where-Object { $_.Name -match "Radeon" }).Integrated -and ($s.Facts.Adapters | Where-Object { $_.Name -match "Radeon" }).BusyPct -eq 95 -and -not ($s.Facts.Adapters | Where-Object { $_.Name -match "NVIDIA" }).Integrated)
    Check "per client averages for the report" (($s.Clients | Where-Object { $_.Pid -eq 1 }).CpuPct -eq 12 -and ($s.Clients | Where-Object { $_.Pid -eq 1 }).GpuPct -eq 30 -and ($s.Clients | Where-Object { $_.Pid -eq 1 }).Adapter -match "NVIDIA")
    Check "client count, settings and battery are passed on" ($s.Facts.Clients -eq 2 -and $s.Facts.Quality -eq 10 -and $s.Facts.OnBattery)
    $f = @(Get-LoadFindings $s.Facts)
    Check "...and give the right advice: built-in graphics first" ($f[0].Title -match "built-in graphics")

    # ---- limit on clients open at once ----
    Check "no limit: everyone may open" ((Get-LaunchAllowance 8 2 5 0) -eq 5)
    Check "limit 10, 6 open + 2 opening: 2 more may open" ((Get-LaunchAllowance 6 2 5 10) -eq 2)
    Check "limit reached: none" ((Get-LaunchAllowance 9 1 3 10) -eq 0)
    Check "already over the limit: none (never negative)" ((Get-LaunchAllowance 12 0 3 10) -eq 0)

    # ---- changing Roblox's graphics settings (the same values its Esc > Settings menu saves) ----
    $xml2 = '<roblox><Item class="UserGameSettings"><Properties><int name="FramerateCap">-1</int><int name="GraphicsQualityLevel">21</int><bool name="Fullscreen">false</bool><token name="SavedQualityLevel">10</token></Properties></Item></roblox>'
    $new2 = Set-RobloxGraphics $xml2 2 30
    $r2 = Read-RobloxGraphics $new2
    Check "sets quality 2 and a 30 FPS cap" ($r2.Quality -eq 2 -and $r2.FpsCap -eq 30)
    Check "keeps everything else exactly as it was" (($new2 -replace '<token name="SavedQualityLevel">\d+</token>', '' -replace '<int name="FramerateCap">-?\d+</int>', '' -replace '<int name="GraphicsQualityLevel">\d+</int>', '') -eq ($xml2 -replace '<token name="SavedQualityLevel">\d+</token>', '' -replace '<int name="FramerateCap">-?\d+</int>', '' -replace '<int name="GraphicsQualityLevel">\d+</int>', ''))
    Check "also moves Roblox's matching internal level (1-21 scale) so they agree" ($new2 -match '<int name="GraphicsQualityLevel">(\d+)</int>' -and [int]$Matches[1] -lt 21)
    Check "a file without these settings is left alone ($null)" ($null -eq (Set-RobloxGraphics '<roblox></roblox>' 2 30))
    Check "only valid values: quality 1-10, cap 30/60/144/240 or -1" ($null -eq (Set-RobloxGraphics $xml2 11 30) -and $null -eq (Set-RobloxGraphics $xml2 2 45))

    # ---- advice from the app's own state ----
    function SX { @{ MultiWindowOff = $false; RobloxRunning = 0; NeedSignIn = @(); SetupIssue = @(); LimitBlocked = @(); MaxClients = 0 } }
    Check "all fine: no advice" (@(Get-StateFindings (SX)).Count -eq 0)
    $x = SX; $x.MultiWindowOff = $true; $x.RobloxRunning = 2
    $f = @(Get-StateFindings $x)
    Check "multi-window off while Roblox runs: says so first, with the fix" ($f[0].Title -match "Multi-window is off" -and $f[0].Severity -eq "high" -and $f[0].Fix -match "Close Roblox and turn on")
    $x = SX; $x.MultiWindowOff = $true; $x.RobloxRunning = 0
    Check "multi-window off with no Roblox running: nothing (it turns on by itself)" (@(Get-StateFindings $x).Count -eq 0)
    $x = SX; $x.SharedProfile = @("A and B (Profile 4)")
    $f = @(Get-StateFindings $x)
    Check "two accounts on one Chrome profile: a high-priority tip naming them" ($f.Count -eq 1 -and $f[0].Severity -eq "high" -and $f[0].Seen -match "A and B \(Profile 4\)" -and $f[0].Nav -eq "accounts")
    $x = SX; $x.NeedSignIn = @("Alt4"); $x.SetupIssue = @("Main", "Alt2"); $x.LimitBlocked = @("Alt9"); $x.MaxClients = 8
    $f = @(Get-StateFindings $x)
    Check "sign-in, setup and limit: each named, and where to fix it" ((Titles $f) -match "sign in" -and ($f | Where-Object { $_.Title -match "sign in" }).Nav -eq "accounts" -and ($f | Where-Object { $_.Seen -match "Main, Alt2" }).Nav -eq "settings" -and ($f | Where-Object { $_.Seen -match "Alt9" }).Seen -match "8")

    # ---- advice from measurements ----
    function M { @{ Clients = 11; CpuTotalPct = 60; RamTotalGB = 16; RamFreeGB = 4; PagesPerSec = 50; OnBattery = $false
                    Adapters = @(@{ Name = "NVIDIA GeForce RTX 3060 Laptop GPU"; Integrated = $false; BusyPct = 60; RobloxCount = 11 }); Quality = 3; FpsCap = 30; ManagerCpuPct = 0.5 } }
    $f = @(Get-LoadFindings (M))
    Check "a machine that copes: no warnings" ($f.Count -eq 0) (Titles $f)

    $m = M; $m.Adapters[0].BusyPct = 97
    Check "graphics chip busy 97%: says the GPU is the limit" ((Titles (Get-LoadFindings $m)) -match "graphics chip is maxed out")
    $m = M; $m.Adapters = @(@{ Name = "AMD Radeon(TM) Graphics"; Integrated = $true; BusyPct = 80; RobloxCount = 7 }, @{ Name = "NVIDIA GeForce RTX 3060 Laptop GPU"; Integrated = $false; BusyPct = 20; RobloxCount = 4 })
    $f = @(Get-LoadFindings $m)
    Check "7 clients on the built-in graphics while a 3060 is there: says so, first" ($f[0].Title -match "built-in graphics" -and $f[0].Seen -match "7 of 11" -and $f[0].Severity -eq "high")
    $m = M; $m.RamFreeGB = 0.6; $m.PagesPerSec = 2500
    Check "memory nearly full and Windows swapping: says memory is the limit" ((Titles (Get-LoadFindings $m)) -match "memory is full")
    $mem = @(Get-LoadFindings $m) | Where-Object { $_.Title -match "memory is full" } | Select-Object -First 1
    Check "...with what was seen (free memory AND swapping), why, and what to do in the right places" ($mem.Seen -match "0\.6 GB free of 16 GB" -and $mem.Seen -match "2,?500" -and $mem.Why -match "moves parts of programs to the disk" -and $mem.Fix -match "Run fewer clients") "Seen=[$($mem.Seen)] Why=[$($mem.Why)] Fix=[$($mem.Fix)]"
    $m = M; $m.CpuTotalPct = 93
    Check "CPU at 93%: says the CPU is the limit" ((Titles (Get-LoadFindings $m)) -match "processor is maxed out")
    $m = M; $m.OnBattery = $true
    Check "on battery: says to plug in" ((Titles (Get-LoadFindings $m)) -match "battery")
    $m = M; $m.Quality = 10; $m.FpsCap = -1
    $f = @(Get-LoadFindings $m)
    Check "quality 10 with 11 clients: suggests lower quality and a frame cap" ((Titles $f) -match "graphics quality" -and (Titles $f) -match "frame rate")
    $m = M; $m.Quality = 10; $m.Clients = 2
    Check "quality 10 with only 2 clients: no nagging" (-not ((Titles (Get-LoadFindings $m)) -match "graphics quality"))
    $m = M; $m.ManagerCpuPct = 6
    Check "Roblox Manager itself busy: says so" ((Titles (Get-LoadFindings $m)) -match "Roblox Manager itself")
    $m = M; $m.Adapters = $null; $m.Quality = $null
    $f = @(Get-LoadFindings $m)
    Check "no GPU numbers or settings: nothing made up" (-not ((Titles $f) -match "graphics"))
    $m = M; $m.Adapters[0].BusyPct = 97; $m.RamFreeGB = 0.6; $m.PagesPerSec = 2500; $m.OnBattery = $true
    $f = @(Get-LoadFindings $m)
    Check "most important first (high before medium)" (($f | ForEach-Object { $_.Severity }) -join "," -match '^(high,)*high(,medium)*(,info)*$')
    Check "every finding says what was seen, why it matters and what to do" (@($f | Where-Object { -not ($_.Seen -and $_.Why -and $_.Fix) }).Count -eq 0)
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_  (line $($_.InvocationInfo.ScriptLineNumber))"
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All load checks passed." })
exit $script:fails
