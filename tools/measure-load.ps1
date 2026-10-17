# Measures how hard your PC works while Roblox clients run, and says what limits it.
# Run it WHILE the lag happens (clients open and in game):
#     powershell -ExecutionPolicy Bypass -File tools\measure-load.ps1
#     powershell -ExecutionPolicy Bypass -File tools\measure-load.ps1 -Seconds 120
# It only reads; it changes nothing. The report is also saved on your Desktop.
param([int]$Seconds = 60, [int]$Every = 5)
. (Join-Path $PSScriptRoot "..\BloxKit.ps1") -TestOnly
Add-Type -AssemblyName System.Windows.Forms

$lines = New-Object System.Collections.ArrayList
function Out-Line([string]$s = "") { [void]$lines.Add($s); $s }

# ---- what this PC is ----
$cpuName = try { (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name.Trim() } catch { "unknown" }
$adapters = Get-GpuAdapters
$power = [System.Windows.Forms.SystemInformation]::PowerStatus
$onBattery = $power.PowerLineStatus -eq "Offline"
$gbs = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Roblox") -Filter "GlobalBasicSettings_*.xml" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$graphics = $(if ($gbs) { Read-RobloxGraphics ([IO.File]::ReadAllText($gbs.FullName)) } else { @{ Quality = $null; FpsCap = $null } })
$pref = @()
$k = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
if (Test-Path $k) { $pref = @((Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -match 'Roblox' } | ForEach-Object { "$($_.Name) = $($_.Value)" }) }
# The app: BloxKit.exe, or PowerShell running BloxKit.ps1 (the .bat). Test copies (-NoRoblox) don't count.
$mgr = @(Get-CimInstance Win32_Process -Filter "Name='BloxKit.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { ($_.Name -eq 'BloxKit.exe' -or $_.CommandLine -match 'BloxKit.ps1') -and $_.CommandLine -notmatch 'NoRoblox|measure-load' }) | Select-Object -First 1

Out-Line "ROBLOX MANAGER - LOAD MEASUREMENT  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Out-Line "Processor:   $cpuName ($([Environment]::ProcessorCount) threads)"
foreach ($l in $adapters.Keys) { Out-Line ("Graphics:    {0}, {1:N1} GB video memory{2}" -f $adapters[$l].Name, ($adapters[$l].VramMB / 1024), $(if (Test-IntegratedGpu $adapters[$l]) { "  (built-in)" } else { "" })) }
Out-Line ("Power:       " + $(if ($onBattery) { "ON BATTERY ($([int]($power.BatteryLifePercent * 100))%)" } else { "plugged in" }))
Out-Line ("Roblox graphics (all clients share it): quality " + $(if ($null -eq $graphics.Quality) { "unknown" } elseif ($graphics.Quality -eq 0) { "Automatic" } else { "$($graphics.Quality) of 10" }) +
          ", frame rate cap " + $(if ($null -eq $graphics.FpsCap) { "unknown" } elseif ($graphics.FpsCap -le 0) { "not set (Roblox default)" } else { "$($graphics.FpsCap)" }))
Out-Line ("Windows graphics choice for Roblox: " + $(if ($pref.Count) { $pref -join "; " } else { "none (Windows decides)" }))
Out-Line ""
Out-Line "Measuring for $Seconds seconds (every $Every s)..."

# ---- measure ----
$readings = @(); $comparisons = @()
$prev = Get-LoadReading $(if ($mgr) { $mgr.ProcessId } else { 0 })
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    Start-Sleep -Seconds $Every
    $now = Get-LoadReading $(if ($mgr) { $mgr.ProcessId } else { 0 })
    $c = Compare-LoadReadings $prev $now
    $comparisons += $c; $prev = $now
    Write-Host ("  {0,3}s  clients {1,2}  CPU {2,5:N1}%  free memory {3,5:N1} GB  GPU {4}" -f [int]($Seconds - ($end - (Get-Date)).TotalSeconds), @($c.Clients).Count, $c.CpuTotalPct, $c.RamFreeGB,
        $(if ($c.GpuByAdapter) { ($c.GpuByAdapter.Keys | ForEach-Object { "{0} {1:N0}%" -f $(if ($adapters[$_]) { $adapters[$_].Name } else { $_ }), $c.GpuByAdapter[$_].BusyPct }) -join ", " } else { "not available" }))
}
$sum = ConvertTo-LoadFacts $comparisons $adapters $graphics $onBattery
$f = $sum.Facts

# ---- report ----
Out-Line ""
Out-Line ("RESULT ({0} clients)" -f $f.Clients)
Out-Line ("  Processor, all cores:  {0}" -f $(if ($null -ne $f.CpuTotalPct) { "{0:N0}% busy on average" -f $f.CpuTotalPct } else { "not available" }))
Out-Line ("  Memory:                {0}" -f $(if ($null -ne $f.RamFreeGB) { "{0:N1} GB free at the lowest, of {1:N0} GB" -f $f.RamFreeGB, $f.RamTotalGB } else { "not available" }))
Out-Line ("  Swapping to disk:      {0}" -f $(if ($null -ne $f.PagesPerSec) { "{0:N0} pages/s at the most" -f $f.PagesPerSec } else { "not available" }))
if ($f.Adapters) { foreach ($a in $f.Adapters) { Out-Line ("  {0}: {1:N0}% busy on average, {2} client(s) on it" -f $a.Name, $a.BusyPct, $a.RobloxCount) } }
else { Out-Line "  Graphics use:          not available (Windows didn't give GPU counters)" }
Out-Line ("  BloxKit itself: {0}" -f $(if ($null -ne $f.ManagerCpuPct) { "{0:N2}% of the processor" -f $f.ManagerCpuPct } else { "not running" }))
$ch = $comparisons[-1].Chrome
if ($ch) { Out-Line ("  Chrome:                {0} processes, {1:N1} GB" -f $ch.Count, ($ch.MemMB / 1024)) }
Out-Line ""
Out-Line "PER CLIENT (average)"
foreach ($x in $sum.Clients) {
    Out-Line ("  pid {0,-6}  CPU {1,5:N1}%   memory {2,5:N0} MB   GPU {3}" -f $x.Pid, $x.CpuPct, $x.MemMB,
        $(if ($null -ne $x.GpuPct) { "{0,5:N1}% on {1}" -f $x.GpuPct, $x.Adapter } else { "not available" }))
}
Out-Line ""
$find = @(Get-LoadFindings $f)
if ($find.Count) {
    Out-Line "WHAT LIMITS IT (most important first)"
    $i = 0
    foreach ($x in $find) {
        $i++
        Out-Line "  $i. [$($x.Severity)] $($x.Title)"
        Out-Line "     Seen:  $($x.Seen)"
        Out-Line "     Why:   $($x.Why)"
        Out-Line "     Do:    $($x.Fix)"
    }
} else { Out-Line "Nothing is maxed out in this measurement. If it still lags, measure again while it lags." }

$desk = [Environment]::GetFolderPath("Desktop")
$file = Join-Path $(if ($desk -and (Test-Path $desk)) { $desk } else { $PSScriptRoot }) ("BloxKit-load-" + (Get-Date -Format "yyyyMMdd-HHmm") + ".txt")
[IO.File]::WriteAllLines($file, [string[]]$lines)
""
"Saved: $file"
