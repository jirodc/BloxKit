# Checks BloxKit's UI stall detector: a watchdog notices when the UI thread doesn't answer for
# 1 second or more, notes what it was doing, and the tick logs it as ui.stall. Uses a pretend
# clock (and, once, the real watchdog thread for a second and a half).
#     powershell -ExecutionPolicy Bypass -File tools\check-ui.ps1
. (Join-Path $PSScriptRoot "..\BloxKit.ps1") -TestOnly

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}

# ---- a pretend disk for the log (only the calls the log makes) ----
$Dir = "C:\fake\logs"
function New-FakeDisk {
    $script:D = @{ Files = @{}; Calls = 0 }
    @{
        EnsureDir = { param($d) $script:D.Calls++ }; Size = { param($p) $script:D.Calls++; [long]("" + $script:D.Files[$p]).Length }
        EndsWithNewline = { param($p) $script:D.Calls++; $true }; Append = { param($p, $t) $script:D.Calls++; $script:D.Files[$p] = "" + $script:D.Files[$p] + $t }
        Move = { param($a, $b) $script:D.Calls++ }; Delete = { param($p) $script:D.Calls++ }; Exists = { param($p) $script:D.Calls++; $false }; Now = { [DateTime]"2026-10-18T12:00:00" }
    }
}
function Written { @(@($script:D.Files.Values) -join "" -split "`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }

try {
    Add-Type -TypeDefinition $BkStallSource
    # A watch on a pretend clock: Tick advances it; Beat is the UI thread, Look the watchdog.
    function New-Watch { $w = New-Object BkStallWatch; $script:now = [long]10000; $w.Clock = [Func[long]]{ $script:now }; $w }
    function Tick([long]$ms) { $script:now += $ms }
    function Run-Normal($w, [int]$beats) { for ($i = 0; $i -lt $beats; $i++) { for ($j = 0; $j -lt 3; $j++) { Tick 85; $w.Check() }; Tick 5; $w.Beat() } }   # a beat about every 260 ms, looked at 3 times in between
    function Stuck($w, [long]$ms, [string]$section = "") { if ($section) { $w.Section = $section }; $left = $ms; while ($left -gt 0) { $step = [Math]::Min(100, $left); Tick $step; $left -= $step; $w.Check() } }

    # ---- thresholds and timing ----
    $w = New-Watch
    $w.Check(); Tick 5000; $w.Check()
    Check "before the first heartbeat (BloxKit still starting) nothing counts, however long" (@($w.Take()).Count -eq 0 -and $w.Totals()[0] -eq 0)
    $w.Beat(); Run-Normal $w 40
    Check "heartbeats on time (with normal jitter), 40 of them: no stall" (@($w.Take()).Count -eq 0)
    $w.Beat(); Stuck $w 1249; $w.Beat()
    Check "a beat 999 ms late (1249 ms after the last, which includes its 250 ms interval): not a stall" (@($w.Take()).Count -eq 0)
    $w.Beat(); Stuck $w 1250; $w.Beat(); $st = @($w.Take())
    Check "a beat 1000 ms late: one stall of 1000 ms (how late it was, never more)" ($st.Count -eq 1 -and $st[0].DurationMs -eq 1000) "$($st.Count) / $($st[0].DurationMs)"
    $w.Beat(); Stuck $w 3250 "refresh"; $w.Beat(); $st = @($w.Take())
    Check "a 3-second freeze: one stall of 3000 ms, not one per second" ($st.Count -eq 1 -and $st[0].DurationMs -eq 3000) "$($st.Count) / $($st[0].DurationMs)"
    Run-Normal $w 5
    Check "after a stall, beats on time again: nothing more" (@($w.Take()).Count -eq 0)

    # ---- what the UI thread was doing ----
    $w.Section = "tick"; $w.Beat(); Stuck $w 1400 "logs"; $w.Section = "other"; $w.Beat(); $st = @($w.Take())
    Check "the section noted is the one it was stuck in (not the one it moved to after)" ($st.Count -eq 1 -and $st[0].Section -eq "logs") "$($st[0].Section)"
    $w.Beat(); $w.Section = "status"; Tick 600; $w.Check(); $w.Section = "disconnects"; Tick 900; $w.Check(); Tick 100; $w.Beat(); $st = @($w.Take())
    Check "noted when it's a second overdue: a freeze that runs on from one part into the next counts as the later one" ($st.Count -eq 1 -and $st[0].Section -eq "disconnects") "$($st[0].Section)"
    $w.Beat(); Stuck $w 1300 "refresh"; Stuck $w 700 "logs"; $w.Beat(); $st = @($w.Take())
    Check "once noted, the section stays, even if the stuck thread moves on before it answers" ($st.Count -eq 1 -and $st[0].Section -eq "refresh" -and $st[0].DurationMs -eq 1750) "$($st[0].Section) / $($st[0].DurationMs)"
    $w.Beat(); $w.Section = "refresh"; Tick 1600; $w.Beat(); $st = @($w.Take())
    Check "a stall the watchdog didn't get to look at is still counted, as 'other'" ($st.Count -eq 1 -and $st[0].Section -eq "other" -and $st[0].DurationMs -eq 1350) "$($st[0].Section) / $($st[0].DurationMs)"

    # ---- not the UI's doing ----
    $w.Beat(); Tick 90; $w.Check(); Tick 6000; $w.Check(); Tick 50; $w.Beat()
    Check "the PC asleep (the watchdog didn't run either): not a stall" (@($w.Take()).Count -eq 0)
    Run-Normal $w 3; $w.Beat(); Stuck $w 1300 "afk"; $w.Beat(); $st = @($w.Take())
    Check "...and the next real stall after waking still counts" ($st.Count -eq 1 -and $st[0].Section -eq "afk") "$($st.Count)"

    # ---- limits ----
    $w = New-Watch; $w.MaxQueued = 3; $w.Beat()
    foreach ($ms in 1500, 2500, 1200, 4000, 1100) { Stuck $w ($ms + 250) "refresh"; $w.Beat() }
    $st = @($w.Take()); $over = $w.TakeOverflow(); $tot = $w.Totals()
    Check "at most MaxQueued stalls wait between ticks; the rest are counted as overflow" ($st.Count -eq 3 -and $over -eq 2 -and $w.TakeOverflow() -eq 0) "$($st.Count) / $over"
    Check "the run's totals still count every stall: 5, longest 4000 ms, 10300 ms in all" ($tot[0] -eq 5 -and $tot[1] -eq 4000 -and $tot[2] -eq 10300) ($tot -join ",")
    Check "taking empties the list" (@($w.Take()).Count -eq 0)

    # ---- stopping, and a broken clock ----
    $w = New-Watch; $w.Beat(); Stuck $w 1500 "tray"; $w.Beat(); $w.Stop()
    Stuck $w 5000 "tray"; $w.Beat()
    $st = @($w.Take())
    Check "after Stop nothing more is counted (closing takes its time), but what was found is still handed over" ($st.Count -eq 1 -and $w.Totals()[0] -eq 1)
    $w = New-Watch; $w.Beat(); $w.Clock = [Func[long]]{ throw "clock broke" }; $err = $null
    try { $w.Beat(); $w.Check(); [void]$w.Take() } catch { $err = $_ }
    Check "a failing clock: Beat and Check never throw (the watchdog thread can't take BloxKit down)" ($null -eq $err) "$err"

    # ---- the real watchdog thread ----
    $w = New-Object BkStallWatch
    $w.Start(); $w.Beat(); Start-Sleep -Milliseconds 300; $w.Beat()
    $w.Section = "refresh"; Start-Sleep -Milliseconds 1700; $w.Section = "other"; $w.Beat()
    $st = @($w.Take()); $thr = $w.GetType().GetField("thread", [Reflection.BindingFlags]"NonPublic,Instance").GetValue($w)
    Check "real thread: a 1.7 s freeze on this thread is found, noted as refresh, about 1.45 s" ($st.Count -eq 1 -and $st[0].Section -eq "refresh" -and $st[0].DurationMs -ge 1300 -and $st[0].DurationMs -le 1700) "$($st.Count) / $($st[0].Section) / $($st[0].DurationMs)"
    Check "real thread: a background thread (never keeps BloxKit open)" ($thr.IsBackground -and $w.Running)
    $w.Stop(); Start-Sleep -Milliseconds 400
    Check "real thread: Stop ends it within a few tenths of a second" (-not $w.Running)

    # ---- from stalls to log events ----
    Check "the sections the log accepts are BloxKit's list of sections" ((($BkLogSchema["ui.stall"].Fields["section"].Substring(5) -split '\|') -join ",") -ceq ($BkStallSections -join ","))
    $w = New-Watch; $w.Beat()
    foreach ($s in "refresh", "made-up") { Stuck $w 1450 $s; $w.Beat() }
    $log = New-BkLog $Dir (New-FakeDisk)
    $ev = @(Get-BkStallEvents $w $log)
    Check "each stall becomes a ui.stall event with its duration and section (an unknown section becomes other)" ($ev.Count -eq 2 -and $ev[0].Ev -eq "ui.stall" -and $ev[0].Fields.durationMs -eq 1200 -and $ev[0].Fields.section -eq "refresh" -and $ev[1].Fields.section -eq "other") (($ev | ForEach-Object { "$($_.Fields.section)/$($_.Fields.durationMs)" }) -join ",")
    $w.MaxQueued = 1; foreach ($i in 1..3) { Stuck $w 1300 "logs"; $w.Beat() }
    $ev = @(Get-BkStallEvents $w $log)
    Check "stalls that didn't fit while waiting are counted as dropped in the log" ($ev.Count -eq 1 -and $log.Dropped -eq 2 -and $log.DropsToReport -eq 2) "$($ev.Count) dropped=$($log.Dropped)"
    $sum = Get-BkStallSummary $w
    Check "the summary: how many, the longest and the total (all of them, dropped ones too)" ($sum.Ev -eq "ui.stalls" -and $sum.Fields.count -eq 5 -and $sum.Fields.longestMs -eq 1200 -and $sum.Fields.totalMs -eq 5550) ($sum.Fields | ConvertTo-Json -Compress)
    Check "no stalls this run: no summary" ($null -eq (Get-BkStallSummary (New-Watch)))
    $bad = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Take -Value { throw "broken" } -PassThru
    $err = $null; try { $e1 = @(Get-BkStallEvents $null $log); $e2 = @(Get-BkStallEvents $bad $log); $e3 = Get-BkStallSummary $bad } catch { $err = $_ }
    Check "no watch, or a broken one: no events, nothing thrown" ($null -eq $err -and $e1.Count -eq 0 -and $e2.Count -eq 0 -and $null -eq $e3) "$err"
    $log = New-BkLog $Dir (New-FakeDisk)
    Write-BkLog $log "ui.stall" @{ durationMs = 1234; section = "refresh" }; Write-BkLog $log "ui.stalls" @{ count = 3; longestMs = 2000; totalMs = 4500 }
    Check "ui.stall and ui.stalls pass the log's schema, and only queue (no disk work)" ($log.Rejected -eq 0 -and $log.Queue.Count -eq 2 -and $script:D.Calls -eq 0)

    # ---- the app's own hooks, taken from BloxKit.ps1 by name, against stand-ins ----
    $tokens = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "..\BloxKit.ps1"), [ref]$tokens, [ref]$perr)
    $names = @("Set-BkSection", "Get-BkSection", "Start-BkStallWatch", "Stop-BkStallWatch", "Write-BkDiag", "Step-BkLog", "Invoke-AfkPassLogged", "Send-Webhook", "Test-HookUrl")
    $nodes = @(foreach ($n in $names) { $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true) })
    $missing = @($names | Where-Object { $n = $_; -not @($nodes | Where-Object { $_ -and $_.Name -eq $n }).Count })
    Check "hook check: all $($names.Count) functions are in BloxKit.ps1" ($missing.Count -eq 0) ("missing: " + ($missing -join ", "))
    $hooks = (@($nodes | Where-Object { $_ } | ForEach-Object { $_.Extent.Text }) -join "`n")
    Add-Type -AssemblyName WindowsBase
    $envUi = {
        $script:BkLog = New-BkLog $Dir (New-FakeDisk); $script:BkDiag = New-BkDiag; $script:BkStall = $null; $script:BkStallBeat = $null
        $script:BkErrors = New-BkErrorSweep; $script:BkLogClock = [Diagnostics.Stopwatch]::StartNew(); $script:AfkDiag = New-AfkDiag; $script:AfkOn = $false
        $script:State = [pscustomobject]@{ afkMode = "hidden"; afkMinutes = 5; afkActions = @("jump"); webhook = "https://discord.com/api/webhooks/1/abc" }
        $script:Locks = @(); $NoRoblox = $true; $script:ExitReason = "exit"; $script:Seen = @()
        function Say { }
        Invoke-Expression $hooks
        function Written2 { Flush-BkLog $script:BkLog; Written }
    }

    # start and stop
    $r = & { . $envUi; Start-BkStallWatch; $on = @{ Watch = $script:BkStall; Beat = $script:BkStallBeat; Running = $script:BkStall.Running; Enabled = $script:BkStallBeat.IsEnabled; Every = $script:BkStallBeat.Interval.TotalMilliseconds; Prio = "" + [System.Windows.Threading.DispatcherTimer].GetField("_priority", [Reflection.BindingFlags]"NonPublic,Instance").GetValue($script:BkStallBeat) }
             Stop-BkStallWatch; Start-Sleep -Milliseconds 300; $on.After = $script:BkStall.Running; $on.EnabledAfter = $script:BkStallBeat.IsEnabled; $on }
    Check "start: the watchdog runs and a heartbeat every 250 ms at Input priority (a stall means BloxKit couldn't react to you)" ($null -ne $r.Watch -and $r.Running -and $r.Enabled -and $r.Every -eq 250 -and $r.Prio -eq "Input") "running=$($r.Running) every=$($r.Every) prio=$($r.Prio)"
    Check "stop: the heartbeat stops and the thread ends" (-not $r.After -and -not $r.EnabledAfter)
    $r = & { . $envUi; $script:BkLog = $null; Start-BkStallWatch; @{ Watch = $script:BkStall; Beat = $script:BkStallBeat } }
    Check "logging off: no watchdog at all (nowhere to report to)" ($null -eq $r.Watch -and $null -eq $r.Beat)
    $r = & { . $envUi; $BkStallSource = "this is not C#"; function New-Object { throw "can't make it" }; $err = $null; try { Start-BkStallWatch; Stop-BkStallWatch; Set-BkSection "logs"; $sec = Get-BkSection } catch { $err = $_ }; @{ Err = $err; Watch = $script:BkStall; Sec = $sec } }
    Check "the watchdog can't be made: BloxKit starts as usual, sections do nothing, nothing thrown" ($null -eq $r.Err -and $null -eq $r.Watch -and $r.Sec -eq "other") "$($r.Err)"

    # the tick hands stalls to the log
    $r = & {
        . $envUi
        $script:BkStall = New-Watch; $script:BkStall.Beat(); Stuck $script:BkStall 1450 "logs"; $script:BkStall.Beat()
        Step-BkLog; $mid = @(Written2 | Where-Object { $_.ev -eq "ui.stall" }).Count
        Stuck $script:BkStall 2250 "refresh"; $script:BkStall.Beat()
        Step-BkLog -Final
        @{ Mid = $mid; Lines = @(Written2) }
    }
    $evs = @($r.Lines | ForEach-Object { $_.ev })
    $us = @($r.Lines | Where-Object { $_.ev -eq "ui.stall" }); $sm = @($r.Lines | Where-Object { $_.ev -eq "ui.stalls" })
    Check "the tick logs each stall once: ui.stall with its duration and section" ($r.Mid -eq 1 -and $us.Count -eq 2 -and $us[0].durationMs -eq 1200 -and $us[0].section -eq "logs" -and $us[1].section -eq "refresh" -and $us[0].lvl -eq "warn") (($us | ConvertTo-Json -Compress))
    Check "closing: the last stalls, then the summary, then app.stop last" ($sm.Count -eq 1 -and $sm[0].count -eq 2 -and $sm[0].longestMs -eq 2000 -and [array]::IndexOf($evs, "ui.stalls") -lt [array]::IndexOf($evs, "app.stop") -and $evs[-1] -eq "app.stop") ($evs -join ",")
    $r = & { . $envUi; $script:BkStall = New-Watch; $script:BkStall.Beat(); Step-BkLog -Final; @{ Lines = @(Written2) } }
    Check "closing after a run without stalls: no summary line" (@($r.Lines | Where-Object { $_.ev -like "ui.stall*" }).Count -eq 0)
    $r = & { . $envUi; $script:BkStall = New-Watch; $script:BkStall.MaxQueued = 500; $script:BkStall.Beat(); for ($i = 0; $i -lt 205; $i++) { Stuck $script:BkStall 1300 "mute"; $script:BkStall.Beat() }; Step-BkLog; @{ Lines = @(Written2); Dropped = $script:BkLog.Dropped } }
    Check "a run full of stalls: at most 200 ui.stall lines, the rest counted as dropped" (@($r.Lines | Where-Object { $_.ev -eq "ui.stall" }).Count -eq 200 -and $r.Dropped -eq 5) "dropped=$($r.Dropped)"
    $r = & { . $envUi; $script:BkStall = New-Watch; $script:BkStall.Beat(); Stuck $script:BkStall 1300 "logs"; $script:BkStall.Beat(); function Write-BkLog { throw "the log broke" }; $err = $null; try { Step-BkLog; Step-BkLog -Final } catch { $err = $_ }; @{ Err = $err; Left = @($script:BkStall.Take()).Count } }
    Check "the log failing: nothing thrown into the tick or closing, and the stalls aren't kept piling up" ($null -eq $r.Err -and $r.Left -eq 0) "$($r.Err) left=$($r.Left)"

    # sections: anti-AFK passes and the webhook mark themselves, and put back what was there
    $r = & {
        . $envUi; $script:BkStall = New-Watch; $script:BkLog = $null
        $script:AfkFocus = @{ Stuck = $false }; $script:InputPort = $null
        function Invoke-AfkPass($picks, [bool]$hidden, [IntPtr]$back) { $script:Seen += (Get-BkSection); @{ Results = @(); Back = $back; Restored = $true; Why = "" } }
        Set-BkSection "tick"; $pass = Invoke-AfkPassLogged @() $true ([IntPtr]5) "timer"; $after = Get-BkSection
        @{ During = ($script:Seen -join ","); After = $after; Back = $pass.Back }
    }
    Check "an anti-AFK pass is marked afk while it runs, then the section goes back; the pass is unchanged" ($r.During -eq "afk" -and $r.After -eq "tick" -and $r.Back -eq [IntPtr]5) "during=$($r.During) after=$($r.After)"
    $r = & {
        . $envUi; $script:BkStall = New-Watch
        function Invoke-RestMethod { [CmdletBinding()] param($Uri, $Method, $ContentType, $Body, $TimeoutSec) $script:Seen += (Get-BkSection); if ($script:HookFails) { throw "no network" } }
        Set-BkSection "logs"; $script:HookFails = $false; $ok1 = Send-Webhook "hi"; $a1 = Get-BkSection
        Set-BkSection "tick"; $script:HookFails = $true; $ok2 = Send-Webhook "hi"; $a2 = Get-BkSection
        @{ During = ($script:Seen -join ","); A1 = $a1; A2 = $a2; Ok1 = $ok1; Ok2 = $ok2 }
    }
    Check "the webhook is marked while it waits for Discord (sent or failed), then the section goes back; same results as before" ($r.During -eq "webhook,webhook" -and $r.A1 -eq "logs" -and $r.A2 -eq "tick" -and $r.Ok1 -eq $true -and $r.Ok2 -eq $false) "during=$($r.During) after=$($r.A1)/$($r.A2) ok=$($r.Ok1)/$($r.Ok2)"

    # where the hooks sit in the app
    $tickNode = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.Extent.Text -like '$Tick.Add_Tick*' }, $true)
    if (-not $tickNode) { $tickNode = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Extent.Text -like '$Tick.Add_Tick*' }, $true) }
    $tickText = "" + $tickNode.Extent.Text
    $secs = @([regex]::Matches($tickText, 'Set-BkSection "([a-z]+)"') | ForEach-Object { $_.Groups[1].Value })
    $want = @("tick", "mascot", "update", "refresh", "rejoin", "status", "disconnects", "logs", "schedule", "mute", "session", "efficiency", "tray", "graphics", "perf", "afk", "log", "other")
    $lack = @($want | Where-Object { $secs -notcontains $_ })
    Check "the tick marks each of its parts (window refresh, logs, status, disconnects, anti-AFK, the log's own write...)" ($lack.Count -eq 0) ("unmarked: " + ($lack -join ","))
    Check "the tick ends by putting the section back to other" ($secs.Count -gt 0 -and $secs[-1] -eq "other") ($secs -join ",")
    Check "every section the code sets is one the log accepts" (@([regex]::Matches(($ast.Extent.Text), 'Set-BkSection "([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $BkStallSections -cnotcontains $_ }).Count -eq 0)
    $closing = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Extent.Text -like '$win.Add_Closing*' }, $true).Extent.Text
    $iStop = $closing.IndexOf("Stop-BkStallWatch"); $iSave = $closing.IndexOf("Save-Settings; Save-Session"); $iCancel = $closing.IndexOf('$e.Cancel = $true')
    Check "closing stops the watchdog after a cancelled close can't happen any more, and before the slow saves" ($iStop -gt $iCancel -and $iStop -lt $iSave -and $iCancel -gt 0) "stop=$iStop cancel=$iCancel save=$iSave"
    $all = $ast.Extent.Text
    Check "the watchdog starts once, after the 1-second tick starts and before the app runs" (([regex]::Matches($all, '(?m)^Start-BkStallWatch')).Count -eq 1 -and $all.IndexOf("`nStart-BkStallWatch") -gt $all.IndexOf("`n`$Tick.Start()") -and $all.IndexOf("`nStart-BkStallWatch") -lt $all.IndexOf("`n`$app.Run()"))
    Check "Test anti-AFK is marked test while it runs" ($all -match '"test"\s*\{\s*Set-BkSection "test"; Test-HiddenJump \$tg\.W; Set-BkSection "other" \}')
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_ (check-ui.ps1 line $($_.InvocationInfo.ScriptLineNumber))"
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All UI stall checks passed." })
exit $script:fails
