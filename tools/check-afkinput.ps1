# Checks that anti-AFK only presses keys or clicks when the intended Roblox window really has
# the focus (BkInput in BloxKit.ps1), using a pretend Windows: no real windows, keys or mouse.
#     powershell -ExecutionPolicy Bypass -File tools\check-afkinput.ps1
. (Join-Path $PSScriptRoot "..\BloxKit.ps1") -TestOnly
Add-Type -TypeDefinition $BkInputSource

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}

# ---- the pretend Windows ----
# $S.Fg is the foreground window. Every key and button event is recorded with the window that
# was in front at that moment, so "input only reached the intended window" can be checked.
# USER is your app (Notepad), A and B are Roblox screens, TASKBAR is Windows' taskbar, BKTRAY is
# BloxKit's own hidden tray-icon window and BKMAIN its main window (both in BloxKit's process, OWNPID).
$USER = 100; $A = 201; $B = 202; $THIEF = 300; $TASKBAR = 400; $BKTRAY = 500; $BKMAIN = 600; $GONE = 999; $OWNPID = 20
function New-World {
    $script:S = @{
        Fg = $USER; Alive = @($USER, $A, $B, $THIEF, $TASKBAR, $BKTRAY, $BKMAIN); Grant = $true; GrantTo = $null
        Reads = 0; StealOnRead = 0; StealOnWait = $false; GoneOnWait = 0; ThrowActivate = $false; ThrowForeground = $false; ThrowOnHold = 0
        Activations = 0; Waits = 0; Log = New-Object System.Collections.ArrayList
        Spot = @(500, 400); PidAt = 7; Cursor = @(10, 20); CursorNow = @(10, 20)
        Hidden = @($BKTRAY)   # not visible
        Class = @{ $USER = "Notepad"; $A = "WINDOWSCLIENT"; $B = "WINDOWSCLIENT"; $THIEF = "Chrome_WidgetWin_1"; $TASKBAR = "Shell_TrayWnd"; $BKTRAY = "WindowsForms10.Window.0.app.0.1"; $BKMAIN = "HwndWrapper[BloxKit]" }
        Pid = @{ $USER = 11; $A = 7; $B = 8; $THIEF = 12; $TASKBAR = 13; $BKTRAY = $OWNPID; $BKMAIN = $OWNPID }
    }
    $p = New-Object BkInputPort
    $p.IsWindow = [Func[IntPtr, bool]]{ param($h) $script:S.Alive -contains $h.ToInt64() }
    $p.Foreground = [Func[IntPtr]]{
        if ($script:S.ThrowForeground) { throw "GetForegroundWindow failed" }
        $script:S.Reads++
        if ($script:S.StealOnRead -and $script:S.Reads -ge $script:S.StealOnRead) { $script:S.Fg = $THIEF }   # another app takes over
        [IntPtr]$script:S.Fg
    }
    $p.Activate = [Action[IntPtr]]{
        param($h)
        $script:S.Activations++
        if ($script:S.ThrowActivate) { throw "SetForegroundWindow failed" }
        if ($script:S.Grant) { $script:S.Fg = $(if ($script:S.GrantTo) { $script:S.GrantTo } else { $h.ToInt64() }) }
    }
    $p.Wait = [Action[int]]{
        param($ms)
        $script:S.Waits++
        if ($script:S.ThrowOnHold -and $ms -eq $script:S.ThrowOnHold) { throw "interrupted while holding the key" }
        if ($script:S.StealOnWait) { $script:S.Fg = $THIEF }
        if ($script:S.GoneOnWait) { $script:S.Alive = @($script:S.Alive | Where-Object { $_ -ne $script:S.GoneOnWait }) }
    }
    $p.Key = [Action[int, bool]]{ param($vk, $down) [void]$script:S.Log.Add([pscustomobject]@{ Kind = "key"; Vk = $vk; Down = $down; Fg = $script:S.Fg }) }
    $p.Button = [Action[bool]]{ param($down) [void]$script:S.Log.Add([pscustomobject]@{ Kind = "button"; Vk = 0; Down = $down; Fg = $script:S.Fg }) }
    $p.SpotOf = [Func[IntPtr, double, double, int[]]]{ param($h, $fx, $fy) if ($null -eq $script:S.Spot) { return $null }; [int[]]$script:S.Spot }
    $p.Cursor = [Func[int[]]]{ [int[]]$script:S.Cursor }
    $p.MoveCursor = [Action[int, int]]{ param($x, $y) $script:S.CursorNow = @($x, $y); [void]$script:S.Log.Add([pscustomobject]@{ Kind = "move"; Vk = 0; Down = $false; Fg = $script:S.Fg }) }
    $p.PidAt = [Func[int, int, int]]{ param($x, $y) $script:S.PidAt }
    $p.PidOf = [Func[IntPtr, int]]{ param($h) [int]$script:S.Pid[[int]$h.ToInt64()] }   # the maps are keyed by [int]
    $p.IsVisible = [Func[IntPtr, bool]]{ param($h) ($script:S.Alive -contains $h.ToInt64()) -and ($script:S.Hidden -notcontains $h.ToInt64()) }
    $p.ClassOf = [Func[IntPtr, string]]{ param($h) "" + $script:S.Class[[int]$h.ToInt64()] }
    return $p
}
function Ctx { New-AfkFocusContext $OWNPID ([IntPtr]$BKMAIN) @($A, $B) }   # BloxKit's process and main window; the Roblox screens
function Presses($kind = "") { @($script:S.Log | Where-Object { $_.Down -and $_.Kind -ne "move" -and (-not $kind -or $_.Kind -eq $kind) }) }
function Releases { @($script:S.Log | Where-Object { -not $_.Down -and $_.Kind -ne "move" }) }
function Strays([long]$target) { @(Presses | Where-Object { $_.Fg -ne $target }) }   # a press that reached any other window

try {
    # ---- keys ----
    $p = New-World
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "focus granted: the key is sent" ("$r" -eq "Sent") "got $r"
    Check "focus granted: one press and one release, both while the Roblox window is in front" (@(Presses).Count -eq 1 -and @(Releases).Count -eq 1 -and @(Strays $A).Count -eq 0 -and @(Releases)[0].Fg -eq $A)
    Check "focus granted: the right key (Space)" (@(Presses)[0].Vk -eq 0x20)

    $p = New-World; $S.Fg = $A
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "already in front: sent without asking Windows to switch" ("$r" -eq "Sent" -and $S.Activations -eq 0) "got $r, $($S.Activations) activations"

    $p = New-World; $S.Grant = $false
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "Windows refuses the focus: nothing is sent" ("$r" -eq "NoFocus" -and @(Presses).Count -eq 0 -and @(Releases).Count -eq 0) "got $r, $(@(Presses).Count) presses"
    Check "Windows refuses the focus: it asks a bounded number of times ($([BkInput]::FocusTries))" ($S.Activations -eq [BkInput]::FocusTries) "asked $($S.Activations) times"

    $p = New-World; $S.StealOnRead = 3   # read 1: the user's app; read 2: Roblox (focus granted); read 3, right before the press: another app
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "another app takes the focus between activation and the press: nothing is sent" ("$r" -eq "FocusLost" -and @(Presses).Count -eq 0) "got $r, $(@(Presses).Count) presses"

    $p = New-World; $S.StealOnWait = $true   # every time we wait, another app jumps in front
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "another app keeps taking the focus back: nothing is sent" ("$r" -eq "NoFocus" -and @(Presses).Count -eq 0) "got $r"

    $p = New-World; $S.Grant = $false; $S.GoneOnWait = $A
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "the window closes during a retry: nothing is sent, and it stops asking" ("$r" -eq "NoWindow" -and @(Presses).Count -eq 0 -and $S.Activations -eq 1) "got $r, $($S.Activations) activations"

    $p = New-World
    $r = [BkInput]::Key($p, [IntPtr]$GONE, 0x20, 100)
    Check "a handle that's no longer valid: nothing is sent, Windows isn't asked" ("$r" -eq "NoWindow" -and @(Presses).Count -eq 0 -and $S.Activations -eq 0) "got $r"
    $r = [BkInput]::Key($p, [IntPtr]::Zero, 0x20, 100)
    Check "an empty handle: nothing is sent" ("$r" -eq "NoWindow" -and @(Presses).Count -eq 0) "got $r"

    $p = New-World; $S.ThrowActivate = $true
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "asking for the focus throws: nothing is sent, no crash" ("$r" -eq "NoFocus" -and @(Presses).Count -eq 0) "got $r"

    $p = New-World; $S.ThrowForeground = $true
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "reading the foreground window throws: nothing is sent, no crash" ("$r" -eq "Failed" -and @(Presses).Count -eq 0) "got $r"

    $p = New-World; $S.ThrowOnHold = 100
    $r = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100)
    Check "an error while the key is held: the key is still let go (never stuck)" ("$r" -eq "Failed" -and @(Presses).Count -eq 1 -and @(Releases).Count -eq 1) "got $r, $(@(Presses).Count) presses, $(@(Releases).Count) releases"

    # ---- several Roblox windows ----
    $p = New-World; $S.GrantTo = $A   # Windows brings the OTHER Roblox window to the front
    $r = [BkInput]::Key($p, [IntPtr]$B, 0x20, 100)
    Check "two Roblox windows, the other one comes to the front: nothing is sent to either" ("$r" -eq "NoFocus" -and @(Presses).Count -eq 0) "got $r"
    $p = New-World
    $ra = [BkInput]::Key($p, [IntPtr]$A, 0x20, 100); $rb = [BkInput]::Key($p, [IntPtr]$B, 0x20, 100)
    $toA = @(Presses | Where-Object { $_.Fg -eq $A }).Count; $toB = @(Presses | Where-Object { $_.Fg -eq $B }).Count
    Check "two Roblox windows in a row: each gets exactly its own press" ("$ra" -eq "Sent" -and "$rb" -eq "Sent" -and $toA -eq 1 -and $toB -eq 1 -and @(Presses).Count -eq 2)

    # ---- getting the focus back to the user's window afterwards ----
    $p = New-World; $S.Fg = $A
    Check "the user's window gets the focus back (checked)" ([BkInput]::Acquire($p, [IntPtr]$USER) -and $S.Fg -eq $USER)
    $p = New-World; $S.Fg = $A; $S.Grant = $false
    $ok = [BkInput]::Acquire($p, [IntPtr]$USER)
    Check "the user's window can't get the focus back: reported, bounded, nothing pressed" (-not $ok -and $S.Activations -eq [BkInput]::FocusTries -and $S.Log.Count -eq 0)

    # ---- clicks ----
    $p = New-World
    $r = [BkInput]::Click($p, [IntPtr]$A, 0.5, 0.5)
    Check "click, focus granted: clicked while the Roblox window is in front" ("$r" -eq "Sent" -and @(Presses "button").Count -eq 1 -and @(Strays $A).Count -eq 0 -and @(Releases).Count -eq 1) "got $r"
    Check "click: the pointer goes back where it was" ($S.CursorNow[0] -eq 10 -and $S.CursorNow[1] -eq 20)

    $p = New-World; $S.Grant = $false
    $r = [BkInput]::Click($p, [IntPtr]$A, 0.5, 0.5)
    Check "click, Windows refuses the focus: no click, the pointer isn't even moved" ("$r" -eq "NoFocus" -and @(Presses).Count -eq 0 -and @($S.Log | Where-Object { $_.Kind -eq "move" }).Count -eq 0) "got $r"

    $p = New-World; $S.PidAt = 55   # another app's window is on top of the click spot
    $r = [BkInput]::Click($p, [IntPtr]$A, 0.5, 0.5)
    Check "click spot covered by another window: no click, pointer put back" ("$r" -eq "Covered" -and @(Presses).Count -eq 0 -and $S.CursorNow[0] -eq 10) "got $r"

    $p = New-World; $S.StealOnRead = 3
    $r = [BkInput]::Click($p, [IntPtr]$A, 0.5, 0.5)
    Check "click, another app takes the focus after the pointer moved: no click, pointer put back" ("$r" -eq "FocusLost" -and @(Presses).Count -eq 0 -and $S.CursorNow[0] -eq 10) "got $r"

    $p = New-World; $S.Spot = $null
    $r = [BkInput]::Click($p, [IntPtr]$A, 0.5, 0.5)
    Check "click, the window has no picture any more: no click" ("$r" -eq "NoWindow" -and @(Presses).Count -eq 0) "got $r"

    # ---- the anti-AFK actions (BloxKit.ps1's Invoke-AfkInput) ----
    $p = New-World
    $r = Invoke-AfkInput $p ([IntPtr]$A) "walk"
    Check "step: W then S, both into the Roblox window" ("$r" -eq "Sent" -and (@(Presses | ForEach-Object { $_.Vk }) -join ",") -eq "87,83" -and @(Strays $A).Count -eq 0) "got $r"
    $p = New-World
    $r = Invoke-AfkInput $p ([IntPtr]$A) "zoom"
    Check "zoom: I then O" ("$r" -eq "Sent" -and (@(Presses | ForEach-Object { $_.Vk }) -join ",") -eq "73,79")
    $p = New-World
    $r = Invoke-AfkInput $p ([IntPtr]$A) "jump"
    Check "jump: Space" ("$r" -eq "Sent" -and (@(Presses | ForEach-Object { $_.Vk }) -join ",") -eq "32")
    $p = New-World; $S.Grant = $false
    $r = Invoke-AfkInput $p ([IntPtr]$A) "walk"
    Check "step, no focus: neither W nor S is sent, S isn't even tried" ("$r" -eq "NoFocus" -and @(Presses).Count -eq 0 -and $S.Activations -eq [BkInput]::FocusTries) "got $r, $($S.Activations) activations"
    $p = New-World
    $r = Invoke-AfkInput $p ([IntPtr]$A) "click"
    Check "click action: one click" ("$r" -eq "Sent" -and @(Presses "button").Count -eq 1)
    foreach ($k in [Enum]::GetNames([BkSent])) {
        Check "skip reason has words: $k" ([bool](Get-AfkSkipText $k) -and [bool](Get-AfkSkipText $k -Short))
    }

    # ---- where the keyboard goes back after a round (Get-AfkReturnTarget) ----
    $p = New-World
    Check "return target: Notepad in front is chosen" ((Get-AfkReturnTarget $p ([IntPtr]$USER) ([IntPtr]::Zero) (Ctx)) -eq [IntPtr]$USER)
    Check "return target: the taskbar in front (a tray click) falls back to the remembered Notepad" ((Get-AfkReturnTarget $p ([IntPtr]$TASKBAR) ([IntPtr]$USER) (Ctx)) -eq [IntPtr]$USER)
    Check "return target: BloxKit's hidden tray window in front falls back to the remembered Notepad" ((Get-AfkReturnTarget $p ([IntPtr]$BKTRAY) ([IntPtr]$USER) (Ctx)) -eq [IntPtr]$USER)
    $S.Alive += 700; $S.Class[700] = "WindowsForms10.Window.808.app.0.1"; $S.Pid[700] = $OWNPID   # BloxKit's tray menu, still showing
    Check "return target: BloxKit's visible tray menu (or a dialog) falls back to the remembered Notepad" ((Get-AfkReturnTarget $p ([IntPtr]700) ([IntPtr]$USER) (Ctx)) -eq [IntPtr]$USER)
    Check "return target: BloxKit's main window can be chosen"((Get-AfkReturnTarget $p ([IntPtr]$BKMAIN) ([IntPtr]$USER) (Ctx)) -eq [IntPtr]$BKMAIN)
    Check "return target: a Roblox screen in front is never chosen (falls back to Notepad)" ((Get-AfkReturnTarget $p ([IntPtr]$A) ([IntPtr]$USER) (Ctx)) -eq [IntPtr]$USER)
    Check "return target: a remembered Roblox screen is never chosen" ((Get-AfkReturnTarget $p ([IntPtr]$TASKBAR) ([IntPtr]$B) (Ctx)) -eq [IntPtr]::Zero)
    $S.Class[$USER + 1] = "WINDOWSCLIENT"; $S.Pid[$USER + 1] = 7; $S.Alive += ($USER + 1)   # another window of Roblox client A (not a screen)
    Check "return target: another window of a Roblox client is never chosen" ((Get-AfkReturnTarget $p ([IntPtr]($USER + 1)) ([IntPtr]::Zero) (Ctx)) -eq [IntPtr]::Zero)
    foreach ($cls in "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland") {
        $p = New-World; $S.Class[$TASKBAR] = $cls
        Check "return target: taskbar/tray class $cls is never chosen" ((Get-AfkReturnTarget $p ([IntPtr]$TASKBAR) ([IntPtr]::Zero) (Ctx)) -eq [IntPtr]::Zero)
    }
    $p = New-World; $S.Alive = @($S.Alive | Where-Object { $_ -ne $USER })
    Check "return target: a remembered window that closed is refused" ((Get-AfkReturnTarget $p ([IntPtr]$TASKBAR) ([IntPtr]$USER) (Ctx)) -eq [IntPtr]::Zero)
    $p = New-World; $S.Hidden += $USER
    Check "return target: a remembered window that's no longer visible is refused" ((Get-AfkReturnTarget $p ([IntPtr]$TASKBAR) ([IntPtr]$USER) (Ctx)) -eq [IntPtr]::Zero)
    $p = New-World
    Check "return target: BloxKit's hidden tray window is never chosen, even when remembered" ((Get-AfkReturnTarget $p ([IntPtr]$TASKBAR) ([IntPtr]$BKTRAY) (Ctx)) -eq [IntPtr]::Zero)

    # ---- giving the keyboard back after a round (Restore-AfkFocus) ----
    # A round just ended with Roblox screen A in front; the keyboard should go back to Notepad.
    $p = New-World; $S.Fg = $A; $f = New-AfkFocus
    $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
    Check "hand-back works: reported as restored, Notepad really in front, not stuck" ($r.Restored -and $r.Why -eq "" -and $S.Fg -eq $USER -and -not $f.Stuck) "restored=$($r.Restored) why=$($r.Why) fg=$($S.Fg)"
    Check "hand-back presses nothing" ($S.Log.Count -eq 0)
    $p = New-World; $S.Fg = $A; $S.Grant = $false; $f = New-AfkFocus
    $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
    Check "hand-back refused by Windows: reported (not restored), Roblox still in front, stuck" (-not $r.Restored -and $r.Why -eq "refused" -and $S.Fg -eq $A -and $f.Stuck) "restored=$($r.Restored) why=$($r.Why) stuck=$($f.Stuck)"
    Check "hand-back refused: a bounded number of tries ($([BkInput]::FocusTries)), nothing pressed" ($S.Activations -eq [BkInput]::FocusTries -and $S.Log.Count -eq 0) "$($S.Activations) tries"
    $p = New-World; $S.Fg = $A; $S.Alive = @($S.Alive | Where-Object { $_ -ne $USER }); $f = New-AfkFocus
    $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
    Check "the window to go back to closed during the round: reported as closed, stuck, Windows not asked" (-not $r.Restored -and $r.Why -eq "closed" -and $f.Stuck -and $S.Activations -eq 0) "why=$($r.Why) tries=$($S.Activations)"
    $p = New-World; $S.Fg = $A; $S.Grant = $false; $S.GoneOnWait = $USER; $f = New-AfkFocus
    $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
    Check "the window to go back to closes while handing back: reported as closed, stuck" (-not $r.Restored -and $r.Why -eq "closed" -and $f.Stuck) "why=$($r.Why)"
    $p = New-World; $S.Fg = $A; $S.ThrowActivate = $true; $f = New-AfkFocus
    $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
    Check "handing back throws: reported (not restored), stuck, no crash" (-not $r.Restored -and $f.Stuck) "why=$($r.Why)"
    $p = New-World; $S.Fg = $A; $S.ThrowForeground = $true; $f = New-AfkFocus
    $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
    Check "reading the foreground window throws while handing back: reported, stuck, no crash" (-not $r.Restored -and $f.Stuck) "why=$($r.Why)"
    $p = New-World; $S.Fg = $A; $f = New-AfkFocus
    $r = Restore-AfkFocus $f $p ([IntPtr]::Zero)
    Check "no window to go back to: reported, stuck, Windows not asked" (-not $r.Restored -and $r.Why -eq "notarget" -and $f.Stuck -and $S.Activations -eq 0) "why=$($r.Why)"
    $p = New-World; $S.Fg = $A; $f = New-AfkFocus; $f.Stuck = $true; $f.Note = "old"
    $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
    Check "a hand-back that works clears an earlier stuck flag and its message" ($r.Restored -and -not $f.Stuck -and $f.Note -eq "")

    # ---- can a round start, and where does the keyboard go back (Get-AfkPassStart) ----
    $p = New-World; $f = New-AfkFocus
    $st = Get-AfkPassStart $f $p ([IntPtr]$USER) (Ctx)
    Check "round start: Notepad in front, the keyboard goes back to Notepad" ($st.Ok -and $st.Back -eq [IntPtr]$USER)
    $f.Last = [IntPtr]$USER
    $st = Get-AfkPassStart $f $p ([IntPtr]$TASKBAR) (Ctx)
    Check "round start from the tray (taskbar in front): goes back to the remembered Notepad" ($st.Ok -and $st.Back -eq [IntPtr]$USER)
    $st = Get-AfkPassStart $f $p ([IntPtr]$BKTRAY) (Ctx)
    Check "round start from the tray (BloxKit's tray window in front): goes back to the remembered Notepad" ($st.Ok -and $st.Back -eq [IntPtr]$USER)
    $f = New-AfkFocus
    $st = Get-AfkPassStart $f $p ([IntPtr]$TASKBAR) (Ctx)
    Check "round start with no window of yours known: skipped, says why" (-not $st.Ok -and $st.Why -eq "notarget" -and $st.Back -eq [IntPtr]::Zero)
    $f = New-AfkFocus; $f.Stuck = $true; $f.Last = [IntPtr]$USER
    $st = Get-AfkPassStart $f $p ([IntPtr]$A) (Ctx)
    Check "round start while stuck and Roblox still in front: refused (no taking the keyboard again)" (-not $st.Ok -and $st.Why -eq "stuck")
    $f = New-AfkFocus; $f.Last = [IntPtr]$USER
    $st = Get-AfkPassStart $f $p ([IntPtr]$A) (Ctx)
    Check "round start while you play in a Roblox window (not stuck): it gets the keyboard back, as before" ($st.Ok -and $st.Back -eq [IntPtr]$A)
    $f = New-AfkFocus; $f.Stuck = $true
    $st = Get-AfkPassStart $f $p ([IntPtr]$USER) (Ctx)
    Check "round start while stuck but you're back in Notepad: allowed, back to Notepad" ($st.Ok -and $st.Back -eq [IntPtr]$USER)

    # ---- the 1-second timer remembers your window (Watch-AfkFocus) ----
    $p = New-World; $f = New-AfkFocus
    $cleared = Watch-AfkFocus $f $p ([IntPtr]$USER) (Ctx)
    Check "timer: Notepad in front is remembered" ($f.Last -eq [IntPtr]$USER -and -not $cleared)
    foreach ($w in @(@{ H = $A; N = "a Roblox screen" }, @{ H = $TASKBAR; N = "the taskbar" }, @{ H = $BKTRAY; N = "BloxKit's tray window" })) {
        $f = New-AfkFocus; $f.Last = [IntPtr]$USER; $f.Stuck = $true
        $cleared = Watch-AfkFocus $f $p ([IntPtr]$w.H) (Ctx)
        Check "timer: $($w.N) in front isn't remembered and doesn't clear stuck" ($f.Last -eq [IntPtr]$USER -and $f.Stuck -and -not $cleared)
    }
    $f = New-AfkFocus; $f.Stuck = $true; $f.Note = "old"
    $cleared = Watch-AfkFocus $f $p ([IntPtr]$USER) (Ctx)
    Check "timer: back in a window of yours clears stuck and its message" ($cleared -and -not $f.Stuck -and $f.Note -eq "" -and $f.Last -eq [IntPtr]$USER)
    $f = New-AfkFocus; $f.Stuck = $true
    $cleared = Watch-AfkFocus $f $p ([IntPtr]$BKMAIN) (Ctx)
    Check "timer: BloxKit's main window in front also counts as back" ($cleared -and -not $f.Stuck)

    # ---- the second hidden visit, 1.5 s later (Test-AfkRepeatOk) ----
    $p = New-World
    $first = @{ Back = [IntPtr]$USER; Restored = $true }
    Check "repeat: runs when the first visit gave the keyboard back and that window is still in front" (Test-AfkRepeatOk $p ([IntPtr]$USER) $first)
    Check "repeat: skipped when another window is in front now" (-not (Test-AfkRepeatOk $p ([IntPtr]$THIEF) $first))
    Check "repeat: skipped when a Roblox window is in front now" (-not (Test-AfkRepeatOk $p ([IntPtr]$A) $first))
    Check "repeat: skipped when the first visit couldn't give the keyboard back" (-not (Test-AfkRepeatOk $p ([IntPtr]$USER) @{ Back = [IntPtr]$USER; Restored = $false }))
    Check "repeat: skipped when there was nothing to go back to" (-not (Test-AfkRepeatOk $p ([IntPtr]::Zero) @{ Back = [IntPtr]::Zero; Restored = $true }))
    Check "repeat: skipped without a first visit" (-not (Test-AfkRepeatOk $p ([IntPtr]$USER) $null))
    $S.Alive = @($S.Alive | Where-Object { $_ -ne $USER })
    Check "repeat: skipped when that window has closed" (-not (Test-AfkRepeatOk $p ([IntPtr]$USER) $first))

    # ---- the rule, under random Windows behaviour ----
    # 2000 rounds where Windows grants or refuses the focus, other apps steal it, windows close,
    # and calls throw, at random. In every round: a press only ever reaches the intended window,
    # and every press is let go.
    $rng = New-Object System.Random 4242
    $bad = 0; $sentCount = 0; $first = ""
    for ($i = 0; $i -lt 2000; $i++) {
        $p = New-World
        $S.Grant = $rng.NextDouble() -lt 0.6
        if ($rng.NextDouble() -lt 0.2) { $S.GrantTo = $B }
        if ($rng.NextDouble() -lt 0.2) { $S.StealOnRead = $rng.Next(1, 7) }
        if ($rng.NextDouble() -lt 0.1) { $S.StealOnWait = $true }
        if ($rng.NextDouble() -lt 0.1) { $S.GoneOnWait = $A }
        if ($rng.NextDouble() -lt 0.05) { $S.ThrowActivate = $true }
        if ($rng.NextDouble() -lt 0.03) { $S.ThrowForeground = $true }
        if ($rng.NextDouble() -lt 0.15) { $S.PidAt = 55 }
        if ($rng.NextDouble() -lt 0.1) { $S.Fg = $A }
        $act = @("jump", "walk", "zoom", "click")[$rng.Next(0, 4)]
        $r = Invoke-AfkInput $p ([IntPtr]$A) $act
        if ("$r" -eq "Sent") { $sentCount++ }
        $stray = @(Strays $A).Count; $stuck = @(Presses).Count -ne @(Releases).Count
        if ($stray -or $stuck -or ("$r" -eq "Sent" -and @(Presses).Count -eq 0)) {
            $bad++; if (-not $first) { $first = "round $i ($act): $stray stray press(es), stuck=$stuck, result $r" }
        }
    }
    Check "random Windows behaviour, 2000 rounds: no press ever reached another window, none got stuck ($sentCount sent)" ($bad -eq 0 -and $sentCount -gt 0) $first

    # The same for giving the keyboard back: 1000 rounds where Windows grants or refuses it, another
    # app takes it, the window closes, or calls throw, at random. "Restored" is only ever reported when
    # that window really is in front, every failure is marked stuck, and nothing is ever pressed.
    $rng = New-Object System.Random 777
    $bad = 0; $okCount = 0; $first = ""
    for ($i = 0; $i -lt 1000; $i++) {
        $p = New-World; $S.Fg = $A; $f = New-AfkFocus
        $S.Grant = $rng.NextDouble() -lt 0.6
        if ($rng.NextDouble() -lt 0.15) { $S.GrantTo = $B }
        if ($rng.NextDouble() -lt 0.15) { $S.StealOnRead = $rng.Next(1, 6) }
        if ($rng.NextDouble() -lt 0.1) { $S.StealOnWait = $true }
        if ($rng.NextDouble() -lt 0.1) { $S.GoneOnWait = $USER }
        if ($rng.NextDouble() -lt 0.05) { $S.Alive = @($S.Alive | Where-Object { $_ -ne $USER }) }
        if ($rng.NextDouble() -lt 0.05) { $S.ThrowActivate = $true }
        if ($rng.NextDouble() -lt 0.03) { $S.ThrowForeground = $true }
        $r = Restore-AfkFocus $f $p ([IntPtr]$USER)
        if ($r.Restored) { $okCount++ }
        $wrong = ($r.Restored -and ($S.Fg -ne $USER -or $S.Alive -notcontains $USER)) -or (-not $r.Restored -and -not $f.Stuck) -or ($r.Restored -and $f.Stuck) -or $S.Log.Count
        if ($wrong) { $bad++; if (-not $first) { $first = "round ${i}: restored=$($r.Restored) why=$($r.Why) fg=$($S.Fg) stuck=$($f.Stuck) events=$($S.Log.Count)" } }
    }
    Check "random hand-backs, 1000 rounds: 'restored' only when that window is really in front, failures always stuck, nothing pressed ($okCount restored)" ($bad -eq 0 -and $okCount -gt 0 -and $okCount -lt 1000) $first
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_"
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All anti-AFK input checks passed." })
exit $script:fails
