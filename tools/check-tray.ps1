# Checks how BloxKit handles Roblox's tray copy: it's only closed while tray copies are all that's
# left of Roblox, and a launch that crashed on a closed tray copy's leftover record is spotted in
# Roblox's own log. Uses pretend log folders, and one real temp folder.
#     powershell -ExecutionPolicy Bypass -File tools\check-tray.ps1
. (Join-Path $PSScriptRoot "..\BloxKit.ps1") -TestOnly

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}

# ---- Roblox logs, as Roblox 0.743 writes them (IDs and addresses made up) ----
$Head = @"
[FLog::Output] All use of Roblox services must comply with Roblox's Terms of Use, Privacy Policy, Community Standards, and applicable laws.
2026-10-18T14:08:18.165Z,0.165000,8488,6,Info [FLog::PioneerConfig] No Pioneer config specified.
2026-10-18T14:08:18.174Z,0.174000,8488,6,Warning [FLog::RobloxStarter] Starting module: Logging
2026-10-18T14:08:18.176Z,0.176000,8488,6,Warning [FLog::RobloxStarter] Roblox stage ReadyForFlagFetch completed
2026-10-18T14:08:18.176Z,0.176000,8488,6,Warning [FLog::Output] NoReload Detector: warm start adjustment: 184

"@
$TrayLine = "2026-10-18T14:08:18.176Z,0.176000,8488,6,Warning [FLog::Output] NoReload Detector: WebPlay NoReload with Tray only!`n"
$CrashLine = "2026-10-18T14:08:18.178Z,0.178000,8488,6 [LOGCHANNELS + 1] RBXCRASH: UnhandledException (class wil::ResultException B:\Client\WindowsClient\SingleInstanceGuard.cpp(131)\RobloxPlayerBeta.exe!00007FF6A1B2C3D4: (caller: 00007FF6A1B2C3D5) Exception(1) tid(8488) 80070578 Invalid window handle.`n    Msg:[Failed to send message ID 49862, result: 0, error: 1400] `n)`n"
$Fix = @{
    Crash      = $Head + $TrayLine + $CrashLine                                                     # the crash (2026-10-18 22:08)
    Handoff    = $Head + $TrayLine + "2026-10-18T14:03:44.224Z,0.224000,232c,6,Warning [FLog::RobloxStarter] RobloxStarter destroyed`n"   # handed to a live tray copy: fine
    Normal     = $Head + "2026-10-18T14:02:27.057Z,2.057000,5d20,6 [FLog::Output] ! Joining game '00000000-1111-2222-3333-444444444444' place 1818 at 10.0.0.1`n"
    OtherCrash = $Head + $TrayLine + "2026-10-18T14:08:18.178Z,0.178000,8488,6 [LOGCHANNELS + 1] RBXCRASH: UnhandledException (class std::bad_alloc) Access violation.`n"
    NoTray     = $Head + $CrashLine                                                                  # the same handle error, but not a hand-off to a tray copy
    Reversed   = $Head + $CrashLine + $TrayLine
    UpToTray   = $Head + $TrayLine                                                                   # still being written: the crash line isn't there yet
    MidCrash   = $Head + $TrayLine + "2026-10-18T14:08:18.178Z,0.178000,8488,6 [LOGCHANNELS + 1] RBXCRASH: UnhandledException (class wil::ResultException B:\Client\WindowsClient\SingleInst"
}

# ---- a pretend Roblox log folder: List(dir) -> files, Read(path, maxBytes) -> text ----
# Each file: @{ Name; Created; Text; Size (optional, else the text's length); Fail (Read throws) }
function New-FakeLogs {
    $script:Files = @(); $script:Reads = New-Object System.Collections.ArrayList; $script:ListFails = $false
    @{
        List = { param($d) if ($script:ListFails) { throw "The device is not ready" }
                 foreach ($f in @($script:Files)) { [pscustomobject]@{ Name = $f.Name; FullName = "$d\$($f.Name)"; CreationTime = $f.Created; Length = $(if ($f.Size) { [long]$f.Size } else { [long]$f.Text.Length }) } } }
        Read = { param($p, $max) [void]$script:Reads.Add($p); $f = @($script:Files | Where-Object { $p.EndsWith("\" + $_.Name) })[0]
                 if ($f.Fail) { throw "The process cannot access the file because it is being used by another process" }; $f.Text }
    }
}
$Dir = "C:\fake\Roblox\logs"
$Start = [DateTime]"2026-10-18T22:08:12"
function LogName([string]$id) { "0.743.0.7431134_20261018T1408${id}Z_Player_${id}ABC_last.log" }

try {
    # ---- 1. closing tray copies: only when they're all that's left of Roblox ----
    Check "one tray copy and nothing else: close it" (Test-TrayCloseOk 1 1)
    Check "one tray copy and 4 game clients (5 Roblox): leave it" (-not (Test-TrayCloseOk 1 5))
    Check "two tray copies and nothing else: close them" (Test-TrayCloseOk 2 2)
    Check "two tray copies and one game client: leave them" (-not (Test-TrayCloseOk 2 3))
    Check "no tray copy: nothing to close" (-not (Test-TrayCloseOk 0 0) -and -not (Test-TrayCloseOk 0 3))
    Check "a tray copy that ended between the two looks (fewer Roblox than tray copies): still all that's left" (Test-TrayCloseOk 2 1)

    # ---- 2. the crash, in one Roblox log ----
    Check "the crash: a hand-off to the tray copy, then RBXCRASH with an invalid window handle" (Test-StaleTrayCrash $Fix.Crash)
    Check "a hand-off to a live tray copy (no crash) isn't it" (-not (Test-StaleTrayCrash $Fix.Handoff))
    Check "a normal client's log isn't it" (-not (Test-StaleTrayCrash $Fix.Normal))
    Check "a different crash after the hand-off isn't it" (-not (Test-StaleTrayCrash $Fix.OtherCrash))
    Check "an invalid window handle without the tray hand-off isn't it" (-not (Test-StaleTrayCrash $Fix.NoTray))
    Check "the two lines the wrong way round aren't it" (-not (Test-StaleTrayCrash $Fix.Reversed))
    Check "a log still being written (only up to the hand-off) isn't it yet" (-not (Test-StaleTrayCrash $Fix.UpToTray))
    Check "a log cut off inside the crash line (before 'Invalid window handle') isn't it yet" (-not (Test-StaleTrayCrash $Fix.MidCrash))
    Check "an empty or missing log isn't it" (-not (Test-StaleTrayCrash "") -and -not (Test-StaleTrayCrash $null))

    # ---- 3. finding the launch's crash log among Roblox's logs ----
    $port = New-FakeLogs
    $script:Files = @(@{ Name = (LogName "18"); Created = $Start.AddSeconds(6); Text = $Fix.Crash })
    $hit = Find-StaleTrayCrash $port $Dir $Start @()
    Check "the launch's own crash log is found (its path)" ($hit -eq "$Dir\$(LogName '18')") "got '$hit'"

    $script:Files = @(
        @{ Name = (LogName "01"); Created = $Start.AddSeconds(-30); Text = $Fix.Crash },                                         # from an earlier launch
        @{ Name = "0.743.0.7431134_20261018T140818Z_Player_9D1C2_CrashHandler_last.log"; Created = $Start.AddSeconds(6); Text = $Fix.Crash },
        @{ Name = (LogName "19"); Created = $Start.AddSeconds(7); Text = $Fix.Crash; Size = 9000 },                              # too big to be a 2 ms crash
        @{ Name = (LogName "20"); Created = $Start.AddSeconds(8); Text = $Fix.Crash },                                           # a window's log already
        @{ Name = (LogName "21"); Created = $Start.AddSeconds(9); Text = $Fix.UpToTray },
        @{ Name = (LogName "22"); Created = $Start.AddSeconds(9); Text = $Fix.Handoff })
    $script:Reads.Clear()
    $hit = Find-StaleTrayCrash $port $Dir $Start @("$Dir\$(LogName '20')")
    Check "nothing found among: an older log, a CrashHandler log, an oversized one, a window's log, an unfinished one, a fine hand-off" ($hit -eq "") "got '$hit'"
    $read = @($script:Reads | ForEach-Object { $_.Substring($_.LastIndexOf("\") + 1) })
    $want = (@((LogName "21"), (LogName "22")) | Sort-Object) -join ","
    Check "only the candidates are read (not the older, CrashHandler, oversized or window's log)" ((($read | Sort-Object) -join ",") -eq $want) ($read -join ",")
    Check "a log written at the very moment of the launch counts" ((& { $script:Files = @(@{ Name = (LogName "23"); Created = $Start; Text = $Fix.Crash }); Find-StaleTrayCrash $port $Dir $Start @() }) -ne "")

    $script:Files = @(@{ Name = (LogName "24"); Created = $Start.AddSeconds(5); Text = $Fix.Crash; Fail = $true }, @{ Name = (LogName "25"); Created = $Start.AddSeconds(6); Text = $Fix.Crash })
    $err = $null; try { $hit = Find-StaleTrayCrash $port $Dir $Start @() } catch { $err = $_ }
    Check "a log that can't be read is skipped; the next one is still found" ($null -eq $err -and $hit -eq "$Dir\$(LogName '25')") "$err / '$hit'"
    $script:ListFails = $true; $err = $null; try { $hit = Find-StaleTrayCrash $port $Dir $Start @() } catch { $err = $_ }
    Check "a log folder that can't be listed: nothing found, nothing thrown" ($null -eq $err -and $hit -eq "") "$err"
    $script:ListFails = $false; $script:Files = @()
    Check "an empty log folder: nothing found" ((Find-StaleTrayCrash $port $Dir $Start @()) -eq "")

    # ---- 4. the real log folder port, in a temp folder ----
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("bk-tray-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    try {
        [void][IO.Directory]::CreateDirectory($tmp)
        $crashPath = Join-Path $tmp (LogName "30")
        [IO.File]::WriteAllText($crashPath, $Fix.Crash)
        [IO.File]::WriteAllText((Join-Path $tmp "0.743.0.7431134_20261018T140830Z_Player_77777_CrashHandler_last.log"), $Fix.Crash)
        [IO.File]::WriteAllText((Join-Path $tmp "notes.txt"), $Fix.Crash)
        $real = New-RobloxLogPort
        $names = @(& $real.List $tmp | ForEach-Object { $_.Name } | Sort-Object)
        Check "real folder: only Roblox client logs are listed (CrashHandler ones too, the finder skips those)" ($names.Count -eq 2 -and @($names | Where-Object { $_ -like "*_Player_*_last.log" }).Count -eq 2) ($names -join ",")
        # Roblox keeps its log open for writing while it runs
        $open = New-Object IO.FileStream ($crashPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            $text = & $real.Read $crashPath 8192
            Check "real folder: a log Roblox still has open can be read" (Test-StaleTrayCrash $text)
            $hit = Find-StaleTrayCrash $real $tmp ([DateTime]::Now.AddMinutes(-1)) @()
            Check "real folder: the crash log is found" ($hit -eq $crashPath) "got '$hit'"
        } finally { $open.Dispose() }
        $short = & $real.Read $crashPath 100
        Check "real folder: never reads more than asked" ($short.Length -le 100) "$($short.Length) characters"
        $hit = Find-StaleTrayCrash $real $tmp ([DateTime]::Now.AddMinutes(1)) @()
        Check "real folder: a log made before the launch isn't it" ($hit -eq "") "got '$hit'"
        $err = $null; try { $hit = Find-StaleTrayCrash $real (Join-Path $tmp "no-such-folder") ([DateTime]::Now.AddMinutes(-1)) @() } catch { $err = $_ }
        Check "real folder: a missing log folder: nothing found, nothing thrown" ($null -eq $err -and $hit -eq "") "$err"
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_ (check-tray.ps1 line $($_.InvocationInfo.ScriptLineNumber))"
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All tray checks passed." })
exit $script:fails
