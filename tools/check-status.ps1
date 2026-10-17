# Checks how Roblox Manager tells what a Roblox window is doing (from Roblox's log),
# which launch a new window belongs to, and how a Chrome profile is set up.
#     powershell -ExecutionPolicy Bypass -File tools\check-status.ps1
# No app window, no network, no real Chrome or Roblox files.
. (Join-Path $PSScriptRoot "..\RobloxManager.ps1") -TestOnly

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}
$Dir = Join-Path ([IO.Path]::GetTempPath()) ("rml-status-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $Dir | Out-Null

# Real lines from Roblox's logs (timestamps, ids and addresses changed).
$P = "2026-10-14T15:39:43.930Z,1.930918,4930,6"
$L = @{
    join      = "$P [FLog::Output] ! Joining game 'b827d90b-464f-4680-a963-3eaf94e71248' place 1234567890 at 10.32.6.227"
    accepted  = "$P,Info [DFLog::NetworkClient] Connection accepted from 128.116.54.33|62557"
    replic    = "$P [FLog::Network] Replicator created for player 128.116.54.33|62557"
    teleport  = "$P [FLog::SessionTransitionFSM] Teleported."
    left      = "$P,Info [DFLog::RbxTransportDummyClient] Disconnected from server for reason: Player: 285 (DisconnectClientInitiated)"
    shutdown  = "$P,Info [DFLog::RbxTransportDummyClient] Connection closed by server for reason: RCC: 288 (DisconnectServerShutdown)"
    elsewhere = "$P,Warning [FLog::Network] Lost connection with reason : Disconnected from game, possibly due to game joined from another device"
    idle      = "$P,Info [DFLog::RbxTransportDummyClient] Disconnected from server for reason: Player: 278 (DisconnectIdle)"
    kickmsg   = "$P,Error [FLog::CreatorError] Error: Server Kick Message: Profile session end - Please rejoin; Metadata: "
    noise     = "$P [FLog::Network] Time to disconnect replication data: 0.0123"
    handoff   = "$P [FLog::SingleSurfaceApp] initializeSingleton"
}

try {
    # ---- reading log lines ----
    $e = Read-LogEvent $L.join
    Check "a join line gives the server and game" ($e.Kind -eq "join" -and $e.Job -eq "b827d90b-464f-4680-a963-3eaf94e71248" -and $e.Place -eq "1234567890")
    Check "'Connection accepted' means connected" ((Read-LogEvent $L.accepted).Kind -eq "connected")
    Check "'Replicator created for player' means connected" ((Read-LogEvent $L.replic).Kind -eq "connected")
    Check "a teleport is recognised" ((Read-LogEvent $L.teleport).Kind -eq "teleport")
    Check "leaving on purpose (285) isn't a disconnect" ((Read-LogEvent $L.left).Kind -eq "left")
    $e = Read-LogEvent $L.shutdown
    Check "'Connection closed by server' (288) is a disconnect: server shut down" ($e.Kind -eq "disc" -and $e.Code -eq "288" -and $e.Text -match "shut down")
    $e = Read-LogEvent $L.elsewhere
    Check "'joined from another device' says so" ($e.Kind -eq "disc" -and $e.Text -match "somewhere else")
    $e = Read-LogEvent $L.idle
    Check "idle kick (278) says so" ($e.Kind -eq "disc" -and $e.Code -eq "278" -and $e.Text -match "idle")
    $e = Read-LogEvent $L.kickmsg
    Check "a game's kick message is read" ($e.Kind -eq "kickmsg" -and $e.Text -eq "Profile session end - Please rejoin")
    Check "other lines are ignored" ($null -eq (Read-LogEvent $L.noise))

    # ---- what the window is doing ----
    $t0 = [DateTime]"2026-10-14 15:00:00"
    function Feed($s, [string[]]$keys, $at) { foreach ($k in $keys) { $e = Read-LogEvent $L[$k]; if ($e) { Update-Session $s $e $at | Out-Null } } }
    $s = New-Session $t0
    Check "a new window is loading" ($s.State -eq "loading")
    Feed $s @("accepted") $t0
    Check "'connected' without a join first doesn't count" ($s.State -eq "loading")
    Feed $s @("join") $t0
    Check "after the join line it's joining, with the server known" ($s.State -eq "joining" -and $s.Job -match '^b827d90b')
    $changed = Update-Session $s (Read-LogEvent $L.accepted) $t0.AddSeconds(2)
    Check "after the connection is accepted it's connected" ($s.State -eq "connected" -and $changed)
    Check "a second connected line changes nothing" (-not (Update-Session $s (Read-LogEvent $L.replic) $t0.AddSeconds(2)))
    Feed $s @("shutdown") $t0.AddSeconds(60)
    Check "a disconnect gives the reason and when" ($s.State -eq "disconnected" -and $s.Reason -match "shut down" -and $s.ChangedAt -eq $t0.AddSeconds(60))
    Feed $s @("teleport", "join") $t0.AddSeconds(63)
    Check "a teleport then a join is joining again, reason cleared" ($s.State -eq "joining" -and -not $s.Reason)
    Feed $s @("accepted") $t0.AddSeconds(65)
    Feed $s @("kickmsg", "elsewhere") $t0.AddSeconds(90)
    Check "a game kick message is used as the reason" ($s.State -eq "disconnected" -and $s.Reason -match "Profile session end")
    $s = New-Session $t0; Feed $s @("join", "accepted", "left") $t0
    Check "leaving on purpose is 'left', not disconnected" ($s.State -eq "left")

    Check "no log found yet: loading" ((Get-ClientState (New-Session $t0) $false $false) -eq "loading")
    Check "no log found after trying: unknown, never 'connected'" ((Get-ClientState (New-Session $t0) $false $true) -eq "unknown")
    $s = New-Session $t0; Feed $s @("join", "accepted") $t0
    Check "log found and connected: connected" ((Get-ClientState $s $true $false) -eq "connected")

    # ---- which launch a new Roblox window belongs to ----
    # Launches go one at a time. A window belongs to the latest launch that started
    # before its Roblox process did.
    function Op([string]$nick, [int]$sec, [long]$hwnd = 0) { [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Nick = $nick; Start = $t0.AddSeconds($sec); Hwnd = $hwnd } }
    $ops = @(Op "Alt1" 0)
    Check "a window started after the launch belongs to it" ((Select-LaunchForWindow $t0.AddSeconds(12) $ops 600).Nick -eq "Alt1")
    Check "a window started before any launch belongs to none (opened some other way)" ($null -eq (Select-LaunchForWindow $t0.AddSeconds(-5) $ops 600))
    $ops = @((Op "Alt1" 0), (Op "Alt2" 90))
    Check "a slow window from a launch that gave up still goes to that account, not the next one" ((Select-LaunchForWindow $t0.AddSeconds(85) $ops 600).Nick -eq "Alt1")
    Check "a window started after the next launch goes to the next one" ((Select-LaunchForWindow $t0.AddSeconds(95) $ops 600).Nick -eq "Alt2")
    $ops = @((Op "Alt1" 0), (Op "Alt2" 90 12345))
    Check "a second window for a launch that already has one belongs to none" ($null -eq (Select-LaunchForWindow $t0.AddSeconds(100) $ops 600))
    $ops = @(Op "Alt1" 0)
    Check "a launch older than the time limit is ignored" ($null -eq (Select-LaunchForWindow $t0.AddSeconds(700) $ops 600))
    $c = Op "Alt1" 0; $c | Add-Member -NotePropertyName Cancelled -NotePropertyValue $true
    Check "a cancelled launch never claims a window (it may be one you opened yourself)" ($null -eq (Select-LaunchForWindow $t0.AddSeconds(10) @($c) 600))

    # ---- multi-window off: Roblox hands a new launch to the window that's already open ----
    # (seen in real logs: the new process quits, the old window logs initializeSingleton, then joins)
    Check "'initializeSingleton' is read as a hand-over" ((Read-LogEvent $L.handoff).Kind -eq "handoff")
    $s = New-Session $t0; Feed $s @("join", "accepted") $t0
    Feed $s @("handoff") $t0.AddSeconds(30)
    Check "after a hand-over the window is loading again (not 'in game' from before)" ($s.State -eq "loading")
    $winStart = $t0.AddSeconds(-600)   # a window opened 10 minutes earlier
    function HOp([string]$nick, [int]$sec, [long]$hwnd = 0, [bool]$cancelled = $false) { [pscustomobject]@{ Nick = $nick; Start = $t0.AddSeconds($sec); Hwnd = $hwnd; Cancelled = $cancelled } }
    $ops = @(HOp "Alt1" 0)
    Check "a hand-over right after a launch belongs to that launch" ((Select-LaunchForHandoff $winStart $t0.AddSeconds(2) $ops 360).Nick -eq "Alt1")
    Check "a hand-over before the launch belongs to none" ($null -eq (Select-LaunchForHandoff $winStart $t0.AddSeconds(-2) $ops 360))
    $ops = @(HOp "Alt1" 0 555)
    Check "a launch that already has its window isn't taken again" ($null -eq (Select-LaunchForHandoff $winStart $t0.AddSeconds(2) $ops 360))
    $ops = @(HOp "Alt1" 0 0 $true)
    Check "a cancelled launch isn't taken" ($null -eq (Select-LaunchForHandoff $winStart $t0.AddSeconds(2) $ops 360))
    $ops = @(HOp "Alt1" -900)
    Check "a hand-over long after the launch belongs to none" ($null -eq (Select-LaunchForHandoff $winStart $t0.AddSeconds(2) $ops 360))
    $ops = @(HOp "Old" -700)
    Check "a window's own start-up (opened after the launch) isn't a hand-over" ($null -eq (Select-LaunchForHandoff $t0.AddSeconds(-650) $t0.AddSeconds(-649) $ops 360))

    # ---- spreading accounts over servers (shape of games.roblox.com/v1/games/{id}/servers/Public) ----
    function Srv([string]$id, [int]$playing, [int]$max) { [pscustomobject]@{ id = $id; playing = $playing; maxPlayers = $max } }
    $list = @((Srv "s1" 8 9), (Srv "s2" 3 9), (Srv "s3" 9 9), (Srv "s4" 6 9))
    $r = Select-Servers $list 4 2 @{}
    Check "up to 2 per server: uses the servers with room, emptiest first, never a full one" (($r.Jobs -join ",") -eq "s2,s2,s4,s4" -and $r.Short -eq 0)
    $r = Select-Servers $list 4 1 @{}
    Check "1 per server (separate servers): one account on each server with room" (($r.Jobs -join ",") -eq "s2,s4,s1" -and $r.Short -eq 1)
    $r = Select-Servers $list 2 2 @{ "s2" = 2 }
    Check "accounts already on a server count toward its limit" (($r.Jobs -join ",") -eq "s4,s4")
    $r = Select-Servers @((Srv "s9" 9 9)) 2 2 @{}
    Check "no room anywhere: says how many couldn't get a server" ($r.Jobs.Count -eq 0 -and $r.Short -eq 2)
    $r = Select-Servers $list 0 2 @{}
    Check "nobody to place: nothing chosen" ($r.Jobs.Count -eq 0 -and $r.Short -eq 0)

    $job = "b827d90b-464f-4680-a963-3eaf94e71248"
    Check "landed on the planned server: confirmed" ((Get-ServerCheck $job $job) -eq "confirmed")
    Check "landed somewhere else: says so" ((Get-ServerCheck $job "aaaaaaaa-464f-4680-a963-3eaf94e71248") -eq "elsewhere")
    Check "no join seen yet: not confirmed" ((Get-ServerCheck $job "") -eq "pending")
    Check "no server was planned: nothing to check" ((Get-ServerCheck "" $job) -eq "")

    # ---- GPU use per program (Windows' "GPU Engine" counters, like Task Manager) ----
    # Each engine counter grows by its busy time (100 ns units); use = busy time / elapsed time.
    $L1 = "luid_0x00000000_0x0000da19"; $L2 = "luid_0x00000000_0x0000edfa"
    function GS($raw, $t) { @{ Raw = [long]$raw; Time = [long]$t } }
    $old = @{
        "pid_100_${L1}_phys_0_eng_0_engtype_3D" = (GS 0 0); "pid_100_${L1}_phys_0_eng_1_engtype_VideoDecode" = (GS 0 0)
        "pid_200_${L1}_phys_0_eng_0_engtype_3D" = (GS 0 0); "pid_300_${L2}_phys_0_eng_0_engtype_3D" = (GS 0 0)
        "pid_400_${L1}_phys_0_eng_0_engtype_3D" = (GS 0 0)
    }
    $new = @{
        "pid_100_${L1}_phys_0_eng_0_engtype_3D" = (GS 2500000 10000000); "pid_100_${L1}_phys_0_eng_1_engtype_VideoDecode" = (GS 500000 10000000)
        "pid_200_${L1}_phys_0_eng_0_engtype_3D" = (GS 1000000 10000000); "pid_300_${L2}_phys_0_eng_0_engtype_3D" = (GS 7000000 10000000)
        "pid_500_${L1}_phys_0_eng_0_engtype_3D" = (GS 9000000 10000000)
    }
    $g = Measure-GpuUsage $old $new
    Check "GPU use per program: its busiest engine (25% 3D, not 25%+5%)" ([Math]::Round($g.ByPid["100"].Pct, 1) -eq 25 -and $g.ByPid["100"].Luid -eq "0x00000000_0x0000da19")
    Check "programs on another graphics chip are told apart" ([Math]::Round($g.ByPid["300"].Pct, 1) -eq 70 -and $g.ByPid["300"].Luid -eq "0x00000000_0x0000edfa")
    Check "each graphics chip's total (3D on the first: 25% + 10%)" ([Math]::Round($g.ByAdapter["0x00000000_0x0000da19"], 1) -eq 35)
    Check "a program that started or stopped between samples isn't guessed" (-not $g.ByPid.ContainsKey("400") -and -not $g.ByPid.ContainsKey("500"))
    Check "no counters (old Windows or blocked): 'not available', not 0%" ($null -eq (Measure-GpuUsage $null $new))
    $g2 = Measure-GpuUsage @{ "pid_7_${L1}_phys_0_eng_0_engtype_3D" = (GS 0 0) } @{ "pid_7_${L1}_phys_0_eng_0_engtype_3D" = (GS 123456 10000000) }
    Check "fractions are kept (1.23456%, not rounded to 1)" ([Math]::Round($g2.ByPid["7"].Pct, 4) -eq 1.2346)
    Check "CPU share: 2.5 s of CPU time in 10 s on 16 threads = 1.6% of the whole CPU" ([Math]::Round((Get-CpuShare 1000 3500 10000 16), 2) -eq 1.56)

    # ---- Chrome profile setup (read only; shapes copied from Chrome 155's files) ----
    $helper = "C:\Apps\RobloxManager\AutoJoinHelper"
    function Profile([string]$name, [string]$prefs, [string]$secure) {
        $p = Join-Path $Dir $name; New-Item -ItemType Directory -Path $p -Force | Out-Null
        if ($null -ne $prefs) { [IO.File]::WriteAllText((Join-Path $p "Preferences"), $prefs) }
        if ($null -ne $secure) { [IO.File]::WriteAllText((Join-Path $p "Secure Preferences"), $secure) }
        return $p
    }
    $allow = '{ "protocol_handler": { "allowed_origin_protocol_pairs": { "https://www.roblox.com": { "roblox-player": true } } } }'
    function Ext([string]$path, [string]$disable = "[]") { '{ "extensions": { "settings": { "gebfhbfgpelafaonkaioipickjgddoem": { "location": 4, "path": ' + (ConvertTo-Json $path) + ', "disable_reasons": ' + $disable + ' } } } }' }

    $r = Get-ProfileSetup (Profile "ready" $allow (Ext $helper)) $helper
    Check "helper installed from this folder and 'Always allow' ticked" ($r.Exists -and $r.Helper -eq "on" -and $r.AlwaysAllow -eq "yes")
    $r = Get-ProfileSetup (Profile "fresh" '{ "profile": { "name": "Person 2" } }' '{ "extensions": { "settings": {} } }') $helper
    Check "a fresh profile: no helper, 'Always allow' not ticked" ($r.Helper -eq "missing" -and $r.AlwaysAllow -eq "no")
    $r = Get-ProfileSetup (Profile "disabled" $allow (Ext $helper "[1]")) $helper
    Check "helper turned off in Chrome" ($r.Helper -eq "off")
    $r = Get-ProfileSetup (Profile "moved" $allow (Ext "D:\Old\RobloxManager\AutoJoinHelper")) $helper
    Check "helper loaded from another folder (app was moved)" ($r.Helper -eq "elsewhere" -and $r.HelperPath -eq "D:\Old\RobloxManager\AutoJoinHelper")
    $r = Get-ProfileSetup (Profile "case" $allow (Ext ($helper.ToLower() + "\"))) $helper
    Check "same folder written differently still counts" ($r.Helper -eq "on")
    $r = Get-ProfileSetup (Join-Path $Dir "not-there") $helper
    Check "a missing profile folder: doesn't exist, nothing known" ((-not $r.Exists) -and $r.Helper -eq "unknown" -and $r.AlwaysAllow -eq "unknown")
    $r = Get-ProfileSetup (Profile "broken" '{ broken' (Ext $helper)) $helper
    Check "an unreadable Preferences file: 'Always allow' unknown, helper still found" ($r.AlwaysAllow -eq "unknown" -and $r.Helper -eq "on")
    # Chrome records a helper with a background part (2.2+) like this; 2.1 had none.
    $v22 = '{ "extensions": { "settings": { "gebfhbfgpelafaonkaioipickjgddoem": { "location": 4, "path": ' + (ConvertTo-Json $helper) + ', "disable_reasons": [], "service_worker_registration_info": { "version": "2.2" } } } } }'
    $r = Get-ProfileSetup (Profile "v22" $allow $v22) $helper
    Check "helper version 2.2 is read from Chrome's record" ($r.Helper -eq "on" -and $r.HelperVersion -eq "2.2")
    $r = Get-ProfileSetup (Join-Path $Dir "ready") $helper
    Check "helper 2.1 (no background part) has no version" ($r.Helper -eq "on" -and $r.HelperVersion -eq "")
    Check "2.2 can close tabs, 2.1 and none can't" ((Test-HelperCanCloseTabs "2.2") -and (Test-HelperCanCloseTabs "2.10") -and -not (Test-HelperCanCloseTabs "") -and -not (Test-HelperCanCloseTabs "2.1"))

    # ---- launch marker ----
    $g = "https://www.roblox.com/games/1"; $id = "0f8fad5b-d9cb-469f-a165-70867728950e"
    Check "no auto-join, no tab closing: link unchanged" ((Add-Marker $g $false) -eq $g)
    Check "auto-join only: as before" ((Add-Marker $g $true) -eq "$g#rml-autojoin")
    Check "tab closing only" ((Add-Marker $g $false "" "" $id 5123) -eq "$g#rml-launch&op=$id&port=5123")
    Check "auto-join and tab closing" ((Add-Marker $g $true "" "" $id 5123) -eq "$g#rml-autojoin&op=$id&port=5123")
    $job = "b827d90b-464f-4680-a963-3eaf94e71248"
    Check "rejoin a server and tab closing" ((Add-Marker $g $true $job "1" $id 5123) -eq "$g#rml-autojoin&job=$job&place=1&op=$id&port=5123")
    Check "a link that already has a # is left alone" ((Add-Marker "$g#x" $true "" "" $id 5123) -eq "$g#x")

    # ---- when may the launch tab close? ----
    function TOp([int]$sec, [long]$hwnd = 0, [bool]$cancelled = $false) { [pscustomobject]@{ Id = $id; Start = $t0.AddSeconds(-$sec); Hwnd = $hwnd; Cancelled = $cancelled } }
    Check "unknown launch: keep the tab" ((Get-TabAnswer $null "" $t0 "connected" 360) -eq "unknown")
    Check "no Roblox window yet: wait" ((Get-TabAnswer (TOp 20) "" $t0 "connected" 360) -eq "wait")
    Check "no Roblox window after the time limit: keep" ((Get-TabAnswer (TOp 400) "" $t0 "connected" 360) -eq "keep")
    Check "cancelled: keep" ((Get-TabAnswer (TOp 20 0 $true) "" $t0 "connected" 360) -eq "keep")
    Check "window open, setting 'when the window opens': close" ((Get-TabAnswer (TOp 20 77) "loading" $t0 "window" 360) -eq "close")
    Check "window open but still joining, setting 'in game': wait" ((Get-TabAnswer (TOp 20 77) "joining" $t0 "connected" 360) -eq "wait")
    Check "in game, setting 'in game': close" ((Get-TabAnswer (TOp 20 77) "connected" $t0 "connected" 360) -eq "close")
    Check "can't tell if it's in game (no log): keep" ((Get-TabAnswer (TOp 20 77) "unknown" $t0 "connected" 360) -eq "keep")
    Check "left the game before joining: keep" ((Get-TabAnswer (TOp 20 77) "left" $t0 "connected" 360) -eq "keep")
    Check "its window closed again: keep" ((Get-TabAnswer (TOp 20 77) "" $t0 "connected" 360) -eq "keep")
    Check "still joining after the time limit: keep" ((Get-TabAnswer (TOp 400 77) "joining" $t0 "connected" 360) -eq "keep")
    Check "tab closing turned off: keep" ((Get-TabAnswer (TOp 20 77) "connected" $t0 "off" 360) -eq "keep")

    # ---- why a launch tab closed or stayed open (shown to you) ----
    $v = Get-TabVerdict (TOp 20 77) "connected" $t0 "connected" 360
    Check "closing: the answer and why" ($v.State -eq "close" -and $v.Why -match "in a game")
    $v = Get-TabVerdict (TOp 20 77) "unknown" $t0 "connected" 360
    Check "kept open because there's no Roblox log to confirm the game" ($v.State -eq "keep" -and $v.Why -match "log")
    $v = Get-TabVerdict (TOp 400) "" $t0 "connected" 360
    Check "kept open because no Roblox window appeared" ($v.State -eq "keep" -and $v.Why -match "No Roblox window")
    Check "the verdict and Get-TabAnswer always agree" ((Get-TabAnswer (TOp 20 77) "joining" $t0 "connected" 360) -eq (Get-TabVerdict (TOp 20 77) "joining" $t0 "connected" 360).State)
    Check "not tracked: tab closing is off" ((Get-TabSkipReason "off" @{ Helper = "on"; HelperVersion = "2.2" }) -match "off")
    Check "not tracked: no helper in this profile" ((Get-TabSkipReason "connected" @{ Helper = "missing"; HelperVersion = "" }) -match "isn't installed")
    Check "not tracked: helper older than 2.2" ((Get-TabSkipReason "connected" @{ Helper = "on"; HelperVersion = "" }) -match "older than 2\.2")
    Check "tracked: no reason" ((Get-TabSkipReason "connected" @{ Helper = "on"; HelperVersion = "2.2" }) -eq "")

    # ---- the helper's question ----
    $q = Read-TabRequest "GET /launch/$id`?v=2.2 HTTP/1.1`r`nHost: 127.0.0.1:5123`r`nAccept: */*`r`n`r`n"
    Check "the helper's question is read" ($q.Op -eq $id -and $q.Version -eq "2.2")
    Check "the extension's origin is allowed" ($null -ne (Read-TabRequest "GET /launch/$id`?v=2.2 HTTP/1.1`r`nOrigin: chrome-extension://gebfhbfgpelafaonkaioipickjgddoem`r`n`r`n"))
    Check "a web page's origin is refused" ($null -eq (Read-TabRequest "GET /launch/$id`?v=2.2 HTTP/1.1`r`nOrigin: https://evil.example`r`n`r`n"))
    Check "anything else is refused" ($null -eq (Read-TabRequest "POST /launch/$id`?v=2.2 HTTP/1.1`r`n`r`n") -and $null -eq (Read-TabRequest "GET /etc/passwd HTTP/1.1`r`n`r`n"))

    # ---- a real local listener ----
    $srv = Start-TabListener
    Check "listens on this PC only" ($srv.LocalEndpoint.Address.ToString() -eq "127.0.0.1" -and $srv.LocalEndpoint.Port -gt 0)
    Add-Type -AssemblyName System.Net.Http
    $http = New-Object System.Net.Http.HttpClient
    $task = $http.GetStringAsync("http://127.0.0.1:$($srv.LocalEndpoint.Port)/launch/$id`?v=2.2")
    $asked = $null
    for ($i = 0; $i -lt 40 -and -not $task.IsCompleted; $i++) {
        Step-TabListener $srv { param($req) $script:asked = $req; "close" } | Out-Null
        Start-Sleep -Milliseconds 50
    }
    Check "answers the helper over HTTP" ($task.IsCompleted -and -not $task.IsFaulted -and $task.Result -match '"state"\s*:\s*"close"' -and $script:asked.Op -eq $id) $(if ($task.IsFaulted) { $task.Exception.InnerException.Message } else { "" })
    $silent = @(1..6 | ForEach-Object { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $srv.LocalEndpoint.Port); $c })   # connect, send nothing
    Start-Sleep -Milliseconds 100
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Step-TabListener $srv { param($req) "close" } | Out-Null
    Check "programs that connect and send nothing can't freeze the window (6 of them: under 0.8 s)" ($sw.ElapsedMilliseconds -lt 800) "$($sw.ElapsedMilliseconds) ms"
    foreach ($c in $silent) { $c.Close() }
    $srv.Stop()
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_"
}
finally {
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All status checks passed." })
exit $script:fails
