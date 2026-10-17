# Checks Roblox Manager's group schedule: timers, moving on to the next group, pause/stop,
# retries, and coming back after a restart. Uses a fake clock, so 2 hours take no time.
#     powershell -ExecutionPolicy Bypass -File tools\check-schedule.ps1
. (Join-Path $PSScriptRoot "..\RobloxManager.ps1") -TestOnly

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}

# Group A: Main + Alt1-3, Group B: Main + Alt4-6 (the example from the plan)
$S = New-Defaults
foreach ($n in "Main","Alt1","Alt2","Alt3","Alt4","Alt5","Alt6") { $a = New-Account $n "P-$n"; $a.isMain = ($n -eq "Main"); $S.accounts = @($S.accounts) + $a }
$GA = (New-Group $S "Group A" @("Main","Alt1","Alt2","Alt3")).Group
$GB = (New-Group $S "Group B" @("Main","Alt4","Alt5","Alt6")).Group
function New-TestPlan { $p = New-PlanDefaults; $p.steps = @([pscustomobject]@{ groupId = $GA.id; minutes = 60 }, [pscustomobject]@{ groupId = $GB.id; minutes = 60 }); $p }

# A tiny world: which accounts have a Roblox window, which failed to load.
$W = @{ Open = New-Object System.Collections.ArrayList; Failed = New-Object System.Collections.ArrayList; Busy = $false }
function Facts { @{ Open = @($W.Open); Failed = @($W.Failed); Busy = $W.Busy } }
$script:opened = @(); $script:closed = @(); $script:dupes = @()
function Apply($acts) {
    foreach ($x in @($acts)) {
        if ($x.Do -eq "open") {
            foreach ($n in $x.Nicks) { if ($W.Open -contains $n) { $script:dupes += $n }; [void]$W.Failed.Remove($n) }
            $script:opened += @($x.Nicks); $W.Busy = $true   # the app's queue is now working on them
        }
        if ($x.Do -eq "close") { foreach ($n in $x.Nicks) { [void]$W.Open.Remove($n) }; $script:closed += @($x.Nicks) }
    }
}
function Ev($run, $plan, [string]$e, [double]$t, [bool]$closeOnStop = $false) { $a = Invoke-PlanEvent $run $plan $S.groups $e $t (Facts) $closeOnStop; Apply $a; return $a }
function Load-All([string[]]$nicks) { foreach ($n in $nicks) { if ($W.Open -notcontains $n) { [void]$W.Open.Add($n) } }; $W.Busy = $false }   # loaded: the queue is done
function Fail([string]$n) { [void]$W.Failed.Add($n); $W.Busy = $false }   # didn't load: the queue gave up on it
function Reset-World { $W.Open.Clear(); $W.Failed.Clear(); $W.Busy = $false; $script:opened = @(); $script:closed = @(); $script:dupes = @() }
$sorted = { param($x) (@($x) | Sort-Object) -join "," }

try {
    # ---- Group A for an hour, then Group B for an hour ----
    $P = New-TestPlan; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null
    Check "start opens everyone in Group A" ($R.State -eq "launching" -and (& $sorted $script:opened) -eq "Alt1,Alt2,Alt3,Main" -and $R.GroupName -eq "Group A")
    Ev $R $P "tick" 10 | Out-Null
    Check "the timer waits until they're open" ($R.State -eq "launching")
    Load-All @("Main","Alt1","Alt2","Alt3")
    Ev $R $P "tick" 30 | Out-Null
    Check "when all are open, the timer starts" ($R.State -eq "running" -and [int](Get-PlanElapsed $R 30) -eq 0)
    Ev $R $P "tick" 1830 | Out-Null
    Check "half way: 30 minutes left" ($R.State -eq "running" -and [int]((Get-PlanView $R $P $S.groups 1830).RemainingSec) -eq 1800)
    $script:opened = @()
    Ev $R $P "tick" 3631 | Out-Null
    Check "after an hour: only Alt1-3 close (Main is in Group B too)" ((& $sorted $script:closed) -eq "Alt1,Alt2,Alt3")
    Check "and only Alt4-6 open (Main stays open, not opened twice)" ((& $sorted $script:opened) -eq "Alt4,Alt5,Alt6" -and $script:dupes.Count -eq 0 -and $R.GroupName -eq "Group B")
    $before = $script:opened.Count
    Ev $R $P "tick" 3632 | Out-Null
    Check "a second tick doesn't open anything again" ($script:opened.Count -eq $before)
    Load-All @("Alt4","Alt5","Alt6")
    Ev $R $P "tick" 3700 | Out-Null
    Check "Group B's timer starts" ($R.State -eq "running" -and $R.GroupName -eq "Group B")
    $script:closed = @()
    Ev $R $P "tick" 7301 | Out-Null
    Check "after Group B's hour the schedule is done and closes Group B" ($R.State -eq "completed" -and (& $sorted $script:closed) -eq "Alt4,Alt5,Alt6,Main")
    Check "no account was ever opened twice" ($script:dupes.Count -eq 0)
    Check "accounts and groups are untouched" (@($S.accounts).Count -eq 7 -and ($GA.nicks -join ",") -eq "Main,Alt1,Alt2,Alt3" -and ($GB.nicks -join ",") -eq "Main,Alt4,Alt5,Alt6")
    Ev $R $P "tick" 9000 | Out-Null
    Check "once done, nothing more happens" ($R.State -eq "completed")

    # ---- pause, resume, stop ----
    Reset-World; $P = New-TestPlan; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null
    Check "pause isn't possible while accounts are opening" (-not (Test-PlanCan $R "pause"))
    Load-All @("Main","Alt1","Alt2","Alt3"); Ev $R $P "tick" 0 | Out-Null
    Ev $R $P "pause" 1000 | Out-Null
    Check "pause keeps the time so far" ($R.State -eq "paused" -and [int](Get-PlanElapsed $R 5000) -eq 1000)
    Ev $R $P "pause" 1500 | Out-Null
    Check "pausing twice changes nothing" ($R.State -eq "paused" -and [int](Get-PlanElapsed $R 5000) -eq 1000)
    Ev $R $P "resume" 2000 | Out-Null
    Ev $R $P "tick" 4500 | Out-Null
    Check "after resuming, the paused time doesn't count" ($R.State -eq "running" -and [int](Get-PlanElapsed $R 4500) -eq 3500)
    Ev $R $P "tick" 4601 | Out-Null
    Check "the hour ends an hour of running time later" ($R.GroupName -eq "Group B")
    $script:closed = @()
    Ev $R $P "stop" 4700 $false | Out-Null
    Check "stop without closing leaves windows open" ($R.State -eq "stopped" -and $script:closed.Count -eq 0)
    Ev $R $P "stop" 4800 $true | Out-Null
    Check "stopping twice changes nothing" ($R.State -eq "stopped" -and $script:closed.Count -eq 0)

    Reset-World; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null; Load-All @("Main","Alt1","Alt2","Alt3"); Ev $R $P "tick" 0 | Out-Null
    Ev $R $P "stop" 100 $true | Out-Null
    Check "stop and close: closes the schedule's windows" ($R.State -eq "stopped" -and (& $sorted $script:closed) -eq "Alt1,Alt2,Alt3,Main")

    Reset-World; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null; Load-All @("Main","Alt1")
    $acts = @(Ev $R $P "stop" 30 $false)
    $cancel = @($acts | Where-Object { $_.Do -eq "cancel" }) | Select-Object -First 1
    Check "stop while opening: stops opening the ones that aren't open yet" ($R.State -eq "stopped" -and $cancel -and (& $sorted $cancel.Nicks) -eq "Alt2,Alt3")

    # ---- options: leave open, wait, break between groups, repeat, total limit ----
    Reset-World; $P = New-TestPlan; $P.whenTimeUp = "keep"; $P.then = "wait"; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null; Load-All @("Main","Alt1","Alt2","Alt3"); Ev $R $P "tick" 0 | Out-Null
    Ev $R $P "tick" 3601 | Out-Null
    Check "'leave open' + 'wait': nothing closes, it waits for Next" ($R.State -eq "waiting" -and $script:closed.Count -eq 0)
    Ev $R $P "next" 4000 | Out-Null
    Check "Next starts Group B" ($R.State -eq "launching" -and $R.GroupName -eq "Group B")

    Reset-World; $P = New-TestPlan; $P.cooldownMin = 5; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null; Load-All @("Main","Alt1","Alt2","Alt3"); Ev $R $P "tick" 0 | Out-Null
    Ev $R $P "tick" 3601 | Out-Null
    Check "a 5 minute break after Group A" ($R.State -eq "cooldown")
    Ev $R $P "tick" 3800 | Out-Null
    Check "still in the break after 3 minutes" ($R.State -eq "cooldown")
    Ev $R $P "tick" 3902 | Out-Null
    Check "Group B starts after the break" ($R.State -eq "launching" -and $R.GroupName -eq "Group B")

    Reset-World; $P = New-TestPlan; $P.loop = $true; $P.maxTotalMin = 150; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null; Load-All @("Main","Alt1","Alt2","Alt3"); Ev $R $P "tick" 0 | Out-Null
    Ev $R $P "tick" 3601 | Out-Null; Load-All @("Alt4","Alt5","Alt6"); Ev $R $P "tick" 3601 | Out-Null
    Ev $R $P "tick" 7202 | Out-Null
    Check "'repeat': after Group B comes Group A again" ($R.GroupName -eq "Group A" -and $R.Cycle -eq 2)
    Load-All @("Alt1","Alt2","Alt3"); Ev $R $P "tick" 7202 | Out-Null
    Ev $R $P "tick" 9003 | Out-Null
    Check "the total time limit (2.5 h of running) ends it" ($R.State -eq "completed" -and $R.Reason -match "limit")

    # ---- an account that doesn't load ----
    Reset-World; $P = New-TestPlan; $P.retries = 1; $P.onFailure = "skip"; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null
    Load-All @("Main","Alt1","Alt3"); Fail "Alt2"; $script:opened = @()
    Ev $R $P "tick" 90 | Out-Null
    Check "a failed account is tried again (once)" ((& $sorted $script:opened) -eq "Alt2" -and $R.State -eq "launching")
    Fail "Alt2"; $script:opened = @()
    Ev $R $P "tick" 180 | Out-Null
    Check "after the retries it's skipped and the timer starts without it" ($script:opened.Count -eq 0 -and $R.State -eq "running" -and @($R.Skipped) -contains "Alt2")

    Reset-World; $P = New-TestPlan; $P.retries = 0; $P.onFailure = "stop"; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null
    Load-All @("Main","Alt1","Alt3"); Fail "Alt2"
    Ev $R $P "tick" 90 | Out-Null
    Check "'stop' on failure stops the schedule and says why" ($R.State -eq "stopped" -and $R.Reason -match "Alt2")

    # The main doesn't load: the app drops the alts that were to follow it (they never get a status).
    Reset-World; $P = New-TestPlan; $P.retries = 1; $P.onFailure = "skip"; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null
    Fail "Main"; $W.Busy = $false; $script:opened = @()
    Ev $R $P "tick" 100 | Out-Null
    Check "main didn't load and the queue gave up on the rest: they're tried again too, not waited for" ((& $sorted $script:opened) -eq "Alt1,Alt2,Alt3,Main")
    Fail "Main"; $script:opened = @()
    Ev $R $P "tick" 200 | Out-Null
    Check "...and after the retries the schedule doesn't hang in 'opening' forever" ($R.State -ne "launching") $R.State

    Reset-World; $P = New-TestPlan; $R = New-PlanRun
    $W.Busy = $true
    Ev $R $P "start" 0 | Out-Null; Load-All @("Main","Alt1","Alt2","Alt3"); $W.Busy = $true   # still opening others
    Ev $R $P "tick" 10 | Out-Null
    Check "the timer doesn't start while the app is still opening accounts" ($R.State -eq "launching")

    # ---- what each group card says about the schedule ----
    Reset-World; $P = New-TestPlan; $R = New-PlanRun
    Check "no schedule running: nothing on the cards" ((Get-GroupScheduleTag $GA $R $P $S.groups 0) -eq "")
    Ev $R $P "start" 0 | Out-Null
    Check "opening: the current group says so; the next one says 'next'" ((Get-GroupScheduleTag $GA $R $P $S.groups 0) -eq "Schedule: opening" -and (Get-GroupScheduleTag $GB $R $P $S.groups 0) -eq "Schedule: next")
    Load-All @("Main","Alt1","Alt2","Alt3"); Ev $R $P "tick" 0 | Out-Null
    Check "running: time left on the current group" ((Get-GroupScheduleTag $GA $R $P $S.groups 600) -eq "Schedule: running, 50:00 left")
    Ev $R $P "pause" 600 | Out-Null
    Check "paused" ((Get-GroupScheduleTag $GA $R $P $S.groups 900) -eq "Schedule: paused, 50:00 left")

    # ---- checks before starting ----
    $info = @{}; foreach ($a in $S.accounts) { $info[$a.nick.ToLower()] = @{ Running = $false; Ready = $true; Groups = @() } }
    $v = Test-Plan (New-TestPlan) $S $info "game"
    Check "a good plan can start" ($v.Errors.Count -eq 0) ($v.Errors -join " / ")
    Check "no link: can't start" ((Test-Plan (New-TestPlan) $S $info "empty").Errors.Count -gt 0)
    $p2 = New-PlanDefaults
    Check "no steps: can't start" ((Test-Plan $p2 $S $info "game").Errors.Count -gt 0)
    $p2.steps = @([pscustomobject]@{ groupId = "11111111-1111-1111-1111-111111111111"; minutes = 60 })
    Check "a deleted group: can't start" (((Test-Plan $p2 $S $info "game").Errors -join " ") -match "deleted")
    $S.accounts[2].needsLogin = $true
    Check "an account that needs to sign in: can't start, and it says which" (((Test-Plan (New-TestPlan) $S $info "game").Errors -join " ") -match "Alt2")
    $S.accounts[2].needsLogin = $false

    # ---- saving, and coming back after the app closed ----
    Reset-World; $P = New-TestPlan; $R = New-PlanRun
    Ev $R $P "start" 0 | Out-Null; Load-All @("Main","Alt1","Alt2","Alt3"); Ev $R $P "tick" 0 | Out-Null
    $saved = ConvertTo-SavedRun $R 1200
    $back = ConvertFrom-SavedRun ($saved | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
    Check "after a restart a running schedule comes back paused, with its time" ($back.State -eq "paused" -and [int](Get-PlanElapsed $back 99999) -eq 1200 -and $back.GroupName -eq "Group A")
    Ev $back $P "resume" 50 | Out-Null
    Check "resume after a restart goes on from there" ($back.State -eq "running" -and [int](Get-PlanElapsed $back 110) -eq 1260)
    $short = New-PlanDefaults; $short.steps = @([pscustomobject]@{ groupId = $GB.id; minutes = 60 })   # the step it was on is gone
    $gone = ConvertFrom-SavedRun ($saved | ConvertTo-Json -Depth 5 | ConvertFrom-Json); $gone.Step = 3
    Check "a paused run whose step was removed can't be resumed; it says why" (-not (Test-PlanCan $gone "resume" $short) -and (Get-PlanProblem $gone $short $S.groups) -match "changed")
    $acts = @(Invoke-PlanEvent $gone $short $S.groups "tick" 10 (Facts))
    Check "...and the next tick stops it safely" ($gone.State -eq "stopped" -and $gone.Reason -match "changed")
    $f = Join-Path ([IO.Path]::GetTempPath()) ("rml-plan-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".json")
    $S.plan = New-TestPlan; $S.plan.cooldownMin = 3; $S.plan.then = "wait"
    Write-SettingsFile $S $f | Out-Null
    $L = (Read-SettingsFile $f).State
    Remove-Item $f, "$f.bak" -Force -ErrorAction SilentlyContinue
    Check "the schedule's steps and options are saved" (@($L.plan.steps).Count -eq 2 -and $L.plan.steps[0].groupId -eq $GA.id -and $L.plan.steps[1].minutes -eq 60 -and $L.plan.cooldownMin -eq 3 -and $L.plan.then -eq "wait")
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_  (line $($_.InvocationInfo.ScriptLineNumber))"
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All schedule checks passed." })
exit $script:fails
