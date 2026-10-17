# ==========================================================================
#  ROBLOX MANAGER  -  one app for everything
#
#  Accounts tab     your accounts (one Chrome profile each), links, groups,
#                   and opening them one at a time (waits for each to load)
#  Live screens     CCTV wall of every Roblox window, click to play,
#                   mute, close, and Anti-AFK
#  Settings         timing, alerts, auto-rejoin, tray, sound
#
#  It never sees your passwords. Chrome keeps your logins, not this app.
#  Saved in %APPDATA%\RobloxMultiLauncher\  (settings.json, session.json)
# ==========================================================================

param([switch]$TestOnly, [switch]$Minimized, [switch]$NoRoblox)

$BkVersion = "1.3.0"   # shown in Settings > Help and feedback; bug reports ask for it
$BkLinks = @{
    Discord = "https://discord.gg/n24kcvG8zZ"   # the community server (invite never expires); empty hides the "Join the BloxKit Discord" button
    Repo    = "https://github.com/jirodc/BloxKit"
    Bug     = "https://github.com/jirodc/BloxKit/issues/new?template=bug_report.yml"
    Idea    = "https://github.com/jirodc/BloxKit/issues/new?template=feature_request.yml"
    Raw     = "https://raw.githubusercontent.com/jirodc/BloxKit/main/BloxKit.ps1"   # the update check reads $BkVersion from its first lines
}
# -NoRoblox is for tools and tests: the app opens with its settings but never opens Chrome or touches
# Roblox windows, the multi-window lock, hotkeys or the daily start, and runs next to a real copy.

# ---------------------------------------------------------------- helpers --
function Get-LinkInfo([string]$text) {
    # Looks at what was pasted and says what kind of Roblox link it is.
    $t = ("" + $text).Trim()
    if ($t -eq "") { return @{ Kind = "empty"; Url = ""; Label = "" } }
    if ($t -match '^\d{3,}$') {
        return @{ Kind = "game"; Url = "https://www.roblox.com/games/$t"; Label = "Game (ID $t)" }
    }
    if ($t -notmatch '^[a-zA-Z]+://') { $t = "https://" + $t }
    $uri = $null
    if (-not [System.Uri]::TryCreate($t, [System.UriKind]::Absolute, [ref]$uri)) {
        return @{ Kind = "bad"; Url = ""; Label = "That doesn't look like a link." }
    }
    $hostName = $uri.Host.ToLower()
    $path = $uri.AbsolutePath.ToLower() -replace '^/[a-z]{2}(-[a-z]{2})?(?=/)', ''   # /de/..., /en-us/...
    $query = $uri.Query.ToLower()
    if ($hostName -eq "ro.blox.com") {
        # Links from the Roblox app carry the normal web link inside (af_web_dp=...).
        if ($uri.Query -match '[?&]af_web_dp=([^&]+)') {
            $inner = Get-LinkInfo ([Uri]::UnescapeDataString($Matches[1]))
            if (@("game","private","profile","share") -contains $inner.Kind) { return $inner }
        }
        return @{ Kind = "share"; Url = $t; Label = "Roblox share link" }
    }
    if ($hostName -notmatch '^((www|web)\.)?roblox\.com$') { return @{ Kind = "bad"; Url = ""; Label = "That isn't a Roblox link." } }
    if ($path -match '^/share' -and $query -match 'type=server') { return @{ Kind = "private"; Url = $t; Label = "Private server link" } }
    if ($path -match '^/share' -and $query -match 'type=profile') { return @{ Kind = "profile"; Url = $t; UserId = ""; Label = "Profile share link (joins that player's server)" } }
    if ($path -match '^/share' -and $query -match 'type=experience') { return @{ Kind = "game"; Url = $t; Label = "Game share link" } }
    if ($path -match '^/share') { return @{ Kind = "share"; Url = $t; Label = "Roblox share link" } }
    if ($path -match '^/games/start') { return @{ Kind = "bad"; Url = ""; Label = "Roblox turned off this kind of link. Paste the normal game link instead." } }
    if ($path -match '^/games/\d+' -and $query -match 'privateserverlinkcode=') { return @{ Kind = "private"; Url = $t; Label = "Private server link" } }
    if ($path -match '^/games/\d+') { return @{ Kind = "game"; Url = $t; Label = "Game link" } }
    if ($path -match '^/users/(\d+)') { return @{ Kind = "profile"; Url = $t; UserId = $Matches[1]; Label = "Profile link (joins that player's server)" } }
    return @{ Kind = "other"; Url = $t; Label = "Roblox page. It may not be a game." }
}

function Get-SafeName([string]$s) {
    $x = ($s -replace '[^A-Za-z0-9_-]', '')
    if ($x -eq "") { $x = "Account" }
    return $x
}

function Add-Marker([string]$url, [bool]$auto, [string]$job = "", [string]$place = "", [string]$op = "", [int]$port = 0) {
    # The auto-click helper only acts on links that end with this marker.
    # job/place = a server to rejoin (the helper calls joinGameInstance).
    # op/port   = this launch's id and where BloxKit answers, so the helper (2.2+)
    #             can close the launch tab once the launch is confirmed.
    if (-not $url -or $url -match '#') { return $url }
    $parts = @()
    if ($auto) {
        $parts += "rml-autojoin"
        if ($job -match '^[0-9a-fA-F-]{36}$' -and $place -match '^\d+$') { $parts += "job=$job"; $parts += "place=$place" }
    }
    if ($op -match '^[0-9a-fA-F-]{36}$' -and $port -gt 0) {
        if (-not $auto) { $parts += "rml-launch" }
        $parts += "op=$op"; $parts += "port=$port"
    }
    if ($parts.Count -eq 0) { return $url }
    return $url + "#" + ($parts -join "&")
}

# ---------------------------------------------------------- settings file --
# Reading, checking and writing settings.json. No window needed, so
# tools\check-settings.ps1 can test these.
function New-Defaults {
    [pscustomobject]@{
        accounts      = @()
        lastLink      = ""
        autoJoin      = $false
        favorites     = @()
        groups        = @()
        launchTimeout = 90      # seconds to wait for a Roblox window
        launchSettle  = 12      # extra seconds after it appears, before the next one (the Low resource preset is the default)
        mainSettle    = 20      # "Start everything": time for the main to get into the game
        tabCloseWhen  = "off"   # close the Chrome tab a launch came from: off | window (Roblox window opened) | connected (in a game)
        spread        = 0       # game links: 0 = Roblox picks the server; N = spread out, up to N of your accounts per server
        maxClients    = 0       # most Roblox windows open at once (0 = no limit)
        rbxQuality    = 1       # Roblox graphics picked in Settings > Performance, 1-10 (0 = not picked: show Roblox's own); lowest by default
        rbxFps        = 30      # 30 | 60 | 144 | 240 | -1 (Roblox default); 0 = not picked
        rbxAuto       = $true   # keep Roblox on those: BloxKit writes them into Roblox's file itself whenever no Roblox is running
        alertSound    = $true
        autoRejoin    = $false
        rejoinSameServer = $true
        autoMuteAlts  = $false
        trayOnMinimize = $true
        afkMinutes    = 5
        afkMode       = "hidden"
        afkOn         = $false      # the anti-AFK switch, as it was when the app closed
        animations    = $true       # startup intro, page changes, mascot reactions (also off when Windows' animations are off)
        afkOff        = @()         # lower-case nicks whose screen has its AFK tick off
        soundOff      = @{}         # lower-case nick -> muted or not, each account's own Mute (the main always opens with sound)
        afkSkipActive = $true
        afkJitter     = $true
        afkActions    = @("jump")   # any of: jump, walk, zoom, click (one is picked at random each time)
        clickSpots    = @{}         # account nick -> "x,y" (fractions of the window) for the "click" action
        discCheck     = $true
        lowPower      = $true       # alt windows small (part of the Low resource preset)
        ecoAlts       = $true       # Windows efficiency mode for every window except the main
        webhook       = ""
        webhookOnDone = $false
        schedOn       = $false
        schedTime     = "08:00"
        schedLink     = ""
        schedLastRun  = ""
        statsDate     = ""
        statsSecs     = @{}
        plan          = (New-PlanDefaults)   # the group schedule (see "schedule" below)
        planRun       = $null                 # the schedule in progress, as saved
        planHistory   = @()                   # what the schedule did, newest last (up to 100)
        winWidth      = 0                     # the window's size last time (0 = the normal size)
        winHeight     = 0
        winMax        = $false
    }
}

function New-Account([string]$nick, [string]$profileDir) {
    # id never changes, even when the nickname does.
    [pscustomobject]@{
        id = [guid]::NewGuid().ToString(); nick = $nick; profileDir = $profileDir; profileUrl = ""
        isMain = $false; checked = $false; lastUrl = ""
        needsLogin = $false   # true after a backup is loaded on a PC that doesn't have this Chrome profile
        autoJoin = $false     # the helper clicks Play / Join for this account
    }
}

function ConvertTo-State($s) {
    # Builds a clean State from a parsed settings file. Returns @{ State; Warnings }.
    $state = New-Defaults
    $warn = @()
    $accs = @(); $seen = @{}; $ids = @{}
    foreach ($a in @($s.accounts)) {
        if ($null -eq $a) { continue }
        $nick = ("" + $a.nick).Trim()
        if ($nick -eq "") { $warn += "Skipped an account with no nickname."; continue }
        if ($seen.ContainsKey($nick.ToLower())) { $warn += "Skipped a second account called '$nick' (nicknames must be different)."; continue }
        $seen[$nick.ToLower()] = $true
        $acc = New-Account $nick ("" + $a.profileDir)
        if (("" + $a.id) -match '^[0-9a-fA-F-]{36}$' -and -not $ids.ContainsKey("" + $a.id)) { $acc.id = "" + $a.id }
        $ids[$acc.id] = $true
        $acc.profileUrl = "" + $a.profileUrl; $acc.isMain = [bool]$a.isMain; $acc.checked = [bool]$a.checked
        $acc.lastUrl = "" + $a.lastUrl; $acc.needsLogin = [bool]$a.needsLogin
        # Before auto-click was per account there was one setting for all: start from that.
        $acc.autoJoin = $(if ($null -ne $a.autoJoin) { [bool]$a.autoJoin } else { [bool]$s.autoJoin })
        $accs += $acc
    }
    foreach ($grp in @($accs | Where-Object { $_.profileDir } | Group-Object { $_.profileDir.ToLower() } | Where-Object { $_.Count -gt 1 })) {
        # Kept as they are (nothing is lost), but they share one Roblox login in Chrome.
        $warn += (@($grp.Group | ForEach-Object { $_.nick }) -join " and ") + " use the same Chrome profile ('$($grp.Group[0].profileDir)'), so they share one Roblox login. Remove one and add it again with 'A new Chrome profile'."
    }
    $mains = @($accs | Where-Object { $_.isMain })
    if ($mains.Count -gt 1) {
        foreach ($m in $mains[1..($mains.Count - 1)]) { $m.isMain = $false }
        $warn += "More than one main was saved. Kept $($mains[0].nick) as the main."
    }
    $state.accounts = $accs
    $state.favorites = @(foreach ($f in @($s.favorites)) { if ($f -and $f.url) { [pscustomobject]@{ name = "" + $f.name; url = "" + $f.url } } })
    $grps = @()
    foreach ($g in @($s.groups)) {
        if (-not $g -or -not ("" + $g.name).Trim()) { continue }
        $members = @()
        foreach ($n in @($g.nicks)) {
            $acc = @($accs | Where-Object { $_.nick -ieq ("" + $n) }) | Select-Object -First 1
            if ($acc) { if ($members -notcontains $acc.nick) { $members += $acc.nick } }
            elseif ("" + $n) { $warn += "Group '$($g.name)': removed '$n', there's no account with that name." }
        }
        $gname = ("" + $g.name).Trim()
        if (@($grps | Where-Object { $_.name -ieq $gname }).Count) {
            $n = 2; while (@($grps | Where-Object { $_.name -ieq "$gname ($n)" }).Count) { $n++ }
            $warn += "There were two groups called '$gname'. The second one is now '$gname ($n)'."
            $gname = "$gname ($n)"
        }
        $gid = $(if (("" + $g.id) -match '^[0-9a-fA-F-]{36}$' -and -not @($grps | Where-Object { $_.id -eq ("" + $g.id) }).Count) { "" + $g.id } else { [guid]::NewGuid().ToString() })
        $grps += [pscustomobject]@{ id = $gid; name = $gname; nicks = $members }
    }
    $state.groups = $grps
    foreach ($p in "lastLink","afkMode","webhook","schedTime","schedLink","schedLastRun","statsDate") { if ($null -ne $s.$p) { $state.$p = "" + $s.$p } }
    if (@("off", "window", "connected") -contains ("" + $s.tabCloseWhen)) { $state.tabCloseWhen = "" + $s.tabCloseWhen }
    $n = 0; if ([int]::TryParse("" + $s.spread, [ref]$n) -and $n -ge 0 -and $n -le 20) { $state.spread = $n }
    $n = 0; if ([int]::TryParse("" + $s.maxClients, [ref]$n) -and $n -ge 0 -and $n -le 50) { $state.maxClients = $n }
    $n = 0; if ([int]::TryParse("" + $s.rbxQuality, [ref]$n) -and $n -ge 0 -and $n -le 10) { $state.rbxQuality = $n }
    $n = 0; if ([int]::TryParse("" + $s.rbxFps, [ref]$n) -and @(0, 30, 60, 144, 240, -1) -contains $n) { $state.rbxFps = $n }
    foreach ($p in "winWidth","winHeight") { $n = 0; if ([int]::TryParse("" + $s.$p, [ref]$n) -and $n -ge 0 -and $n -le 20000) { $state.$p = $n } }
    $state.afkOff = @(@($s.afkOff) | Where-Object { ("" + $_).Trim() } | ForEach-Object { ("" + $_).Trim().ToLower() } | Select-Object -Unique)
    foreach ($p in "launchTimeout","launchSettle","mainSettle","afkMinutes") {
        $n = 0
        if ($null -ne $s.$p -and [int]::TryParse("" + $s.$p, [ref]$n) -and $n -gt 0) { $state.$p = $n }
    }
    foreach ($p in "autoJoin","rejoinSameServer","alertSound","autoRejoin","autoMuteAlts","trayOnMinimize","afkSkipActive","afkJitter","discCheck","lowPower","ecoAlts","webhookOnDone","schedOn","afkOn","winMax","animations","rbxAuto") {
        if ($null -ne $s.$p) { $state.$p = [bool]$s.$p }
    }
    $secs = @{}
    if ($s.statsSecs) { foreach ($q in $s.statsSecs.PSObject.Properties) { $d = 0.0; if ([double]::TryParse("" + $q.Value, [ref]$d)) { $secs[$q.Name] = $d } } }
    $state.statsSecs = $secs
    $acts = @($s.afkActions | Where-Object { @("jump","walk","zoom","click") -contains $_ } | ForEach-Object { "" + $_ })
    if ($acts.Count -gt 0) { $state.afkActions = $acts }
    $spots = @{}
    if ($s.clickSpots) { foreach ($q in $s.clickSpots.PSObject.Properties) { $spots[$q.Name] = "" + $q.Value } }
    $state.clickSpots = $spots
    $snd = @{}
    if ($s.soundOff) { foreach ($q in $s.soundOff.PSObject.Properties) { $snd[$q.Name.ToLower()] = [bool]$q.Value } }
    $state.soundOff = $snd
    $p = New-PlanDefaults
    if ($s.plan) {
        $steps = @()
        foreach ($st in @($s.plan.steps)) {
            if (-not $st) { continue }
            if (-not @($grps | Where-Object { $_.id -eq ("" + $st.groupId) }).Count) { $warn += "A schedule step's group no longer exists, so the step was removed."; continue }
            $m = 60; [void][int]::TryParse("" + $st.minutes, [ref]$m)
            $steps += [pscustomobject]@{ groupId = "" + $st.groupId; minutes = [Math]::Max(1, [Math]::Min(1440, $m)) }
        }
        $p.steps = $steps
        foreach ($k in @(@("cooldownMin", 0, 240), @("maxTotalMin", 0, 10080), @("retries", 0, 3))) {
            $n = 0; if ([int]::TryParse("" + $s.plan.($k[0]), [ref]$n) -and $n -ge $k[1] -and $n -le $k[2]) { $p.($k[0]) = $n }
        }
        if (@("close", "keep") -contains ("" + $s.plan.whenTimeUp)) { $p.whenTimeUp = "" + $s.plan.whenTimeUp }
        if (@("next", "wait", "stop") -contains ("" + $s.plan.then)) { $p.then = "" + $s.plan.then }
        if (@("skip", "stop") -contains ("" + $s.plan.onFailure)) { $p.onFailure = "" + $s.plan.onFailure }
        foreach ($k in "loop", "followMain") { if ($null -ne $s.plan.$k) { $p.$k = [bool]$s.plan.$k } }
    }
    $state.plan = $p
    $state.planRun = $s.planRun   # turned back into a (paused) run by ConvertFrom-SavedRun
    $state.planHistory = @(@($s.planHistory) | Where-Object { $_ } | Select-Object -Last 100 | ForEach-Object { [pscustomobject]@{ at = "" + $_.at; text = "" + $_.text } })
    return @{ State = $state; Warnings = $warn }
}

function Read-SettingsFile([string]$path) {
    # Returns @{ Ok; State; Warnings; Error; Source = "main" | "backup" | "new" }.
    # A file that exists but can't be read is NEVER treated as "no accounts":
    # it falls back to the .bak copy, or returns Ok = $false so the app won't save over it.
    $bak = "$path.bak"
    if (-not (Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $bak)) {
        return @{ Ok = $true; State = (New-Defaults); Warnings = @(); Error = ""; Source = "new" }
    }
    $err = $(if (Test-Path -LiteralPath $path) { "" } else { "it is missing" })
    foreach ($src in @(@{ P = $path; S = "main" }, @{ P = $bak; S = "backup" })) {
        if (-not (Test-Path -LiteralPath $src.P)) { continue }
        try {
            $s = [IO.File]::ReadAllText($src.P) | ConvertFrom-Json
            if ($s -isnot [System.Management.Automation.PSCustomObject]) { throw "it isn't a settings file" }
            $c = ConvertTo-State $s
            $w = @($c.Warnings)
            if ($src.S -eq "backup") { $w = @("settings.json couldn't be read ($err). Loaded the backup copy (settings.json.bak) instead.") + $w }
            return @{ Ok = $true; State = $c.State; Warnings = $w; Error = ""; Source = $src.S }
        } catch {
            if (-not $err) { $err = $_.Exception.Message }
        }
    }
    return @{ Ok = $false; State = $null; Warnings = @(); Error = $err; Source = "" }
}

function Move-NickKey($table, [string]$old, [string]$new) {
    # clickSpots and statsSecs are keyed by lower-case nickname.
    $o = $old.ToLower(); $n = $new.ToLower()
    if ($o -eq $n -or -not $table.ContainsKey($o)) { return }
    $table[$n] = $table[$o]; $table.Remove($o)
}

function Set-AccountNick($state, $acc, [string]$nick) {
    # Renames an account everywhere it is referred to by name.
    $old = $acc.nick
    foreach ($g in @($state.groups)) {
        $g.nicks = @(foreach ($n in @($g.nicks)) { if ($n -ieq $old) { $nick } else { $n } })
    }
    Move-NickKey $state.clickSpots $old $nick
    Move-NickKey $state.statsSecs $old $nick
    Move-NickKey $state.soundOff $old $nick
    $state.afkOff = @(foreach ($n in @($state.afkOff)) { if ($n -eq $old.ToLower()) { $nick.ToLower() } else { $n } })
    $acc.nick = $nick
}

function Get-DefaultNick($state) {
    # What the "Add account" box starts with: Main for the first account, then Alt1, Alt2, ...
    if (@($state.accounts).Count -eq 0) { return "Main" }
    $n = 1; while (@($state.accounts | Where-Object { $_.nick -ieq "Alt$n" }).Count) { $n++ }
    return "Alt$n"
}

function Get-AccountMuted($state, $acc) {
    # Should this account's new Roblox window start muted? The main always starts with sound
    # (it's the one you play). Others keep their own Mute button, or follow "Mute alts".
    if ($acc.isMain) { return $false }
    $k = $acc.nick.ToLower()
    if ($state.soundOff.ContainsKey($k)) { return [bool]$state.soundOff[$k] }
    return [bool]$state.autoMuteAlts
}

function Get-ScreenOrder($wins, $accounts) {
    # Screens follow the accounts: the main first, then the others in the account list's order,
    # then windows not linked to an account (in their old order). Two windows of one account:
    # the older first. Returns the windows in that order.
    $rank = @{}; $i = 0
    foreach ($a in @(@($accounts | Where-Object { $_.isMain }) + @($accounts | Where-Object { -not $_.isMain }))) { $rank[$a.nick.ToLower()] = $i++ }
    $keyed = @(foreach ($w in @($wins)) {
        $k = $(if ($w.Nick -and $rank.ContainsKey($w.Nick.ToLower())) { $rank[$w.Nick.ToLower()] } else { 100000 + [int]$w.Num })
        [pscustomobject]@{ K = $k; T = $(if ($w.ProcStart) { $w.ProcStart.Ticks } else { [long]0 }); W = $w }
    })
    return @($keyed | Sort-Object K, T | ForEach-Object { $_.W })
}

function Get-AutoJoinSummary($state) {
    # all | none | some: is auto-click on for every account?
    $accs = @($state.accounts)
    $on = @($accs | Where-Object { $_.autoJoin }).Count
    if ($accs.Count -eq 0 -or $on -eq 0) { return "none" }
    if ($on -eq $accs.Count) { return "all" }
    return "some"
}
function Set-AutoJoinAll($state, [bool]$on) {
    foreach ($a in @($state.accounts)) { $a.autoJoin = $on }
    $state.autoJoin = $on   # what new accounts start with
}

# ----- groups -----
# A group is a named list of account nicknames, with a permanent id (schedules will refer to it).
function Get-Members($state, $nicks) {
    # Real accounts only, each once, in the order of the account list, with their own spelling.
    $want = @($nicks | ForEach-Object { ("" + $_).ToLower() })
    return @($state.accounts | Where-Object { $want -contains $_.nick.ToLower() } | ForEach-Object { $_.nick })
}
function Test-GroupName($state, [string]$name, $except) {
    # "" when the name can be used, otherwise why not.
    if (-not $name.Trim()) { return "Please type a name." }
    $taken = @($state.groups | Where-Object { $_.name -ieq $name.Trim() -and -not [object]::ReferenceEquals($_, $except) })
    if ($taken.Count) { return "There's already a group called '$($taken[0].name)'." }
    return ""
}
function New-Group($state, [string]$name, $nicks) {
    $err = Test-GroupName $state $name $null
    if ($err) { return @{ Group = $null; Error = $err } }
    $g = [pscustomobject]@{ id = [guid]::NewGuid().ToString(); name = $name.Trim(); nicks = @(Get-Members $state $nicks) }
    $state.groups = @($state.groups) + $g
    return @{ Group = $g; Error = "" }
}
function Rename-Group($state, $group, [string]$name) {
    $err = Test-GroupName $state $name $group
    if (-not $err) { $group.name = $name.Trim() }
    return $err
}
function Copy-Group($state, $group) {
    $name = "$($group.name) (copy)"; $i = 2
    while (Test-GroupName $state $name $null) { $name = "$($group.name) (copy $i)"; $i++ }
    return (New-Group $state $name @($group.nicks)).Group
}
function Set-GroupMembers($state, $group, $nicks) { $group.nicks = @(Get-Members $state $nicks) }
function Remove-GroupMember($group, [string]$nick) { $group.nicks = @($group.nicks | Where-Object { $_ -ine $nick }) }
function Remove-Group($state, $group) { $state.groups = @($state.groups | Where-Object { -not [object]::ReferenceEquals($_, $group) }) }
function Move-Group($state, $group, [int]$dir) {
    $list = [System.Collections.ArrayList]@($state.groups)
    $i = $list.IndexOf($group); $j = $i + $dir
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $list.Count) { return }
    $list[$i] = $list[$j]; $list[$j] = $group
    $state.groups = @($list)
}
function Get-GroupSummary($group, $accounts, $info, [bool]$opening) {
    # $info: lower-case nick -> @{ Running; Ready; Groups } from the app's live view.
    # Status: Draft (no members) | Opening | Running (all open) | Needs setup | Partly open | Ready
    $members = @($accounts | Where-Object { @($group.nicks) -icontains $_.nick })
    $running = @($members | Where-Object { $info[$_.nick.ToLower()].Running }).Count
    $notReady = @($members | Where-Object { -not $info[$_.nick.ToLower()].Ready -and -not $info[$_.nick.ToLower()].Running }).Count
    $status = $(if ($members.Count -eq 0) { "Draft" } elseif ($opening) { "Opening" } elseif ($running -eq $members.Count) { "Running" }
                elseif ($notReady) { "Needs setup" } elseif ($running) { "Partly open" } else { "Ready" })
    return @{ Members = $members.Count; HasMain = [bool]@($members | Where-Object { $_.isMain }).Count; Running = $running; NotReady = $notReady; Status = $status }
}
function Select-Accounts($accounts, [string]$query, [string]$filter, $info) {
    # Search by nickname, plus one filter: all | main | alt | running | offline | assigned | unassigned
    $q = $query.Trim()
    return @($accounts | Where-Object {
        $a = $_; $i = $info[$a.nick.ToLower()]
        (-not $q -or $a.nick -like "*$q*") -and $(switch ($filter) {
            "main" { $a.isMain } "alt" { -not $a.isMain }
            "running" { [bool]$i.Running } "offline" { -not $i.Running }
            "assigned" { @($i.Groups).Count -gt 0 } "unassigned" { @($i.Groups).Count -eq 0 }
            default { $true } })
    })
}

function Remove-AccountRecord($state, $acc) {
    # Removes the account from the list and from every group. Its Chrome profile stays.
    $state.accounts = @($state.accounts | Where-Object { -not [object]::ReferenceEquals($_, $acc) })
    foreach ($g in @($state.groups)) { $g.nicks = @($g.nicks | Where-Object { $_ -ine $acc.nick }) }
    $state.clickSpots.Remove($acc.nick.ToLower())
    $state.soundOff.Remove($acc.nick.ToLower())
    $state.afkOff = @($state.afkOff | Where-Object { $_ -ne $acc.nick.ToLower() })
}

function New-BackupObject($state, $profileNames) {
    # What "Save backup file" writes: accounts, groups, saved links and settings.
    # Leaves out the Discord webhook (anyone with that link can post to your channel).
    # profileNames: Chrome profile folder -> its name in Chrome, so a restore can
    # tell whether a folder with the same name on another PC is the same person.
    $out = [pscustomobject]@{ backupFormat = "RobloxManager-config"; backupVersion = 2; exportedAt = (Get-Date).ToString("s") }
    foreach ($p in $state.PSObject.Properties) {
        if ($p.Name -eq "webhook") { continue }
        $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
    }
    $out.accounts = @(foreach ($a in @($state.accounts)) {
        $c = $a.PSObject.Copy()
        $c | Add-Member -NotePropertyName profileName -NotePropertyValue ("" + $profileNames[$a.profileDir]) -Force
        $c
    })
    $out.favorites = @($state.favorites); $out.groups = @($state.groups)
    return $out
}

function Read-BackupFile([string]$path, $current, [string]$chromeData, $profileNames) {
    # Checks a backup before it replaces anything. Returns @{ Ok; State; Warnings; Error; NeedSignIn }.
    # Chrome keeps the logins, not the backup: an account whose Chrome profile isn't on
    # this PC gets a fresh profile and is marked "needs sign-in".
    try { $s = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return @{ Ok = $false; Error = "The file couldn't be read: $($_.Exception.Message)" } }
    if ($s -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $s.PSObject.Properties["accounts"]) {
        return @{ Ok = $false; Error = "That file isn't a BloxKit backup." }
    }
    $c = ConvertTo-State $s
    $state = $c.State; $warn = @($c.Warnings); $need = @()
    if ($current.webhook) { $state.webhook = $current.webhook }   # backups don't carry it; keep this PC's
    $taken = @{}
    foreach ($a in @($state.accounts)) {
        if (-not $a.profileDir) {
            $base = "RobloxLauncher_" + (Get-SafeName $a.nick); $dir = $base; $i = 2
            while ($taken.ContainsKey($dir.ToLower()) -or (Test-Path -LiteralPath (Join-Path $chromeData $dir)) -or @($state.accounts | Where-Object { $_.profileDir -eq $dir }).Count) { $dir = "$base$i"; $i++ }
            $a.profileDir = $dir
        }
        $taken[$a.profileDir.ToLower()] = $true
        $saved = @($s.accounts | Where-Object { $_ -and ("" + $_.nick).Trim() -ieq $a.nick }) | Select-Object -First 1
        $savedName = $(if ($saved) { "" + $saved.profileName } else { "" })
        if (-not (Test-Path -LiteralPath (Join-Path $chromeData $a.profileDir))) {
            $a.needsLogin = $true
        } elseif ($savedName -and $profileNames[$a.profileDir] -and $profileNames[$a.profileDir] -ne $savedName) {
            $warn += "$($a.nick): the Chrome profile '$($a.profileDir)' on this PC is called '$($profileNames[$a.profileDir])', but in the backup it was '$savedName'. It may be someone else's. Check it before opening."
        }
        if ($a.needsLogin) { $need += $a.nick }
    }
    return @{ Ok = $true; State = $state; Warnings = $warn; Error = ""; NeedSignIn = $need }
}

function Write-SettingsFile($state, [string]$path) {
    # Writes to a temporary file first, then swaps it in and keeps the previous
    # version as .bak, so a crash or full disk can never leave a half-written file.
    # Returns "" when saved, or the reason it couldn't save.
    $out = [pscustomobject]@{}
    foreach ($p in $state.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    $out.accounts = @($state.accounts); $out.favorites = @($state.favorites); $out.groups = @($state.groups)
    $tmp = "$path.tmp"
    try {
        $json = $out | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $true))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, "$path.bak") }
        else { [IO.File]::Move($tmp, $path) }
        return ""
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $_.Exception.Message
    }
}

# ------------------------------------------------------------ roblox logs --
# Each Roblox window writes its own log. These lines say what it is doing.
$DiscReasons = @{
    "267" = "kicked by the game"; "268" = "kicked for unexpected client behavior"
    "273" = "this account joined from somewhere else"; "277" = "lost connection"
    "278" = "kicked for being idle 20 minutes"; "279" = "couldn't connect to the server"
    "288" = "the server shut down"
}

function Read-LogEvent([string]$line) {
    # One log line -> @{ Kind = join | connected | teleport | kickmsg | left | disc; ... } or $null.
    if ($line -match "! Joining game '([0-9a-fA-F-]{36})' place (\d+)") { return @{ Kind = "join"; Job = $Matches[1]; Place = $Matches[2] } }
    if ($line -match '\[FLog::SingleSurfaceApp\] initializeSingleton') {
        # Start of a launch in this window. With multi-window off, Roblox hands a new launch to
        # the window that's already open (the new process quits): then it appears mid-log.
        $at = [DateTime]::MinValue
        if ($line -match '^(\d{4}-\d\d-\d\dT[\d:.]+Z)') { $at = [DateTime]::Parse($Matches[1], $null, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() }
        return @{ Kind = "handoff"; At = $at }
    }
    if ($line -match 'Connection accepted from |Replicator created for player ') { return @{ Kind = "connected" } }
    if ($line -match '\] Teleported\.') { return @{ Kind = "teleport" } }
    if ($line -match 'Server Kick Message:\s*(.*?)\s*(;\s*Metadata:.*)?$') { return @{ Kind = "kickmsg"; Text = $Matches[1] } }
    if ($line -match '(Disconnected from server|Connection closed by server) for reason:\s*(.+)$' -or
        $line -match '(Lost connection|Client has been disconnected) with reason\s*:?\s*(.+)$') {
        $reason = $Matches[2].Trim()
        $code = $(if ($reason -match '\b(2\d\d)\b') { $Matches[1] } else { "" })
        if ($code -eq "285") { return @{ Kind = "left" } }   # the player left on purpose
        if (-not $code -and $reason -match 'joined from another device') { $code = "273" }
        $text = $(if ($DiscReasons[$code]) { "$($DiscReasons[$code]) ($code)" } elseif ($code) { "Roblox error $code" } else { "lost connection" })
        return @{ Kind = "disc"; Code = $code; Text = $text }
    }
    return $null
}

function New-Session([DateTime]$now) {
    # What one Roblox window is doing, according to its log.
    # loading -> joining (join line) -> connected (server accepted it) -> disconnected | left
    @{ State = "loading"; Job = ""; Place = ""; Reason = ""; KickMsg = ""; ChangedAt = $now }
}

function Update-Session($s, $e, [DateTime]$now) {
    # Applies one log event. Returns $true when the state changed.
    $before = $s.State
    switch ($e.Kind) {
        "join"      { $s.State = "joining"; $s.Job = $e.Job; $s.Place = $e.Place; $s.Reason = ""; $s.KickMsg = "" }
        "handoff"   { $s.State = "loading"; $s.Reason = ""; $s.KickMsg = "" }   # a new launch starts in this window
        "teleport"  { $s.State = "joining"; $s.Reason = "" }
        "connected" { if ($s.State -eq "joining") { $s.State = "connected" } }   # a process alone is never "connected"
        "left"      { $s.State = "left" }
        "kickmsg"   {
            $s.KickMsg = $e.Text
            if ($s.State -eq "disconnected") { $s.Reason = "kicked by the game: $($e.Text)" }
        }
        "disc"      {
            $s.State = "disconnected"
            $s.Reason = $(if ($s.KickMsg) { "kicked by the game: $($s.KickMsg)" } else { $e.Text })
        }
    }
    if ($s.State -ne $before) { $s.ChangedAt = $now; return $true }
    return $false
}

function Get-ClientState($s, [bool]$logFound, [bool]$gaveUp) {
    # The one place that says what a Roblox window is doing.
    # loading | joining | connected | disconnected | left | unknown (no log to tell)
    if (-not $logFound) { return $(if ($gaveUp) { "unknown" } else { "loading" }) }
    return $s.State
}

# ---------------------------------------------------------------- launches --
function Select-LaunchForWindow([DateTime]$procStart, $ops, [int]$maxAgeSec) {
    # Launches go one at a time, so a new Roblox window belongs to the latest launch
    # that started before its process did. If that launch already has a window, or is
    # too old, the window was opened some other way and belongs to none.
    $best = $null
    foreach ($op in @($ops)) {
        if ($op.Start -le $procStart -and (-not $best -or $op.Start -gt $best.Start)) { $best = $op }
    }
    if (-not $best -or $best.Hwnd -ne 0 -or $best.Cancelled) { return $null }   # cancelled: it may be a window you opened yourself
    if (($procStart - $best.Start).TotalSeconds -gt $maxAgeSec) { return $null }
    return $best
}

# ---------------------------------------------------------------- servers --
# "Spread out": pick public servers (the list Roblox's own game page shows, from
# games.roblox.com/v1/games/{placeId}/servers/Public) and join them with the helper's
# joinGameInstance, like clicking "Join" on that list. A server can fill up before an
# account gets there, so where it really landed is checked in its Roblox log.
function Select-Servers($servers, [int]$count, [int]$perServer, $already) {
    # -> @{ Jobs = one server id per account (as many as fit); Short = how many didn't fit }
    # $already: server id -> how many of your accounts are on it now (they count toward the limit)
    $jobs = @()
    foreach ($s in @($servers | Where-Object { $_.id } | Sort-Object { [int]$_.playing })) {
        if ($jobs.Count -ge $count) { break }
        $free = [int]$s.maxPlayers - [int]$s.playing
        $room = [Math]::Min($free, $perServer - [int]$already[$s.id])
        for ($i = 0; $i -lt $room -and $jobs.Count -lt $count; $i++) { $jobs += $s.id }
    }
    return @{ Jobs = $jobs; Short = $count - $jobs.Count }
}
function Get-ServerCheck([string]$planned, [string]$actual) {
    # "" (no server was planned) | pending (not joined yet) | confirmed | elsewhere
    if (-not $planned) { return "" }
    if (-not $actual) { return "pending" }
    return $(if ($planned -ieq $actual) { "confirmed" } else { "elsewhere" })
}

# ------------------------------------------------------------------- load --
# CPU, memory and GPU use of the Roblox clients, measured the way Task Manager does.
function Get-CpuShare([double]$cpuMs0, [double]$cpuMs1, [double]$elapsedMs, [int]$threads) {
    # Share of the whole CPU (all threads) a program used between two readings, in %.
    if ($elapsedMs -le 0 -or $threads -le 0) { return 0 }
    return [Math]::Max([double]0, ($cpuMs1 - $cpuMs0) / $elapsedMs / $threads * 100)   # [double]0: Max(0, x) would round x to a whole number
}
function Measure-GpuUsage($old, $new) {
    # $old/$new: "GPU Engine" counter instance -> @{ Raw = busy time; Time = clock } (both 100 ns).
    # -> @{ ByPid = pid -> @{ Pct; Luid }; ByAdapter = luid -> % } or $null when there are no counters.
    # Like Task Manager, a program's GPU % is its busiest engine type (3D, video, copy...).
    if ($null -eq $old -or $null -eq $new) { return $null }
    $eng = @{}; $engLuid = @{}; $ad = @{}
    foreach ($k in @($new.Keys)) {
        if (-not $old.ContainsKey($k)) { continue }   # started between the readings: no guessing
        if ($k -notmatch '^pid_(\d+)_luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)_phys_\d+_eng_\d+_engtype_(.+)$') { continue }
        $procId = $Matches[1]; $luid = $Matches[2].ToLower(); $type = $Matches[3]   # DXGI names use lower case
        $dt = [double]($new[$k].Time - $old[$k].Time)
        if ($dt -le 0) { continue }
        $pct = [Math]::Max([double]0, ($new[$k].Raw - $old[$k].Raw) / $dt * 100)
        $eng["$procId|$type"] = [double]$eng["$procId|$type"] + $pct; $engLuid["$procId|$type"] = $luid
        $ad["$luid|$type"] = [double]$ad["$luid|$type"] + $pct
    }
    $byPid = @{}
    foreach ($k in $eng.Keys) {
        $procId = $k.Split("|")[0]
        if (-not $byPid.ContainsKey($procId) -or $eng[$k] -gt $byPid[$procId].Pct) { $byPid[$procId] = @{ Pct = $eng[$k]; Luid = $engLuid[$k] } }
    }
    $byAd = @{}
    foreach ($k in $ad.Keys) { $luid = $k.Split("|")[0]; if ($ad[$k] -gt [double]$byAd[$luid]) { $byAd[$luid] = $ad[$k] } }
    return @{ ByPid = $byPid; ByAdapter = $byAd }
}

function Read-GpuEngines {
    # Windows' "GPU Engine" counters right now: instance -> @{ Raw; Time }, or $null if Windows has none.
    try {
        $data = (New-Object System.Diagnostics.PerformanceCounterCategory "GPU Engine").ReadCategory()
        $col = $data["Utilization Percentage"]
        if (-not $col) { return $null }
        $out = @{}
        foreach ($i in $col.Values) { $out[$i.InstanceName] = @{ Raw = $i.Sample.RawValue; Time = $i.Sample.TimeStamp100nSec } }
        return $out
    } catch { return $null }
}
# C# helpers for the load readings. Kept here so they can also be compiled on a background
# thread when the app starts (Start-LoadWarmUp), instead of freezing the window later.
$RbxGpuSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RbxAdapterDesc1 {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    public uint VendorId, DeviceId, SubSysId, Revision;
    public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    public uint LuidLow; public int LuidHigh; public uint Flags;
}
[ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IRbxAdapter1 {
    void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();   // IDXGIObject
    void EnumOutputs(); void GetDesc(); void CheckInterfaceSupport();                                  // IDXGIAdapter
    [PreserveSig] int GetDesc1(out RbxAdapterDesc1 d);                                                 // IDXGIAdapter1
}
[ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IRbxFactory1 {
    void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();   // IDXGIObject
    void EnumAdapters(); void MakeWindowAssociation(); void GetWindowAssociation(); void CreateSwapChain(); void CreateSoftwareAdapter();
    [PreserveSig] int EnumAdapters1(uint i, out IRbxAdapter1 a);                                       // IDXGIFactory1
}
public static class RbxGpu {
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IRbxFactory1 f);
    // "0xHHHHHHHH_0xLLLLLLLL|Name|dedicated MB|flags" (flags 2 = software adapter)
    public static string[] Adapters() {
        List<string> list = new List<string>();
        Guid g = typeof(IRbxFactory1).GUID;
        IRbxFactory1 f;
        if (CreateDXGIFactory1(ref g, out f) != 0 || f == null) return list.ToArray();
        for (uint i = 0; i < 16; i++) {
            IRbxAdapter1 a;
            if (f.EnumAdapters1(i, out a) != 0 || a == null) break;
            RbxAdapterDesc1 d;
            if (a.GetDesc1(out d) == 0)
                list.Add(String.Format("0x{0:x8}_0x{1:x8}|{2}|{3}|{4}", d.LuidHigh, d.LuidLow, d.Description, (ulong)d.DedicatedVideoMemory / 1048576UL, d.Flags));
            Marshal.ReleaseComObject(a);
        }
        Marshal.ReleaseComObject(f);
        return list.ToArray();
    }
}
'@
$RbxSysSource = @'
using System; using System.Runtime.InteropServices;
public static class RbxSys {
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    public static long[] Times() { long i, k, u; if (!GetSystemTimes(out i, out k, out u)) return null; return new long[] { i, k, u }; }
    [StructLayout(LayoutKind.Sequential)] struct MEMSTATUS { public uint Length, Load; public ulong TotalPhys, AvailPhys, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExtended; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMSTATUS m);
    // total and available memory in MB (fast; no WMI)
    public static ulong[] Memory() { MEMSTATUS m = new MEMSTATUS(); m.Length = (uint)Marshal.SizeOf(typeof(MEMSTATUS)); if (!GlobalMemoryStatusEx(ref m)) return null; return new ulong[] { m.TotalPhys / 1048576UL, m.AvailPhys / 1048576UL }; }
}
'@

function Get-GpuAdapters {
    # Graphics chips: luid (as in the GPU counters) -> @{ Name; VramMB }. Asks DirectX (DXGI).
    if (-not ("RbxGpu" -as [type])) {
        Add-Type -TypeDefinition $RbxGpuSource -ErrorAction Stop
    }
    $out = @{}
    try { foreach ($l in [RbxGpu]::Adapters()) { $p = $l.Split("|"); if ([int]$p[3] -band 2) { continue }; $out[$p[0]] = @{ Name = $p[1]; VramMB = [long]$p[2] } } } catch {}
    return $out
}

function Compare-LoadReadings($a, $b) {
    # Two readings (Get-LoadReading) -> what happened in between:
    # Clients (per Roblox process: CpuPct, MemMB, GpuPct, Luid), Chrome, Manager, CpuTotalPct,
    # RamFreeGB, RamTotalGB, PagesPerSec, GpuByAdapter (luid -> BusyPct, RobloxCount).
    # Anything Windows didn't give is $null ("not available"), never 0.
    $ms = $b.Ms - $a.Ms
    $gpu = Measure-GpuUsage $a.Gpu $b.Gpu
    $clients = @(); $chrome = @{ Count = 0; CpuPct = 0.0; MemMB = 0 }; $manager = $null
    foreach ($k in @($b.Procs.Keys)) {
        $p = $b.Procs[$k]; $o = $a.Procs[$k]
        $cpu = $(if ($o) { Get-CpuShare $o.CpuMs $p.CpuMs $ms $b.Threads } else { $null })
        switch ($p.Kind) {
            "roblox" {
                $g = $(if ($gpu) { $gpu.ByPid["$k"] } else { $null })
                $clients += @{ Pid = [int]$k; CpuPct = $cpu; MemMB = $p.MemMB; GpuPct = $(if ($gpu) { $(if ($g) { $g.Pct } else { 0.0 }) } else { $null }); Luid = $(if ($g) { $g.Luid } else { "" }) }
            }
            "chrome"  { $chrome.Count++; $chrome.MemMB += $p.MemMB; if ($null -ne $cpu) { $chrome.CpuPct += $cpu } }
            "manager" { $manager = @{ CpuPct = $cpu; MemMB = $p.MemMB } }
        }
    }
    $busy = $null
    if ($a.Sys -and $b.Sys) {
        $idle = $b.Sys.Idle - $a.Sys.Idle; $total = ($b.Sys.Kernel - $a.Sys.Kernel) + ($b.Sys.User - $a.Sys.User)   # kernel time includes idle
        if ($total -gt 0) { $busy = [Math]::Max([double]0, ($total - $idle) / $total * 100) }
    }
    $byAd = $null
    if ($gpu) {
        $byAd = @{}
        foreach ($l in $gpu.ByAdapter.Keys) { $byAd[$l] = @{ BusyPct = $gpu.ByAdapter[$l]; RobloxCount = @($clients | Where-Object { $_.Luid -eq $l }).Count } }
    }
    return @{
        Seconds = $ms / 1000; Clients = @($clients | Sort-Object { $_.Pid }); Chrome = $chrome; Manager = $manager; CpuTotalPct = $busy
        RamTotalGB = $b.RamTotalMB / 1024; RamFreeGB = $(if ($null -ne $b.RamFreeMB) { $b.RamFreeMB / 1024 } else { $null })
        PagesPerSec = $(if ($null -ne $a.PagesRaw -and $null -ne $b.PagesRaw -and $ms -gt 0) { ($b.PagesRaw - $a.PagesRaw) / ($ms / 1000) } else { $null })
        GpuByAdapter = $byAd
    }
}
function Get-LoadReading([int]$managerPid = 0) {
    # One reading of everything Compare-LoadReadings needs. Reading only; changes nothing.
    if (-not ("RbxSys" -as [type])) {
        Add-Type -TypeDefinition $RbxSysSource -ErrorAction Stop
    }
    $r = @{ Ms = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency; Threads = [Environment]::ProcessorCount; Procs = @{} }
    $t = [RbxSys]::Times(); $r.Sys = $(if ($t) { @{ Idle = $t[0]; Kernel = $t[1]; User = $t[2] } } else { $null })
    $mem = [RbxSys]::Memory()
    if ($mem) { $r.RamTotalMB = [double]$mem[0]; $r.RamFreeMB = [double]$mem[1] } else { $r.RamTotalMB = 0; $r.RamFreeMB = $null }
    try { $r.PagesRaw = @((New-Object System.Diagnostics.PerformanceCounterCategory "Memory").ReadCategory()["Pages/sec"].Values)[0].Sample.RawValue } catch { $r.PagesRaw = $null }
    $r.Gpu = Read-GpuEngines
    foreach ($n in @(@("RobloxPlayerBeta", "roblox"), @("chrome", "chrome"))) {
        foreach ($p in @(Get-Process -Name $n[0] -ErrorAction SilentlyContinue)) {
            try { $r.Procs[$p.Id] = @{ Kind = $n[1]; CpuMs = $p.TotalProcessorTime.TotalMilliseconds; MemMB = [int]($p.WorkingSet64 / 1MB) } } catch {}
        }
    }
    if ($managerPid) { try { $p = Get-Process -Id $managerPid -ErrorAction Stop; $r.Procs[$p.Id] = @{ Kind = "manager"; CpuMs = $p.TotalProcessorTime.TotalMilliseconds; MemMB = [int]($p.WorkingSet64 / 1MB) } } catch {} }
    return $r
}

function Test-IntegratedGpu($a) {
    # Built-in graphics: little memory of its own, or a name like Intel UHD / Iris, AMD Radeon(TM) Graphics.
    return ($a.VramMB -gt 0 -and $a.VramMB -le 1024) -or ($a.Name -match 'Intel\(R\) (UHD|Iris|HD) Graphics|^AMD Radeon\(TM\) Graphics$|^AMD Radeon Graphics$')
}
function ConvertTo-LoadFacts($comparisons, $adapters, $graphics, [bool]$onBattery) {
    # Several Compare-LoadReadings results -> @{ Facts (for Get-LoadFindings); Clients (per-client averages) }.
    # Averages for steady use (CPU, GPU); the worst moment for memory (lowest free, most swapping).
    $cs = @($comparisons | Where-Object { $_ })
    $avg = { param($vals) $v = @($vals | Where-Object { $null -ne $_ }); if ($v.Count) { ($v | Measure-Object -Average).Average } else { $null } }
    $perPid = @{}
    foreach ($c in $cs) { foreach ($x in $c.Clients) { if (-not $perPid.ContainsKey($x.Pid)) { $perPid[$x.Pid] = @() }; $perPid[$x.Pid] += $x } }
    $clients = @(foreach ($k in ($perPid.Keys | Sort-Object)) {
        $xs = $perPid[$k]; $luid = @($xs | Where-Object { $_.Luid } | ForEach-Object { $_.Luid })[-1]
        @{ Pid = $k; CpuPct = & $avg ($xs | ForEach-Object { $_.CpuPct }); MemMB = ($xs[-1]).MemMB; GpuPct = & $avg ($xs | ForEach-Object { $_.GpuPct })
           Adapter = $(if ($luid -and $adapters[$luid]) { $adapters[$luid].Name } elseif ($luid) { $luid } else { "" }) }
    })
    $ads = @()
    $luids = @($cs | Where-Object { $_.GpuByAdapter } | ForEach-Object { $_.GpuByAdapter.Keys } | Select-Object -Unique)
    foreach ($l in $luids) {
        $a = $(if ($adapters[$l]) { $adapters[$l] } else { @{ Name = $l; VramMB = 0 } })
        $ads += @{ Name = $a.Name; Integrated = (Test-IntegratedGpu $a)
                   BusyPct = & $avg ($cs | Where-Object { $_.GpuByAdapter -and $_.GpuByAdapter[$l] } | ForEach-Object { $_.GpuByAdapter[$l].BusyPct })
                   RobloxCount = (@($cs | Where-Object { $_.GpuByAdapter -and $_.GpuByAdapter[$l] } | ForEach-Object { $_.GpuByAdapter[$l].RobloxCount }) | Measure-Object -Maximum).Maximum }
    }
    $facts = @{
        Clients = $(if ($cs.Count) { ($cs | ForEach-Object { @($_.Clients).Count } | Measure-Object -Maximum).Maximum } else { 0 })
        CpuTotalPct = & $avg ($cs | ForEach-Object { $_.CpuTotalPct })
        RamTotalGB = $(if ($cs.Count) { $cs[-1].RamTotalGB } else { 0 })
        RamFreeGB = $(@($cs | Where-Object { $null -ne $_.RamFreeGB } | ForEach-Object { $_.RamFreeGB }) | Measure-Object -Minimum).Minimum
        PagesPerSec = $(@($cs | Where-Object { $null -ne $_.PagesPerSec } | ForEach-Object { $_.PagesPerSec }) | Measure-Object -Maximum).Maximum
        ManagerCpuPct = & $avg ($cs | Where-Object { $_.Manager } | ForEach-Object { $_.Manager.CpuPct })
        Adapters = $(if ($luids.Count) { $ads } else { $null })
        Quality = $graphics.Quality; FpsCap = $graphics.FpsCap; OnBattery = $onBattery
    }
    return @{ Facts = $facts; Clients = $clients }
}

function Get-StateFindings($x) {
    # Advice from what the app itself knows (not measurements). Nav = the tab that fixes it.
    # $x: MultiWindowOff; RobloxRunning; NeedSignIn; SetupIssue; LimitBlocked (nicknames); MaxClients
    $out = @()
    if ($x.MultiWindowOff -and $x.RobloxRunning -gt 0) {
        $out += @{ Severity = "high"; Title = "Multi-window is off"; Nav = ""
                   Seen = "Roblox was already running when BloxKit started ($($x.RobloxRunning) Roblox program(s) running now)."
                   Why = "New accounts take over the open Roblox window instead of getting their own."
                   Fix = "Close all Roblox (the orange 'Close Roblox and turn on' button at the top right). It turns on by itself once none are left." }
    }
    if (@($x.SharedProfile | Where-Object { $_ }).Count) {   # @($null).Count is 1: count real entries only
        $out += @{ Severity = "high"; Title = "Two accounts use the same Chrome profile"; Nav = "accounts"
                   Seen = "Same Chrome profile: " + (@($x.SharedProfile) -join "; ") + "."
                   Why = "They share one Roblox login, so they open as the same account."
                   Fix = "Remove one of them and add it again with 'A new Chrome profile' (Accounts tab)." }
    }
    if (@($x.NeedSignIn | Where-Object { $_ }).Count) {
        $out += @{ Severity = "medium"; Title = "$(@($x.NeedSignIn).Count) account(s) need to sign in"; Nav = "accounts"
                   Seen = "Not signed in on this PC: " + (@($x.NeedSignIn) -join ", ") + "."; Why = "They can't open Roblox until they sign in once."
                   Fix = "Click 'Sign in' on them (Accounts tab)." }
    }
    if (@($x.SetupIssue | Where-Object { $_ }).Count) {
        $out += @{ Severity = "medium"; Title = "Chrome setup isn't finished"; Nav = "settings"
                   Seen = "Needs something in Chrome: " + (@($x.SetupIssue) -join ", ") + "."; Why = "Auto-click, closing the launch tab or 'Always allow' won't work there yet."
                   Fix = "Settings > Chrome setup shows what's missing for each account." }
    }
    if (@($x.LimitBlocked | Where-Object { $_ }).Count) {
        $out += @{ Severity = "info"; Title = "Some accounts weren't opened (client limit)"; Nav = "settings"
                   Seen = "Not opened: " + (@($x.LimitBlocked) -join ", ") + ". The limit is $($x.MaxClients) Roblox windows at once."
                   Why = "The limit keeps the PC from being overloaded."; Fix = "Close a client, or raise the limit in Settings > Performance." }
    }
    return $out
}

function Get-LaunchAllowance([int]$open, [int]$queued, [int]$requested, [int]$max) {
    # How many more clients may be opened now. $max 0 = no limit.
    if ($max -le 0) { return $requested }
    return [Math]::Max(0, [Math]::Min($requested, $max - $open - $queued))
}

function Set-RobloxGraphics([string]$xml, [int]$quality, [int]$fpsCap) {
    # Roblox's settings file with a new graphics quality (1-10, manual) and frame rate cap
    # (30/60/144/240, or -1 = Roblox's default). Everything else stays exactly as it was.
    # Returns $null when the values aren't valid or the file doesn't have these settings.
    if ($quality -lt 1 -or $quality -gt 10 -or @(-1, 30, 60, 144, 240) -notcontains $fpsCap) { return $null }
    if ($xml -notmatch '<token name="SavedQualityLevel">-?\d+</token>' -or $xml -notmatch '<int name="FramerateCap">-?\d+</int>') { return $null }
    $out = $xml -replace '<token name="SavedQualityLevel">-?\d+</token>', "<token name=`"SavedQualityLevel`">$quality</token>"
    $out = $out -replace '<int name="FramerateCap">-?\d+</int>', "<int name=`"FramerateCap`">$fpsCap</int>"
    # Roblox also keeps the level on its own 1-21 scale; move it along so the two agree (10 -> 21, 1 -> 1).
    $internal = [int][Math]::Round(1 + ($quality - 1) * 20 / 9)
    $out = $out -replace '<int name="GraphicsQualityLevel">\d+</int>', "<int name=`"GraphicsQualityLevel`">$internal</int>"
    return $out
}

function Read-RobloxGraphics([string]$xml) {
    # Roblox's own settings file (GlobalBasicSettings_13.xml, shared by every client):
    # -> @{ Quality = 0 (Automatic) .. 10, or $null; FpsCap = -1 (Roblox's default) / 30 / 60 / ..., or $null }
    $q = $null; $f = $null
    if ($xml -match '<token name="SavedQualityLevel">(-?\d+)</token>') { $q = [int]$Matches[1] }
    if ($xml -match '<int name="FramerateCap">(-?\d+)</int>') { $f = [int]$Matches[1] }
    return @{ Quality = $q; FpsCap = $f }
}

function Get-LoadFindings($m) {
    # Measurements -> advice, most important first. Only from what was measured: a missing number
    # (no GPU counters, settings file not found) gives no advice about it, never a guess.
    # $m: Clients; CpuTotalPct; RamTotalGB; RamFreeGB; PagesPerSec; OnBattery; ManagerCpuPct;
    #     Adapters = @(@{ Name; Integrated; BusyPct; RobloxCount }); Quality; FpsCap
    $out = @()
    $script:FindingNo = 0   # rules run in order of importance; keep that order within a severity
    $add = { param($sev, $title, $seen, $why, $fix) $script:FindingNo++; @{ Severity = $sev; Title = $title; Seen = $seen; Why = $why; Fix = $fix; No = $script:FindingNo } }
    $ads = @($m.Adapters | Where-Object { $_ })
    $discrete = @($ads | Where-Object { -not $_.Integrated }) | Select-Object -First 1
    foreach ($a in @($ads | Where-Object { $_.Integrated -and $_.RobloxCount -gt 0 })) {
        if ($discrete) {
            $out += & $add "high" "Roblox runs on the built-in graphics" "$($a.RobloxCount) of $($m.Clients) clients use $($a.Name) instead of $($discrete.Name)." `
                "The built-in graphics is much slower and shares the computer's memory." `
                "Windows Settings > System > Display > Graphics: add RobloxPlayerBeta.exe (in %LOCALAPPDATA%\Roblox\Versions) and pick High performance ($($discrete.Name)). Roblox updates move that file, so check again after an update."
        }
    }
    foreach ($a in @($ads | Where-Object { $_.BusyPct -ge 90 -and $_.RobloxCount -gt 0 })) {
        $out += & $add "high" "The graphics chip is maxed out" "$($a.Name) was busy $([int]$a.BusyPct)% of the time with $($a.RobloxCount) client(s) on it." `
            "Every client draws its own picture; when the chip can't keep up, all windows stutter." `
            "Lower Roblox's graphics quality, cap the frame rate at 30, make alt windows small (Live screens > Low-power mode), or run fewer clients at once."
    }
    if ($null -ne $m.RamFreeGB -and $m.RamTotalGB -gt 0 -and ($m.RamFreeGB / $m.RamTotalGB) -lt 0.10) {
        $out += & $add "high" "Memory is full: Windows is swapping" (("{0:N1} GB free of {1:N0} GB" -f $m.RamFreeGB, $m.RamTotalGB) + $(if ($m.PagesPerSec) { ", {0:N0} memory pages moved to/from disk per second." -f $m.PagesPerSec } else { "." })) `
            "When memory runs out, Windows moves parts of programs to the disk and everything freezes for moments." `
            "Run fewer clients, close Chrome windows you don't need, and lower Roblox's graphics quality (it uses less memory)."
    } elseif ($m.PagesPerSec -ge 1000) {
        $out += & $add "medium" "Windows is swapping memory to disk" ("{0:N0} pages per second." -f $m.PagesPerSec) "That causes short freezes." "Run fewer clients or close other programs."
    }
    if ($m.CpuTotalPct -ge 90) {
        $out += & $add "high" "The processor is maxed out" ("All cores together were {0:N0}% busy." -f $m.CpuTotalPct) `
            "Each client needs about one core; when all are busy, every window slows down." `
            "Keep efficiency mode on for alts (Live screens), cap the frame rate at 30, or run fewer clients at once."
    }
    if ($m.OnBattery) {
        $out += & $add "medium" "Running on battery" "The laptop isn't plugged in." "On battery, laptops slow down the processor and graphics chip a lot." "Plug in the charger."
    }
    if ($null -ne $m.Quality -and $m.Clients -ge 4 -and ($m.Quality -eq 0 -or $m.Quality -ge 7)) {
        $out += & $add "medium" "Roblox graphics quality is high for $($m.Clients) clients" $(if ($m.Quality -eq 0) { "Quality is Automatic (Roblox raises it when it can)." } else { "Quality is $($m.Quality) of 10, and every client uses the same setting." }) `
            "Higher quality means more drawing work for every single client." `
            "Use quality 1-3 for farming: the Low resource preset, or in Roblox: Esc > Settings > Graphics Mode Manual."
    }
    if ($null -ne $m.FpsCap -and $m.Clients -ge 4 -and ($m.FpsCap -le 0 -or $m.FpsCap -gt 60)) {
        $out += & $add "medium" "No frame rate cap" $(if ($m.FpsCap -le 0) { "Roblox's frame rate cap isn't set (Roblox's default)." } else { "The frame rate cap is $($m.FpsCap) FPS." }) `
            "Each client draws as many frames as the default allows, even when you're not watching it." `
            "Cap it at 30: the Low resource preset, or in Roblox: Esc > Settings > Maximum Frame Rate."
    }
    if ($m.ManagerCpuPct -ge 5) {
        $out += & $add "medium" "BloxKit itself is busy" ("It used {0:N1}% of the processor." -f $m.ManagerCpuPct) "It should use almost nothing." "Please tell the developer (and close the Live screens tab meanwhile)."
    }
    $rank = @{ high = 0; medium = 1; info = 2 }
    return @($out | Sort-Object @{ Expression = { $rank[$_.Severity] } }, @{ Expression = { $_.No } })
}

# ---------------------------------------------------------- profile setup --
function Read-JsonFile([string]$path) {
    try { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return $null }
}
function Get-Prop($obj, [string]$name) {
    # Property whose name has dots or slashes, like "https://www.roblox.com".
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

function Get-ProfileSetup([string]$profilePath, [string]$helperDir) {
    # Reads (never writes) one Chrome profile's own files:
    #   Helper:      on | off | elsewhere (loaded from another folder) | missing | unknown
    #   AlwaysAllow: yes | no | unknown   ("Always allow www.roblox.com to open Roblox")
    $r = @{ Exists = (Test-Path -LiteralPath $profilePath); Helper = "unknown"; HelperPath = ""; HelperVersion = ""; AlwaysAllow = "unknown" }
    if (-not $r.Exists) { return $r }
    $prefs = Read-JsonFile (Join-Path $profilePath "Preferences")
    if ($prefs) {
        $pairs = Get-Prop (Get-Prop $prefs.protocol_handler "allowed_origin_protocol_pairs") "https://www.roblox.com"
        $r.AlwaysAllow = $(if ((Get-Prop $pairs "roblox-player") -eq $true) { "yes" } else { "no" })
    }
    $want = $helperDir.TrimEnd('\')
    $readAny = $false
    foreach ($f in "Secure Preferences", "Preferences") {
        $j = $(if ($f -eq "Preferences") { $prefs } else { Read-JsonFile (Join-Path $profilePath $f) })
        if (-not $j) { continue }
        $readAny = $true
        $settings = $j.extensions.settings
        if (-not $settings) { continue }
        foreach ($e in $settings.PSObject.Properties) {
            $path = ("" + $e.Value.path).TrimEnd('\')
            if (-not $path) { continue }
            if ($path -ieq $want) {
                $dr = $e.Value.disable_reasons
                $off = (@($dr | Where-Object { $_ }).Count -gt 0) -or ($null -ne $e.Value.state -and [int]$e.Value.state -eq 0)
                $r.Helper = $(if ($off) { "off" } else { "on" }); $r.HelperPath = $path
                $r.HelperVersion = "" + $e.Value.service_worker_registration_info.version   # 2.2+ only (2.1 had no background part)
                return $r
            }
            if ($path -match '\\AutoJoinHelper$' -and $r.Helper -ne "elsewhere") {
                $r.Helper = "elsewhere"; $r.HelperPath = $path
                $r.HelperVersion = "" + $e.Value.service_worker_registration_info.version
            }
        }
    }
    if ($readAny -and $r.Helper -eq "unknown") { $r.Helper = "missing" }
    return $r
}

function Select-LaunchForHandoff([DateTime]$winProcStart, [DateTime]$at, $ops, [int]$maxAgeSec) {
    # Multi-window off: a window that was already open took over a launch at $at.
    # It belongs to the latest launch still waiting for a window that started after the
    # window did and shortly before the hand-over.
    $best = $null
    foreach ($op in @($ops)) {
        if ($op.Hwnd -ne 0 -or $op.Cancelled) { continue }
        if ($op.Start -le $winProcStart -or $op.Start -gt $at) { continue }
        if (($at - $op.Start).TotalSeconds -gt $maxAgeSec) { continue }
        if (-not $best -or $op.Start -gt $best.Start) { $best = $op }
    }
    return $best
}

# --------------------------------------------------------------- schedule --
# One schedule: groups in order, each for some minutes. Invoke-PlanEvent is the only thing
# that changes a run; it returns what the app should do (open / close / log). Time is
# passed in as seconds on a clock that never jumps (the app uses a Stopwatch), so changing
# the PC's clock can't end or stretch a group.
#
#   idle -> launching -> running -> (time up) -> cooldown -> launching (next group) ...
#                                            -> waiting  (until Next)
#                                            -> completed
#   running / cooldown / waiting <-> paused        any active state -> stopped
function New-PlanDefaults {
    [pscustomobject]@{
        steps       = @()          # @{ groupId; minutes }
        cooldownMin = 0            # break between groups
        whenTimeUp  = "close"      # close | keep  (close = this group's windows, except ones the next group uses)
        then        = "next"       # next | wait | stop
        loop        = $false       # after the last group, start again from the first
        maxTotalMin = 0            # stop after this much running time in total (0 = no limit)
        retries     = 1            # times to try an account again when it doesn't load
        onFailure   = "skip"       # skip | stop  (after the retries)
        followMain  = $true        # a group with your main: main opens first, the others join its server
    }
}
function New-PlanRun {
    @{ State = "idle"; Step = -1; GroupId = ""; GroupName = ""; Members = @(); Retries = @{}; Skipped = @()
       Elapsed = 0.0; SegStart = $null; Total = 0.0; ResumeTo = ""; Reason = ""; Cycle = 1; NextStep = -1 }
}
function Get-PlanElapsed($run, [double]$now) {
    # Seconds in the current phase (a group's running time, or the break).
    $run.Elapsed + $(if ($null -ne $run.SegStart) { $now - $run.SegStart } else { 0 })
}
function Get-PlanProblem($run, $plan, $groups) {
    # A run that was saved, then the schedule changed under it (step removed or moved).
    $steps = @($plan.steps)
    if ($run.Step -lt 0 -or $run.Step -ge $steps.Count -or $steps[$run.Step].groupId -ne $run.GroupId) {
        return "The schedule was changed while it was paused, so it was stopped. Start it again."
    }
    return ""
}
function Test-PlanCan($run, [string]$action, $plan = $null) {
    if ($plan -and @("pause", "resume", "next") -contains $action -and (Get-PlanProblem $run $plan $null)) { return $false }
    switch ($action) {
        "start"  { return @("idle", "completed", "stopped") -contains $run.State }
        "pause"  { return @("running", "cooldown", "waiting") -contains $run.State }
        "resume" { return $run.State -eq "paused" }
        "next"   { return @("running", "cooldown", "waiting") -contains $run.State }
        "stop"   { return @("launching", "running", "cooldown", "waiting", "paused") -contains $run.State }
    }
    return $false
}
function Get-PlanNextIndex($run, $plan) {
    $n = @($plan.steps).Count
    if ($run.Step + 1 -lt $n) { return $run.Step + 1 }
    if ($plan.loop -and $n -gt 0) { return 0 }
    return -1
}
function Get-GroupById($groups, [string]$id) { @($groups | Where-Object { $_.id -eq $id }) | Select-Object -First 1 }

function Enter-PlanStep($run, $plan, $groups, [int]$idx, [double]$now, $facts, $acts) {
    # Starts group number $idx: opens its accounts that aren't open yet.
    $tries = 0
    while ($tries -lt @($plan.steps).Count) {
        $step = @($plan.steps)[$idx]
        $g = Get-GroupById $groups $step.groupId
        if ($g -and @($g.nicks).Count) { break }
        [void]$acts.Add(@{ Do = "log"; Text = "Skipped step $($idx + 1): its group was deleted or is empty." })
        $tries++; $run.Step = $idx; $idx = Get-PlanNextIndex $run $plan
        if ($idx -lt 0) { $run.State = "completed"; $run.Reason = "No more groups."; return }
    }
    if ($tries -ge @($plan.steps).Count) { $run.State = "stopped"; $run.Reason = "None of the schedule's groups has accounts."; return }
    if ($idx -le $run.Step -and $run.Step -ge 0) { $run.Cycle++ }   # went round again
    $run.Step = $idx; $run.GroupId = $g.id; $run.GroupName = $g.name
    $run.Members = @($g.nicks); $run.Retries = @{}; $run.Skipped = @()
    $run.State = "launching"; $run.Elapsed = 0.0; $run.SegStart = $null; $run.NextStep = -1
    $toOpen = @($run.Members | Where-Object { @($facts.Open) -inotcontains $_ })
    [void]$acts.Add(@{ Do = "log"; Text = "Started '$($g.name)' ($($step.minutes) min)." + $(if ($toOpen.Count -lt $run.Members.Count) { " Already open: " + (@($run.Members | Where-Object { $toOpen -inotcontains $_ }) -join ", ") + "." } else { "" }) })
    if ($toOpen.Count) { [void]$acts.Add(@{ Do = "open"; Nicks = $toOpen; Follow = [bool]$plan.followMain }) }
}

function Complete-PlanStep($run, $plan, $groups, [double]$now, $facts, $acts, [string]$why) {
    # A group's time is up (or Next was clicked, or the total limit was reached).
    $run.Total += Get-PlanElapsed $run $now
    $next = $(if ($why -eq "limit") { -1 } else { Get-PlanNextIndex $run $plan })
    $nextMembers = @()
    if ($next -ge 0 -and $plan.then -ne "stop") { $g = Get-GroupById $groups @($plan.steps)[$next].groupId; if ($g) { $nextMembers = @($g.nicks) } }
    if ($plan.whenTimeUp -eq "close") {
        $close = @($run.Members | Where-Object { @($facts.Open) -icontains $_ -and $nextMembers -inotcontains $_ })
        if ($close.Count) { [void]$acts.Add(@{ Do = "close"; Nicks = $close }) }
    }
    [void]$acts.Add(@{ Do = "log"; Text = "'$($run.GroupName)' finished" + $(if ($why -eq "next") { " early (Next)." } elseif ($why -eq "limit") { ": total time limit reached." } else { "." }) })
    $run.Elapsed = 0.0; $run.SegStart = $null
    if ($why -eq "limit") { $run.State = "completed"; $run.Reason = "Total time limit reached."; return }
    if ($next -lt 0 -or $plan.then -eq "stop") { $run.State = "completed"; $run.Reason = "All groups done."; return }
    $run.NextStep = $next
    if ($plan.then -eq "wait" -and $why -ne "next") { $run.State = "waiting"; return }
    if ($plan.cooldownMin -gt 0 -and $why -ne "next") { $run.State = "cooldown"; $run.SegStart = $now; return }
    Enter-PlanStep $run $plan $groups $next $now $facts $acts
}

function Stop-PlanLaunches($run, $facts, $acts) {
    # Stopping: don't keep opening the group's accounts that aren't open yet.
    $pending = @($run.Members | Where-Object { @($facts.Open) -inotcontains $_ })
    if ($pending.Count) { [void]$acts.Add(@{ Do = "cancel"; Nicks = $pending }) }
}

function Invoke-PlanEvent($run, $plan, $groups, [string]$event, [double]$now, $facts, [bool]$closeOnStop = $false) {
    # Events: start | pause | resume | next | stop | tick. Returns the actions to carry out.
    # Anything that isn't possible in the current state is ignored (so double clicks are safe).
    $acts = New-Object System.Collections.ArrayList
    if ($event -ne "tick" -and -not (Test-PlanCan $run $event $plan)) { return @() }
    switch ($event) {
        "start" {
            $fresh = New-PlanRun; foreach ($k in @($fresh.Keys)) { $run[$k] = $fresh[$k] }
            Enter-PlanStep $run $plan $groups 0 $now $facts $acts
        }
        "pause" {
            $run.Elapsed = Get-PlanElapsed $run $now; $run.SegStart = $null
            $run.ResumeTo = $run.State; $run.State = "paused"
            [void]$acts.Add(@{ Do = "log"; Text = "Paused." })
        }
        "resume" {
            $run.State = $run.ResumeTo; $run.ResumeTo = ""
            if (@("running", "cooldown") -contains $run.State) { $run.SegStart = $now }
            if ($run.State -eq "launching") {
                $toOpen = @($run.Members | Where-Object { @($facts.Open) -inotcontains $_ -and @($run.Skipped) -inotcontains $_ })
                if ($toOpen.Count) { [void]$acts.Add(@{ Do = "open"; Nicks = $toOpen; Follow = [bool]$plan.followMain }) }
            }
            [void]$acts.Add(@{ Do = "log"; Text = "Resumed." })
        }
        "next" {
            if ($run.State -eq "running") { Complete-PlanStep $run $plan $groups $now $facts $acts "next" }
            elseif ($run.NextStep -ge 0) { Enter-PlanStep $run $plan $groups $run.NextStep $now $facts $acts }
        }
        "stop" {
            if ($run.State -eq "running") { $run.Total += Get-PlanElapsed $run $now }
            if ($closeOnStop) {
                $close = @($run.Members | Where-Object { @($facts.Open) -icontains $_ })
                if ($close.Count) { [void]$acts.Add(@{ Do = "close"; Nicks = $close }) }
            }
            Stop-PlanLaunches $run $facts $acts
            $run.State = "stopped"; $run.Reason = "Stopped."; $run.SegStart = $null
            [void]$acts.Add(@{ Do = "log"; Text = "Stopped" + $(if ($closeOnStop) { " and closed its windows." } else { "." }) })
        }
        "tick" {
            $problem = $(if (@("launching", "running", "cooldown", "waiting", "paused") -contains $run.State) { Get-PlanProblem $run $plan $groups } else { "" })
            if ($problem) {
                Stop-PlanLaunches $run $facts $acts
                $run.State = "stopped"; $run.Reason = $problem; $run.SegStart = $null
                [void]$acts.Add(@{ Do = "log"; Text = $problem })
                return @($acts)
            }
            switch ($run.State) {
                "launching" {
                    foreach ($n in @($run.Members)) {
                        if (@($facts.Open) -icontains $n -or @($run.Skipped) -icontains $n) { continue }
                        # Didn't load: reported as failed, or the app isn't opening it any more (e.g. the queue
                        # dropped the alts that were to follow a main that didn't load). Never wait forever.
                        if (@($facts.Failed) -inotcontains $n -and $facts.Busy) { continue }
                        $tried = [int]$run.Retries[$n]
                        if ($tried -lt $plan.retries) {
                            $run.Retries[$n] = $tried + 1
                            [void]$acts.Add(@{ Do = "open"; Nicks = @($n); Follow = [bool]$plan.followMain })
                            [void]$acts.Add(@{ Do = "log"; Text = "$n didn't load. Trying again ($($tried + 1) of $($plan.retries))." })
                        } elseif ($plan.onFailure -eq "stop") {
                            Stop-PlanLaunches $run $facts $acts
                            $run.State = "stopped"; $run.Reason = "$n didn't load in '$($run.GroupName)'."
                            [void]$acts.Add(@{ Do = "log"; Text = "Stopped: $n didn't load." })
                            return @($acts)
                        } else {
                            $run.Skipped = @($run.Skipped) + $n
                            [void]$acts.Add(@{ Do = "log"; Text = "$n didn't load. Going on without it." })
                        }
                    }
                    $pending = @($run.Members | Where-Object { @($facts.Open) -inotcontains $_ -and @($run.Skipped) -inotcontains $_ })
                    if ($pending.Count -eq 0 -and -not $facts.Busy) {
                        if (@($run.Members | Where-Object { @($facts.Open) -icontains $_ }).Count -eq 0) {
                            $run.State = "stopped"; $run.Reason = "Nobody in '$($run.GroupName)' loaded."
                            [void]$acts.Add(@{ Do = "log"; Text = "Stopped: nobody in '$($run.GroupName)' loaded." })
                        } else {
                            $run.State = "running"; $run.Elapsed = 0.0; $run.SegStart = $now
                            [void]$acts.Add(@{ Do = "log"; Text = "'$($run.GroupName)' is open. Timer started." })
                        }
                    }
                }
                "running" {
                    $step = @($plan.steps)[$run.Step]
                    if ($plan.maxTotalMin -gt 0 -and $run.Total + (Get-PlanElapsed $run $now) -ge $plan.maxTotalMin * 60) {
                        Complete-PlanStep $run $plan $groups $now $facts $acts "limit"
                    } elseif ((Get-PlanElapsed $run $now) -ge $step.minutes * 60) {
                        Complete-PlanStep $run $plan $groups $now $facts $acts "time"
                    }
                }
                "cooldown" {
                    if ((Get-PlanElapsed $run $now) -ge $plan.cooldownMin * 60) { Enter-PlanStep $run $plan $groups $run.NextStep $now $facts $acts }
                }
            }
        }
    }
    return @($acts)
}

function Get-PlanView($run, $plan, $groups, [double]$now) {
    # What to show: the current group, time left, the next group.
    $el = Get-PlanElapsed $run $now
    $step = $(if ($run.Step -ge 0 -and $run.Step -lt @($plan.steps).Count) { @($plan.steps)[$run.Step] } else { $null })
    $phaseState = $(if ($run.State -eq "paused") { $run.ResumeTo } else { $run.State })
    $len = $(if ($phaseState -eq "cooldown") { $plan.cooldownMin * 60 } elseif ($step) { $step.minutes * 60 } else { 0 })
    $nextIdx = $(if ($run.NextStep -ge 0) { $run.NextStep } elseif ($run.Step -ge 0) { Get-PlanNextIndex $run $plan } else { -1 })
    $next = $(if ($nextIdx -ge 0) { Get-GroupById $groups @($plan.steps)[$nextIdx].groupId } else { $null })
    return @{ ElapsedSec = $el; RemainingSec = [Math]::Max([double]0, $len - $el); LengthSec = $len; GroupName = $run.GroupName
              NextName = $(if ($next) { $next.name } else { "" }); PhaseState = $phaseState; TotalSec = $run.Total + $(if ($phaseState -eq "running") { $el } else { 0 }) }
}

function Get-GroupScheduleTag($group, $run, $plan, $groups, [double]$now) {
    # What a group's card says about the running schedule ("" when it isn't in it, or none runs).
    if (@("launching", "running", "cooldown", "waiting", "paused") -notcontains $run.State) { return "" }
    $v = Get-PlanView $run $plan $groups $now
    if ($run.GroupId -eq $group.id) {
        switch ($run.State) {
            "launching" { return "Schedule: opening" }
            "running"   { return "Schedule: running, " + (Format-Clock $v.RemainingSec) + " left" }
            "cooldown"  { return "Schedule: done, break before the next group" }
            "waiting"   { return "Schedule: done, waiting for Next" }
            "paused"    { return "Schedule: paused" + $(if ($v.PhaseState -eq "running") { ", " + (Format-Clock $v.RemainingSec) + " left" } else { "" }) }
        }
    }
    if ($v.NextName -and $v.NextName -eq $group.name) { return "Schedule: next" }
    if (@($plan.steps | Where-Object { $_.groupId -eq $group.id }).Count) { return "Schedule: later" }
    return ""
}
function Format-Clock([double]$secs) {
    $s = [int][Math]::Ceiling([Math]::Max([double]0, $secs))
    if ($s -ge 3600) { return "{0}:{1:00}:{2:00}" -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60), ($s % 60) }
    return "{0}:{1:00}" -f [Math]::Floor($s / 60), ($s % 60)
}

function Test-Plan($plan, $state, $info, [string]$linkKind) {
    # Before Start: Errors stop it, Warnings are shown first.
    $err = @(); $warn = @()
    if (@($plan.steps).Count -eq 0) { $err += "Add at least one group to the schedule." }
    if (@("empty", "bad") -contains $linkKind) { $err += "Paste a game, private server or profile link on the Accounts tab first." }
    $i = 0
    foreach ($s in @($plan.steps)) {
        $i++
        $g = Get-GroupById $state.groups $s.groupId
        if (-not $g) { $err += "Step ${i}: its group was deleted. Remove the step or pick another group."; continue }
        if (@($g.nicks).Count -eq 0) { $err += "Step ${i}: '$($g.name)' has no accounts." }
        if ($s.minutes -lt 1) { $err += "Step ${i}: give it at least 1 minute." }
        foreach ($n in @($g.nicks)) {
            $a = @($state.accounts | Where-Object { $_.nick -ieq $n }) | Select-Object -First 1
            if ($a -and $a.needsLogin) { $err += "$n (in '$($g.name)') needs to sign in on this PC first." }
            elseif ($info[$n.ToLower()] -and -not $info[$n.ToLower()].Ready) { $warn += "$n (in '$($g.name)') isn't fully set up (see its setup chip)." }
        }
    }
    if ($state.schedOn) { $warn += "The daily 'Scheduled start' is on. It's skipped while this schedule runs." }
    return @{ Errors = @($err | Select-Object -Unique); Warnings = @($warn | Select-Object -Unique) }
}

function ConvertTo-SavedRun($run, [double]$now) {
    # What's written to settings.json: time so far instead of the clock (it restarts with the app).
    [pscustomobject]@{ State = $run.State; Step = $run.Step; GroupId = $run.GroupId; GroupName = $run.GroupName; Members = @($run.Members)
                       Skipped = @($run.Skipped); Retries = $run.Retries; Elapsed = (Get-PlanElapsed $run $now); Total = $run.Total
                       ResumeTo = $run.ResumeTo; Reason = $run.Reason; Cycle = $run.Cycle; NextStep = $run.NextStep }
}
function ConvertFrom-SavedRun($o) {
    # After the app restarts, a schedule that was going comes back paused: nothing opens by itself.
    $run = New-PlanRun
    if (-not $o) { return $run }
    foreach ($k in "State","GroupId","GroupName","ResumeTo","Reason") { if ($null -ne $o.$k) { $run[$k] = "" + $o.$k } }
    foreach ($k in "Step","Cycle","NextStep") { if ($null -ne $o.$k) { $run[$k] = [int]$o.$k } }
    foreach ($k in "Elapsed","Total") { if ($null -ne $o.$k) { $run[$k] = [double]$o.$k } }
    $run.Members = @($o.Members | Where-Object { $_ } | ForEach-Object { "" + $_ })
    $run.Skipped = @($o.Skipped | Where-Object { $_ } | ForEach-Object { "" + $_ })
    $run.Retries = @{}; if ($o.Retries) { foreach ($p in $o.Retries.PSObject.Properties) { $run.Retries[$p.Name] = [int]$p.Value } }
    $run.SegStart = $null
    if (@("launching", "running", "cooldown", "waiting") -contains $run.State) { $run.ResumeTo = $run.State; $run.State = "paused" }
    if (@("idle", "launching", "running", "cooldown", "waiting", "paused", "completed", "stopped") -notcontains $run.State) { $run = New-PlanRun }
    return $run
}

function Test-HelperCanCloseTabs([string]$version) {
    # Tab closing came in helper 2.2 (its background part).
    $v = $null
    return ([version]::TryParse($version, [ref]$v) -and $v -ge [version]"2.2")
}

# ------------------------------------------------------------ tab closing --
# The helper (2.2+) asks BloxKit, on this PC only, whether the launch that opened
# its tab worked: GET http://127.0.0.1:<port>/launch/<id>?v=<helper version>
# Answers: wait | close | keep | unknown. Only "close" closes that one tab.
function Get-TabVerdict($op, [string]$winState, [DateTime]$now, [string]$closeWhen, [int]$maxAgeSec) {
    # -> @{ State = wait | close | keep | unknown; Why = what to tell you about it }
    # winState: what the launch's Roblox window is doing ("" = no window, or it closed again)
    $v = { param($s, $w) @{ State = $s; Why = $w } }
    if (-not $op) { return & $v "unknown" "BloxKit doesn't know this launch (the app was restarted since)." }
    if ($closeWhen -notin @("window", "connected")) { return & $v "keep" "Tab closing is off (Settings > Opening accounts)." }
    if ($op.Cancelled) { return & $v "keep" "The launch was cancelled." }
    $tooOld = ($now - $op.Start).TotalSeconds -gt $maxAgeSec
    if ($op.Hwnd -eq 0) {   # Roblox hasn't opened (yet)
        if ($tooOld) { return & $v "keep" "No Roblox window appeared for this launch." }
        return & $v "wait" "Waiting for its Roblox window."
    }
    if (-not $winState) { return & $v "keep" "Its Roblox window closed again." }
    if ($closeWhen -eq "window") { return & $v "close" "Its Roblox window opened." }
    switch ($winState) {
        "connected" { return & $v "close" "It's in a game (Roblox's log confirms it)." }
        { $_ -in @("loading", "joining", "disconnected") } {   # disconnected may be a teleport
            if ($tooOld) { return & $v "keep" "It didn't get into a game in time (still $winState)." }
            return & $v "wait" "Waiting until it's in a game ($winState)."
        }
        "unknown" { return & $v "keep" "Its Roblox log wasn't found, so being in a game can't be confirmed. ('When Roblox opens' doesn't need the log.)" }
        default   { return & $v "keep" "It left the game before it was confirmed." }
    }
}
function Get-TabAnswer($op, [string]$winState, [DateTime]$now, [string]$closeWhen, [int]$maxAgeSec) {
    return (Get-TabVerdict $op $winState $now $closeWhen $maxAgeSec).State
}
function Get-TabSkipReason([string]$closeWhen, $setup) {
    # Why a launch doesn't get a tab-closing id at all ("" = it does).
    if ($closeWhen -notin @("window", "connected")) { return "Tab closing is off (Settings > Opening accounts)." }
    if (@("on", "elsewhere") -notcontains $setup.Helper) { return "The helper isn't installed or isn't on in this Chrome profile (Settings > Chrome setup)." }
    if (-not (Test-HelperCanCloseTabs $setup.HelperVersion)) { return "The helper in this Chrome profile is older than 2.2: on chrome://extensions, click its round reload arrow." }
    return ""
}

function Read-TabRequest([string]$head) {
    # The helper's question -> @{ Op; Version }, or $null for anything else.
    # Chrome sends no Origin for the helper; a web page's request would carry its own, so refuse those.
    $lines = $head -split "`r?`n"
    if ($lines[0] -notmatch '^GET /launch/([0-9a-fA-F-]{36})\?v=([\d.]{1,12}) HTTP/1\.[01]$') { return $null }
    $q = @{ Op = $Matches[1]; Version = $Matches[2] }
    foreach ($l in $lines) {
        if ($l -match '^Origin:\s*(.*)$' -and $Matches[1].Trim() -notmatch '^chrome-extension://[a-p]{32}$') { return $null }
    }
    return $q
}

function Start-TabListener {
    # Port 0 = Windows picks a free one. 127.0.0.1 = reachable from this PC only.
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    return $l
}

function Step-TabListener($listener, [scriptblock]$answer) {
    # Answers every question waiting right now. $answer: { param($req) ... return "wait" | "close" | ... }
    # Small and quick: requests are a few hundred bytes, and a client that sends nothing is dropped.
    $n = 0
    while ($listener.Pending() -and $n -lt 5) {   # at most 5 per tick (this runs on the window's thread)
        $n++
        $c = $listener.AcceptTcpClient()
        try {
            $c.ReceiveTimeout = 100; $c.SendTimeout = 100
            if (-not $c.Client.Poll(100000, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }   # sends nothing within 0.1 s: drop it
            $s = $c.GetStream()
            $buf = New-Object byte[] 4096; $got = 0
            while ($got -lt $buf.Length) {
                $k = $s.Read($buf, $got, $buf.Length - $got)
                if ($k -le 0) { break }
                $got += $k
                if ([Text.Encoding]::ASCII.GetString($buf, 0, $got).Contains("`r`n`r`n")) { break }
            }
            $req = Read-TabRequest ([Text.Encoding]::ASCII.GetString($buf, 0, $got))
            if ($req) { $status = "200 OK"; $body = '{"state":"' + (& $answer $req) + '"}' }
            else { $status = "404 Not Found"; $body = '{"state":"unknown"}' }
            $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: application/json`r`nCache-Control: no-store`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
            $s.Write($bytes, 0, $bytes.Length)
        } catch {
        } finally { $c.Close() }
    }
    return $n
}

if ($TestOnly) { return }

# ------------------------------------------------------------------ setup --
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
# Only one copy of the app at a time: two copies would save over each other's
# changes (e.g. the tray copy from Windows startup plus a double-click).
# A second copy asks the first one to show itself, then quits.
$instanceName = "RobloxManager_SingleInstance"
if ($NoRoblox) { $instanceName += "_test_" + [Math]::Abs($env:APPDATA.ToLower().GetHashCode()) }   # one per settings folder
$script:InstanceLock = New-Object System.Threading.Mutex($false, $instanceName)
$script:ShowSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, ($instanceName -replace "SingleInstance", "ShowWindow"))
$gotLock = $false
try { $gotLock = $script:InstanceLock.WaitOne(3000) }   # waits a moment in case the app is restarting
catch [System.Threading.AbandonedMutexException] { $gotLock = $true }   # the last copy crashed
if (-not $gotLock) { [void]$script:ShowSignal.Set(); return }
function Release-Instance { try { $script:InstanceLock.ReleaseMutex() } catch {} }

trap {
    # The line number tells exactly where, when someone sends a screenshot of this box.
    [System.Windows.MessageBox]::Show("Sorry, something went wrong:`n`n$_`n`n(BloxKit $BkVersion, BloxKit.ps1 line $($_.InvocationInfo.ScriptLineNumber))", "BloxKit", "OK", "Error") | Out-Null
    $global:RmlErrorShown = $true   # BloxKit.exe then doesn't show a second box
    break
}

if (-not ("RbxCore" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// ---------- Windows sound mixer (to mute one Roblox window) ----------
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
    int GetAudioSessionControl(IntPtr a, int b, out IntPtr c);
    int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c);
    [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
}
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
}
[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
    // IAudioSessionControl (9 methods, not used)
    int m1(); int m2(); int m3(); int m4(); int m5(); int m6(); int m7(); int m8(); int m9();
    // IAudioSessionControl2
    int m10(); int m11();
    [PreserveSig] int GetProcessId(out uint pid);
}
[ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISimpleAudioVolume {
    [PreserveSig] int SetMasterVolume(float level, ref Guid ctx);
    [PreserveSig] int GetMasterVolume(out float level);
    [PreserveSig] int SetMute(bool mute, ref Guid ctx);
    [PreserveSig] int GetMute(out bool mute);
}

public static class RbxCore {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    [DllImport("dwmapi.dll")] static extern int DwmRegisterThumbnail(IntPtr dest, IntPtr src, out IntPtr thumb);
    [DllImport("dwmapi.dll")] static extern int DwmUnregisterThumbnail(IntPtr thumb);
    [DllImport("dwmapi.dll")] static extern int DwmUpdateThumbnailProperties(IntPtr thumb, ref THUMBPROPS props);
    [DllImport("dwmapi.dll")] static extern int DwmQueryThumbnailSourceSize(IntPtr thumb, out PSIZE size);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct PSIZE { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct THUMBPROPS {
        public int dwFlags; public RECT rcDestination; public RECT rcSource;
        public byte opacity; public bool fVisible; public bool fSourceClientAreaOnly;
    }
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    const uint WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_ACTIVATE = 0x0006, WM_CLOSE = 0x0010;
    const byte SPACE_SCAN = 0x39;

    // ---- finding Roblox windows ----
    public static IntPtr[] FindRobloxWindows() {
        HashSet<uint> pids = new HashSet<uint>();
        foreach (Process p in Process.GetProcessesByName("RobloxPlayerBeta")) { pids.Add((uint)p.Id); }
        List<IntPtr> found = new List<IntPtr>();
        if (pids.Count == 0) return found.ToArray();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (!pids.Contains(pid) || !IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(h, sb, 256);
            if (sb.ToString().IndexOf("Roblox", StringComparison.OrdinalIgnoreCase) >= 0) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
    public static int PidOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid; }
    public static void CloseWindow(IntPtr h) { PostMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); }

    // ---- live screens (same feature as Alt+Tab previews) ----
    public static IntPtr AddScreen(IntPtr panel, IntPtr src) {
        IntPtr t;
        if (DwmRegisterThumbnail(panel, src, out t) != 0) return IntPtr.Zero;
        return t;
    }
    public static void RemoveScreen(IntPtr thumb) { if (thumb != IntPtr.Zero) DwmUnregisterThumbnail(thumb); }
    public static void PlaceScreen(IntPtr thumb, IntPtr src, int x, int y, int w, int h, bool visible) {
        if (thumb == IntPtr.Zero) return;
        // Use the client area size (the picture shows only the client area), so the
        // picture lines up exactly with the click-spot math in the app.
        PSIZE s;
        RECT cr;
        if (src != IntPtr.Zero && GetClientRect(src, out cr) && cr.Right > 0 && cr.Bottom > 0) { s.X = cr.Right; s.Y = cr.Bottom; }
        else DwmQueryThumbnailSourceSize(thumb, out s);
        int dw = w, dh = h;
        if (s.X > 0 && s.Y > 0 && w > 0 && h > 0) {
            double k = Math.Min((double)w / s.X, (double)h / s.Y);
            dw = (int)(s.X * k); dh = (int)(s.Y * k);
        }
        THUMBPROPS p = new THUMBPROPS();
        p.dwFlags = 0x1 | 0x4 | 0x8 | 0x10;
        p.rcDestination.Left = x + (w - dw) / 2;
        p.rcDestination.Top = y + (h - dh) / 2;
        p.rcDestination.Right = p.rcDestination.Left + dw;
        p.rcDestination.Bottom = p.rcDestination.Top + dh;
        p.opacity = 255;
        p.fVisible = visible;
        p.fSourceClientAreaOnly = true;
        DwmUpdateThumbnailProperties(thumb, ref p);
    }

    // ---- window control ----
    public static void ForceFront(IntPtr h) {
        if (!IsWindow(h)) return;
        IntPtr fg = GetForegroundWindow();
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint me = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0 && fgThread != me) attached = AttachThreadInput(me, fgThread, true);
        if (IsIconic(h)) ShowWindow(h, 9);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        if (attached) AttachThreadInput(me, fgThread, false);
    }
    public static void Maximize(IntPtr h) { ShowWindow(h, 3); }
    public static void Restore(IntPtr h) { ShowWindow(h, 9); }
    public static void Unminimize(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 4);
        SetWindowPos(h, new IntPtr(1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }

    // ---- anti-AFK input: keys and clicks ----
    // Roblox reads the keyboard through raw input and only in its focused window, so keys
    // posted to a window in the background (PostMessage) are ignored on most PCs.
    // What always works is real input to the focused window (FocusKey/FocusClick).
    // "Hidden" mode does that out of sight: Stash moves the window just past the right edge
    // of the whole desktop, it gets focus and the key there, and Unstash puts it back (behind
    // everything) once the window you were using has the focus again. The live screens keep
    // showing it, because a DWM thumbnail doesn't care where the window is.
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    public static RECT Stash(IntPtr h) {
        RECT r;
        GetWindowRect(h, out r);
        int x = GetSystemMetrics(76) + GetSystemMetrics(78) + 64;   // SM_XVIRTUALSCREEN + SM_CXVIRTUALSCREEN: past every monitor
        SetWindowPos(h, IntPtr.Zero, x, GetSystemMetrics(77), 0, 0, 0x0001 | 0x0004 | 0x0010);   // no size, no z-order, no activate
        return r;
    }
    public static void Unstash(IntPtr h, RECT r) {
        if (IsWindow(h)) SetWindowPos(h, new IntPtr(1), r.Left, r.Top, 0, 0, 0x0001 | 0x0010);   // back where it was, at the bottom, not activated
    }
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public static void FocusKey(IntPtr h, int vk, int holdMs) {
        if (!IsWindow(h)) return;
        if (GetForegroundWindow() != h) { ForceFront(h); Thread.Sleep(150); }
        byte scan = (byte)MapVirtualKey((uint)vk, 0);
        keybd_event(0, scan, 0x0008, UIntPtr.Zero);
        Thread.Sleep(holdMs);
        keybd_event(0, scan, 0x0008 | 0x0002, UIntPtr.Zero);
        Thread.Sleep(60);
    }
    // fx, fy = where to click, as a fraction of the window's picture (0.5, 0.5 = middle)
    public static void FocusClick(IntPtr h, double fx, double fy) {
        RECT r;
        if (!IsWindow(h) || !GetClientRect(h, out r)) return;
        if (GetForegroundWindow() != h) { ForceFront(h); Thread.Sleep(150); }
        POINT p; p.X = (int)(r.Right * fx); p.Y = (int)(r.Bottom * fy);
        ClientToScreen(h, ref p);
        POINT old; GetCursorPos(out old);
        SetCursorPos(p.X, p.Y);
        Thread.Sleep(50);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(70);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(50);
        SetCursorPos(old.X, old.Y);
    }
    public static int[] ClientSize(IntPtr h) {
        RECT r;
        if (!IsWindow(h) || !GetClientRect(h, out r)) return new int[] { 0, 0 };
        return new int[] { r.Right - r.Left, r.Bottom - r.Top };
    }
    public static uint IdleMs() {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        GetLastInputInfo(ref li);
        return unchecked((uint)Environment.TickCount - li.dwTime);
    }

    // ---- low-power: make a window smaller without moving it ----
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    public static void SizeWindow(IntPtr h, int w, int ht) {
        if (!IsWindow(h)) return;
        if (IsIconic(h) || IsZoomed(h)) ShowWindow(h, 9);
        SetWindowPos(h, IntPtr.Zero, 0, 0, w, ht, 0x0002 | 0x0004 | 0x0010);
    }

    // ---- "Disconnected" box check: looks at the middle of the window picture ----
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BITMAPINFO bi, uint usage);
    [StructLayout(LayoutKind.Sequential)] struct BITMAPINFO {
        public uint biSize; public int biWidth; public int biHeight; public ushort biPlanes; public ushort biBitCount;
        public uint biCompression; public uint biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public uint biClrUsed; public uint biClrImportant;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)] public uint[] colors;
    }
    // Returns 0..1 = how much of the middle looks like Roblox's grey message box.
    // Returns -1 if the picture couldn't be read (minimized / black).
    public static double DialogScore(IntPtr h) {
        RECT r;
        if (!IsWindow(h) || IsIconic(h) || !GetClientRect(h, out r)) return -1;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w < 100 || ht < 100) return -1;
        IntPtr wdc = GetDC(h);
        IntPtr mdc = CreateCompatibleDC(wdc);
        IntPtr bmp = CreateCompatibleBitmap(wdc, w, ht);
        IntPtr old = SelectObject(mdc, bmp);
        byte[] px = null;
        try {
            if (!PrintWindow(h, mdc, 0x1 | 0x2)) return -1;
            BITMAPINFO bi = new BITMAPINFO();
            bi.biSize = 40; bi.biWidth = w; bi.biHeight = -ht; bi.biPlanes = 1; bi.biBitCount = 32; bi.biCompression = 0;
            bi.colors = new uint[4];
            px = new byte[w * ht * 4];
            SelectObject(mdc, old);
            if (GetDIBits(mdc, bmp, 0, (uint)ht, px, ref bi, 0) == 0) return -1;
        } finally {
            DeleteObject(bmp); DeleteDC(mdc); ReleaseDC(h, wdc);
        }
        int total = 0, grey = 0, black = 0;
        for (int yi = 0; yi < 24; yi++) {
            int y = (int)(ht * (0.38 + 0.24 * yi / 23.0));
            for (int xi = 0; xi < 32; xi++) {
                int x = (int)(w * (0.32 + 0.36 * xi / 31.0));
                int i = (y * w + x) * 4;
                int b = px[i], g = px[i + 1], rr = px[i + 2];
                int mx = Math.Max(rr, Math.Max(g, b)), mn = Math.Min(rr, Math.Min(g, b));
                int avg = (rr + g + b) / 3;
                total++;
                if (avg < 8) black++;
                if (mx - mn <= 14 && avg >= 30 && avg <= 85) grey++;
            }
        }
        if (black > total * 0.95) return -1;
        return (double)grey / total;
    }

    // ---- efficiency mode: Windows 11's power-saving mode for a process (as in Task Manager) ----
    // On: EcoQoS (runs on power-saving cores, lower clocks) + "Below normal" priority.
    // Task Manager uses "Low" priority; "Below normal" still puts the main first without
    // starving alts so badly that they lose connection when the PC is busy.
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool SetPriorityClass(IntPtr h, uint cls);
    [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr h, int infoClass, ref POWER_THROTTLING info, int size);
    [StructLayout(LayoutKind.Sequential)] struct POWER_THROTTLING { public uint Version, ControlMask, StateMask; }
    public static bool SetEfficiency(int pid, bool on) {
        IntPtr p = OpenProcess(0x0200 | 0x1000, false, pid);   // set information + query limited information
        if (p == IntPtr.Zero) return false;
        try {
            POWER_THROTTLING s;
            s.Version = 1;
            s.ControlMask = on ? 1u : 0u;   // off = let Windows decide again
            s.StateMask = on ? 1u : 0u;     // 1 = execution speed throttling (EcoQoS)
            bool eco = SetProcessInformation(p, 4, ref s, Marshal.SizeOf(typeof(POWER_THROTTLING)));
            bool pri = SetPriorityClass(p, on ? 0x4000u : 0x20u);   // below normal : normal
            return eco && pri;
        } finally { CloseHandle(p); }
    }

    // ---- sound: mute or unmute one process. Returns how many sound streams changed. ----
    public static int SetProcessMute(int pid, bool mute) {
        int changed = 0;
        try {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
            IMMDevice dev;
            if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0 || dev == null) return 0;
            Guid iid = typeof(IAudioSessionManager2).GUID;
            object o;
            if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0 || o == null) return 0;
            IAudioSessionManager2 mgr = (IAudioSessionManager2)o;
            IAudioSessionEnumerator se;
            if (mgr.GetSessionEnumerator(out se) != 0 || se == null) return 0;
            int n;
            se.GetCount(out n);
            for (int i = 0; i < n; i++) {
                IAudioSessionControl2 c;
                if (se.GetSession(i, out c) != 0 || c == null) continue;
                uint p;
                c.GetProcessId(out p);
                if ((int)p != pid) continue;
                ISimpleAudioVolume v = c as ISimpleAudioVolume;
                if (v == null) continue;
                Guid g = Guid.Empty;
                if (v.SetMute(mute, ref g) == 0) changed++;
            }
        } catch { }
        return changed;
    }
}
'@
}
[RbxCore]::SetProcessDPIAware() | Out-Null

if (-not ("RbxHotKeys" -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// A hidden window that receives system-wide hotkeys (WM_HOTKEY) from Windows.
public class RbxHotKeys : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    readonly List<int> ids = new List<int>();
    public event Action<int> Pressed;
    public RbxHotKeys() { CreateHandle(new CreateParams()); }
    public bool Add(int id, uint mods, uint vk) {
        bool ok = RegisterHotKey(Handle, id, mods | 0x4000, vk);   // 0x4000 = no auto-repeat
        if (ok) ids.Add(id);
        return ok;
    }
    public void Clear() { foreach (int id in ids) UnregisterHotKey(Handle, id); ids.Clear(); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(m.WParam.ToInt32());
        base.WndProc(ref m);
    }
}
'@
}

# --------------------------------------------------------------- settings --
$AppDir       = Join-Path $env:APPDATA "RobloxMultiLauncher"
$SettingsFile = Join-Path $AppDir "settings.json"
$SessionFile  = Join-Path $AppDir "session.json"
$ChromeData   = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
$HelperDir    = Join-Path $PSScriptRoot "AutoJoinHelper"
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }

$State = New-Defaults
$script:SettingsLocked = $false   # settings.json exists but couldn't be read: never save over it
$script:LoadError = ""
$script:LoadNote = ""             # things fixed while loading; shown once the window is open
$script:SaveError = ""

function Load-Settings {
    $r = Read-SettingsFile $SettingsFile
    if (-not $r.Ok) { $script:SettingsLocked = $true; $script:LoadError = $r.Error; return }
    if ($r.Source -eq "backup" -and (Test-Path -LiteralPath $SettingsFile)) {
        # Keep the unreadable file: the next save would otherwise turn it into the .bak copy.
        Copy-Item -LiteralPath $SettingsFile (Join-Path $AppDir ("settings.unreadable-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")) -ErrorAction SilentlyContinue
    }
    $script:State = $r.State
    $script:LoadNote = (@($r.Warnings) -join "`n")
}
function Save-Settings {
    if ($script:SkipSave -or $script:SettingsLocked) { return }
    $err = Write-SettingsFile $script:State $SettingsFile
    if ($err -and $err -ne $script:SaveError) { Say "Couldn't save your settings: $err" }   # once, not on every save
    $script:SaveError = $err
}
Load-Settings

# ----------------------------------------------------------------- chrome --
function Find-Chrome {
    $list = @(
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
    )
    foreach ($p in $list) { if ($p -and (Test-Path $p)) { return $p } }
    foreach ($root in "HKLM:", "HKCU:") {
        try {
            $v = (Get-ItemProperty "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction Stop).'(default)'
            if ($v -and (Test-Path $v)) { return $v }
        } catch {}
    }
    return $null
}
$ChromeExe = Find-Chrome

function Get-ChromeProfiles {
    $result = @()
    $ls = Join-Path $ChromeData "Local State"
    if (Test-Path $ls) {
        try {
            $json = [IO.File]::ReadAllText($ls) | ConvertFrom-Json
            foreach ($p in $json.profile.info_cache.PSObject.Properties) { $result += [pscustomobject]@{ Dir = $p.Name; Name = $p.Value.name } }
        } catch {}
    }
    return $result
}

function Open-Chrome($acc, [string]$url) {
    if ($NoRoblox) { Say "(test mode) would open Chrome for $($acc.nick): $url"; return $true }   # tests never launch anything
    if (-not $ChromeExe) {
        [System.Windows.MessageBox]::Show("I couldn't find Google Chrome on this PC. Please install Chrome, then open this app again.", "Chrome not found", "OK", "Warning") | Out-Null
        return $false
    }
    Start-Process -FilePath $ChromeExe -ArgumentList @("--profile-directory=`"$($acc.profileDir)`"", "--new-window", "`"$url`"")
    return $true
}

# ------------------------------------------------------ multi-window locks --
# Roblox checks these two names to see if it is already running.
# We hold them first, so every new Roblox window thinks it's the only one.
$script:Locks = @()
function Grab-Locks {
    foreach ($name in "ROBLOX_singletonMutex", "ROBLOX_singletonEvent") {
        try {
            $created = $false
            $m = New-Object System.Threading.Mutex($true, $name, [ref]$created)
            if ($created) { $script:Locks += $m } else { $m.Dispose() }
        } catch {}
    }
    return ($script:Locks.Count -gt 0)
}
function Release-Locks {
    foreach ($m in $script:Locks) { try { $m.ReleaseMutex() } catch {}; try { $m.Dispose() } catch {} }
    $script:Locks = @()
}
function Get-RobloxCount { @(Get-Process -Name "RobloxPlayerBeta" -ErrorAction SilentlyContinue).Count }

# ------------------------------------------------------------ runtime state --
$script:Wins = New-Object System.Collections.ArrayList   # one object per Roblox window
$script:NextNum = 1
$script:ExpectedClose = New-Object System.Collections.Generic.HashSet[long]
$script:AccStatus = @{}           # nick -> @{ State = "failed"|"disc"; Time = "14:05" }
$script:RejoinLog = @{}           # nick -> list of times (to stop rejoin loops)
$script:SessionDirty = $false
$script:Playing = [IntPtr]::Zero
$script:PanelHwnd = [IntPtr]::Zero
$script:ReallyExit = $false
$script:TrayTipShown = $false
$script:Rng = New-Object System.Random

# Restore window names from last time (only for windows that are still open)
$script:SessionRestore = @{}
if (Test-Path $SessionFile) {
    try {
        foreach ($e in @((Get-Content $SessionFile -Raw | ConvertFrom-Json).windows)) {
            if ($e) { $script:SessionRestore[[long]$e.h] = $e }
        }
    } catch {}
}
function Save-Session {
    $list = @()
    foreach ($w in $script:Wins) {
        $ps = $(if ($w.ProcStart) { $w.ProcStart.Ticks } else { 0 })
        $list += [pscustomobject]@{ h = $w.Handle.ToInt64(); ps = $ps; num = $w.Num; name = $w.Name; nick = $w.Nick; afk = $w.Afk; muted = $w.Muted; cx = $w.ClickX; cy = $w.ClickY }
    }
    try { [pscustomobject]@{ windows = $list } | ConvertTo-Json -Depth 4 | Set-Content -Path $SessionFile -Encoding UTF8 } catch {}
    $script:SessionDirty = $false
}

# ================================================================== THEME ==
# The BloxKit look in one place. Colors are tokens: XAML uses {StaticResource Accent},
# code uses Brush "Accent". Every window (the main one, dialogs, message boxes) gets
# them, and the control styles below, from the application's resources.
$BkTokens = [ordered]@{
    # the brand palette
    Midnight = "#0B0F14"; Slate = "#1F2937"; Accent = "#3B82F6"; Violet = "#8B5CF6"; Cloud = "#F8FAFC"
    # surfaces: Midnight behind, Slate cards, shades of them for depth
    Bg = "#0B0F14"; Nav = "#111720"; Surface = "#1F2937"; SurfaceAlt = "#263243"; Raised = "#2B3749"; Hover = "#334155"
    Input = "#111827"; Line = "#2E3A4D"; LineStrong = "#475569"; ControlEdge = "#55657D"; Screen = "#000000"
    # text on dark
    Ink = "#F8FAFC"; InkSoft = "#CBD5E1"; Muted = "#94A3B8"; Subtle = "#8B9AB2"; Faint = "#64748B"
    # interaction
    AccentHover = "#60A5FA"; AccentSoft = "#1E3A66"; Focus = "#93C5FD"; VioletSoft = "#2E1F5E"
    # status: always shown with a word or symbol too, never by color alone
    Success = "#22C55E"; SuccessInk = "#4ADE80"; SuccessBg = "#12301F"; SuccessStrong = "#16A34A"
    Warning = "#F59E0B"; WarningInk = "#FBBF24"; WarningBg = "#33260E"; WarnEdge = "#B7791F"
    Caution = "#F97316"; CautionInk = "#FDBA74"; CautionBg = "#3A2412"; CautionStrong = "#C2410C"
    Danger = "#EF4444"; DangerInk = "#F87171"; DangerSoftInk = "#FCA5A5"; DangerBg = "#3A1518"; DangerStrong = "#7F1D1D"
    Star = "#FBBF24"; OnStar = "#111827"; Off = "#64748B"
}
# Motion, in ms. Short and subtle; everything is skipped when animations are off.
$BkMotion = @{ Fast = 120; Base = 180; Slow = 280; Splash = 1150 }

$ThemeStyles = @'
  <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>
  <LinearGradientBrush x:Key="BrandGradient" StartPoint="0,0" EndPoint="1,1"><GradientStop Offset="0" Color="{StaticResource C.Accent}"/><GradientStop Offset="1" Color="{StaticResource C.Violet}"/></LinearGradientBrush>
  <LinearGradientBrush x:Key="BrandGradientH" StartPoint="0,0.5" EndPoint="1,0.5"><GradientStop Offset="0" Color="{StaticResource C.Accent}"/><GradientStop Offset="1" Color="{StaticResource C.Violet}"/></LinearGradientBrush>

  <!-- Buttons: hover fades a light layer in, press darkens, keyboard focus gets a ring. -->
  <Style x:Key="Btn" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Background" Value="{StaticResource Raised}"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Padding" Value="12,7"/>
    <Setter Property="HorizontalContentAlignment" Value="Center"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Grid>
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8"/>
            <Border x:Name="hl" Background="#FFFFFF" Opacity="0" CornerRadius="8"/>
            <Border x:Name="pr" Background="#000000" Opacity="0" CornerRadius="8"/>
            <Border x:Name="ring" BorderBrush="{StaticResource Focus}" BorderThickness="2" CornerRadius="10" Margin="-3" Opacity="0"/>
            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="hl" Storyboard.TargetProperty="Opacity" To="0.08" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="hl" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="pr" Property="Opacity" Value="0.18"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ring" Property="Opacity" Value="1"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.42"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="BigBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="{StaticResource Accent}"/>
    <Setter Property="FontSize" Value="15"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="14,12"/>
  </Style>
  <!-- The one main action on a screen: the brand gradient. -->
  <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource BigBtn}">
    <Setter Property="Background" Value="{StaticResource BrandGradient}"/>
  </Style>
  <Style x:Key="GhostBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="{StaticResource LineStrong}"/>
  </Style>
  <Style TargetType="Button" BasedOn="{StaticResource Btn}"/>   <!-- plain buttons (in dialogs) look the same -->
  <Style TargetType="Window"><Setter Property="Background" Value="{StaticResource Surface}"/></Style>

  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{StaticResource Surface}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="14"/>
    <Setter Property="Padding" Value="18"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Title" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="FontFamily" Value="{StaticResource Display}"/>
    <Setter Property="FontSize" Value="17"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,0,0,4"/>
  </Style>
  <Style x:Key="Eyebrow" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Subtle}"/>
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,14,0,6"/>
  </Style>
  <Style x:Key="Hint" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="LineHeight" Value="19"/>
  </Style>
  <Style x:Key="Label" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource InkSoft}"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>

  <Style TargetType="TextBox">
    <Setter Property="Background" Value="{StaticResource Input}"/>
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
    <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
    <Setter Property="Padding" Value="10,8"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8">
            <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource LineStrong}"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="{StaticResource ControlEdge}" Background="{StaticResource Input}" VerticalAlignment="Top" Margin="0,1,0,0">
              <Grid>
                <Path x:Name="tick" Data="M3.5,8.5 L6.8,11.6 L12.6,5" Stroke="{StaticResource Ink}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
                <Path x:Name="dash" Data="M4,8.2 L11,8.2" Stroke="{StaticResource Ink}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/>
              </Grid>
            </Border>
            <ContentPresenter x:Name="cp" Grid.Column="1" Margin="9,0,0,0" VerticalAlignment="Top" RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource AccentHover}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
            </Trigger>
            <!-- some, not all (e.g. auto-click on for some accounts) -->
            <Trigger Property="IsChecked" Value="{x:Null}">
              <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter TargetName="dash" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Focus}"/></Trigger>
            <Trigger Property="HasContent" Value="False"><Setter TargetName="cp" Property="Margin" Value="0"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="RadioButton">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Grid Background="Transparent">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid Width="18" Height="18" VerticalAlignment="Top" Margin="0,1,0,0">
              <Ellipse x:Name="ring" Stroke="{StaticResource ControlEdge}" StrokeThickness="1.5" Fill="{StaticResource Input}"/>
              <Ellipse x:Name="dot" Width="8" Height="8" Fill="{StaticResource Ink}" Visibility="Collapsed"/>
            </Grid>
            <ContentPresenter Grid.Column="1" Margin="9,0,0,0" VerticalAlignment="Top" RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ring" Property="Stroke" Value="{StaticResource AccentHover}"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="ring" Property="Fill" Value="{StaticResource Accent}"/>
              <Setter TargetName="ring" Property="Stroke" Value="{StaticResource Accent}"/>
              <Setter TargetName="dot" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ring" Property="Stroke" Value="{StaticResource Focus}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="10,7" Margin="2,1">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Hover}"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource AccentSoft}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ComboBox">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Background" Value="{StaticResource Input}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
    <Setter Property="Padding" Value="10,7,30,7"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton x:Name="tg" Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="b" Background="{StaticResource Input}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8">
                    <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" Data="M0,0 L4.5,4.5 L9,0"
                          Stroke="{StaticResource Muted}" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource LineStrong}"/></Trigger>
                    <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <Border x:Name="ring" BorderBrush="{StaticResource Focus}" BorderThickness="2" CornerRadius="10" Margin="-3" Opacity="0" IsHitTestVisible="False"/>
            <ContentPresenter IsHitTestVisible="False" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"
                              Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
            <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
              <Border Background="{StaticResource Raised}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10" Margin="0,4,0,0" Padding="3"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="ring" Property="Opacity" Value="1"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ScrollBar">
    <Setter Property="Width" Value="10"/>
    <Setter Property="MinWidth" Value="10"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
            <Track.Thumb>
              <Thumb>
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb">
                    <Border x:Name="t" Background="{StaticResource Line}" CornerRadius="4" Margin="2"/>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="{StaticResource LineStrong}"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="10"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <!-- Progress: always a real amount (how many accounts opened, how much time is left). -->
  <Style TargetType="ProgressBar">
    <Setter Property="Foreground" Value="{StaticResource BrandGradientH}"/>
    <Setter Property="Background" Value="{StaticResource Input}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ProgressBar">
          <Grid>
            <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="4"/>
            <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ToolTip">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="MaxWidth" Value="360"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToolTip">
          <Border Background="{StaticResource Raised}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="10,6">
            <ContentPresenter TextElement.Foreground="{StaticResource Ink}">
              <ContentPresenter.Resources><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></ContentPresenter.Resources>
            </ContentPresenter>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- Menus opened from code ("..." buttons) -->
  <Style x:Key="DarkMenu" TargetType="ContextMenu">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ContextMenu">
          <Border Background="{StaticResource Raised}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10" Padding="4" MinWidth="220">
            <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="DarkItem" TargetType="MenuItem">
    <Setter Property="Foreground" Value="{StaticResource Ink}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="MenuItem">
          <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="12,8">
            <ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Hover}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- Navigation: the selected tab is lifted onto Slate with a blue-violet underline. -->
  <Style TargetType="TabItem">
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TabItem">
          <Grid Margin="0,0,4,0" Cursor="Hand">
            <Border x:Name="tb" Background="Transparent" CornerRadius="9" Padding="16,8,16,10">
              <ContentPresenter x:Name="cp" ContentSource="Header" TextElement.Foreground="{StaticResource Muted}" TextElement.FontSize="14" TextElement.FontWeight="SemiBold"/>
            </Border>
            <Border x:Name="bar" Height="3" CornerRadius="1.5" VerticalAlignment="Bottom" Margin="16,0,16,3" Background="{StaticResource BrandGradientH}" Opacity="0"/>
            <Border x:Name="ring" BorderBrush="{StaticResource Focus}" BorderThickness="2" CornerRadius="9" Opacity="0"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="cp" Property="TextElement.Foreground" Value="{StaticResource Ink}"/>
              <Setter TargetName="tb" Property="Background" Value="#0FFFFFFF"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="tb" Property="Background" Value="{StaticResource Surface}"/>
              <Setter TargetName="cp" Property="TextElement.Foreground" Value="{StaticResource Ink}"/>
              <Setter TargetName="bar" Property="Opacity" Value="1"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ring" Property="Opacity" Value="1"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="TabControl">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TabControl">
          <DockPanel>
            <Border DockPanel.Dock="Top" HorizontalAlignment="Left" Background="{StaticResource Nav}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="12" Padding="4">
              <TabPanel IsItemsHost="True" KeyboardNavigation.TabNavigation="Once" KeyboardNavigation.DirectionalNavigation="Cycle"/>
            </Border>
            <ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent" Margin="{TemplateBinding Padding}"/>
          </DockPanel>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
'@
function Get-ThemeXaml {
    $colors = foreach ($k in $BkTokens.Keys) { "  <Color x:Key=`"C.$k`">$($BkTokens[$k])</Color>`n  <SolidColorBrush x:Key=`"$k`" Color=`"$($BkTokens[$k])`"/>" }
    "<ResourceDictionary xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" xmlns:x=`"http://schemas.microsoft.com/winfx/2006/xaml`">`n" +
        ($colors -join "`n") + "`n" + $ThemeStyles + "`n</ResourceDictionary>"
}

# --------------------------------------------------------------------- UI --
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BloxKit" Width="1280" Height="820" MinWidth="1000" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="{StaticResource Bg}" Foreground="{StaticResource Ink}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Grid x:Name="Root">
  <Grid Margin="16,14,16,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header: name on the left, live status pills on the right (visible from every tab) -->
    <Grid Grid.Row="0" Margin="0,0,0,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <!-- The mascot shows how things are going; the line under the name says it in words. -->
      <Grid x:Name="MascotBox" Width="60" Height="60" Margin="0,0,10,0" RenderTransformOrigin="0.5,0.9" AutomationProperties.Name="BloxKit mascot">
        <Grid.RenderTransform><ScaleTransform x:Name="MascotScale"/></Grid.RenderTransform>
        <Image x:Name="MascotA" Source="{DynamicResource Bk.Mascot.Default}"/>
        <Image x:Name="MascotB" Opacity="0"/>
      </Grid>
      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <Image Source="{DynamicResource Bk.Wordmark}" Height="25" HorizontalAlignment="Left" AutomationProperties.Name="BloxKit"/>
        <TextBlock x:Name="MascotSays" Style="{StaticResource Hint}" Margin="1,5,0,0" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"
                   Text="Your accounts, live screens and anti-AFK in one place."/>
      </StackPanel>
      <Button x:Name="AfkPill" Grid.Column="2" Style="{StaticResource Btn}" Background="{StaticResource Raised}" Padding="12,7" Margin="0,0,8,0" VerticalAlignment="Center"
              ToolTip="Turn anti-AFK on or off (Ctrl+Alt+A)">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="AfkPillDot" Width="8" Height="8" Fill="{StaticResource Off}" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock x:Name="AfkPillText" Text="Anti-AFK off" FontWeight="SemiBold"/>
        </StackPanel>
      </Button>
      <Border x:Name="StatusPill" Grid.Column="3" CornerRadius="8" Padding="12,7" VerticalAlignment="Center" Background="{StaticResource SuccessBg}">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="{StaticResource SuccessInk}" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock x:Name="StatusText" Text="Multi-window ON" Foreground="{StaticResource SuccessInk}" FontWeight="SemiBold"/>
        </StackPanel>
      </Border>
      <Button x:Name="FixBtn" Grid.Column="4" Content="Close Roblox and turn on" Style="{StaticResource Btn}" Background="{StaticResource CautionStrong}" Margin="8,0,0,0" Visibility="Collapsed" VerticalAlignment="Center"/>
    </Grid>

    <!-- Alert banner (kicks / crashes): restrained red, a clear message, and the way to fix it -->
    <Border x:Name="AlertBar" Grid.Row="1" Background="{StaticResource DangerBg}" BorderBrush="{StaticResource Danger}" BorderThickness="1" CornerRadius="12" Padding="10,8,12,8" Margin="0,0,0,10" Visibility="Collapsed">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Image Source="{DynamicResource Bk.Mascot.Error}" Width="40" Height="40" Margin="0,0,10,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="AlertText" Grid.Column="1" Foreground="{StaticResource Ink}" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/>
        <Button x:Name="AlertRejoinBtn" Grid.Column="2" Content="Rejoin" Style="{StaticResource Btn}" Background="{StaticResource SuccessStrong}" Margin="10,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="AlertCloseBtn" Grid.Column="3" Content="Dismiss" Style="{StaticResource Btn}" Margin="8,0,0,0" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <TabControl x:Name="Tabs" Grid.Row="2" Background="Transparent" BorderThickness="0" Padding="0,12,0,0">

      <!-- ============================ ACCOUNTS ============================ -->
      <TabItem x:Name="TabAccounts" Header="Accounts">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="440"/></Grid.ColumnDefinitions>

          <Border Style="{StaticResource Card}" Margin="0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Top">
                <TextBlock Text="Your accounts" Style="{StaticResource Title}"/>
                <TextBlock Text="Tick the accounts to open. Star = your main. The dot shows who is in a game." Style="{StaticResource Hint}" Margin="0,0,0,10"/>
                <Grid Margin="0,0,0,10">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Group:" Style="{StaticResource Label}" Margin="0,0,8,0"/>
                  <ComboBox x:Name="GroupBox" Grid.Column="1" ToolTip="Pick a group to tick just those accounts"/>
                  <Button x:Name="SaveGroupBtn" Grid.Column="2" Content="Save ticked as group" Style="{StaticResource Btn}" Margin="8,0,0,0"/>
                  <Button x:Name="DelGroupBtn" Grid.Column="3" Content="Delete" Style="{StaticResource Btn}" Margin="8,0,0,0"/>
                </Grid>
              </StackPanel>
              <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
                <Button x:Name="AddBtn" Content="+  Add account" Style="{StaticResource Btn}" Background="{StaticResource Accent}" Margin="0,0,8,0"/>
                <Button x:Name="TickAltsBtn" Content="Tick all alts" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                <Button x:Name="UntickBtn" Content="Untick all" Style="{StaticResource Btn}"/>
              </WrapPanel>
              <Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="AccountList"/></ScrollViewer>
                <StackPanel x:Name="EmptyText" VerticalAlignment="Center" HorizontalAlignment="Center" MaxWidth="340" Margin="0,0,0,20">
                  <Image Source="{DynamicResource Bk.Mascot.Wave1}" Width="132" Height="132"/>
                  <TextBlock Text="No accounts yet" Style="{StaticResource Title}" HorizontalAlignment="Center" Margin="0,6,0,4"/>
                  <TextBlock Text="Click &quot;+ Add account&quot; to start with your main." Style="{StaticResource Hint}" TextAlignment="Center"/>
                </StackPanel>
              </Grid>
            </DockPanel>
          </Border>

          <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Where should they go?" Style="{StaticResource Title}"/>
                  <TextBlock Text="Paste a game, private server, or profile link." Style="{StaticResource Hint}" Margin="0,0,0,8"/>
                  <Grid>
                    <TextBox x:Name="LinkBox" Background="{StaticResource Input}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}" Padding="10,9" CaretBrush="{StaticResource Ink}"/>
                    <TextBlock x:Name="LinkPlaceholder" Text="https://www.roblox.com/games/..." Foreground="{StaticResource Faint}" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                  </Grid>
                  <TextBlock x:Name="LinkStatus" Style="{StaticResource Hint}" Margin="2,6,0,0"/>
                  <WrapPanel Margin="0,8,0,0">
                    <Button x:Name="PasteBtn" Content="Paste" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                    <Button x:Name="MainServerBtn" Content="Use my main's server" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                    <Button x:Name="ClearBtn" Content="Clear" Style="{StaticResource Btn}" Margin="0,0,0,6"/>
                  </WrapPanel>
                  <Grid Margin="0,6,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Saved:" Style="{StaticResource Label}" Margin="0,0,8,0"/>
                    <ComboBox x:Name="FavBox" Grid.Column="1" ToolTip="Your saved games and servers"/>
                    <Button x:Name="SaveFavBtn" Grid.Column="2" Content="Save link" Style="{StaticResource Btn}" Margin="8,0,0,0"/>
                    <Button x:Name="DelFavBtn" Grid.Column="3" Content="Delete" Style="{StaticResource Btn}" Margin="8,0,0,0"/>
                  </Grid>
                  <CheckBox x:Name="AutoJoinBox" Margin="0,12,0,0">
                    <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Ink}" Text="Auto-click Play / Join for all accounts (a dash = some; set each one in Settings &gt; Chrome setup)"/>
                  </CheckBox>
                  <StackPanel x:Name="SpreadPanel" Margin="0,12,0,0">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Server:" Style="{StaticResource Label}" Margin="0,0,8,0"/>
                      <ComboBox x:Name="SpreadBox" Grid.Column="1" AutomationProperties.Name="Which server"/>
                    </Grid>
                    <TextBlock x:Name="SpreadHint" Style="{StaticResource Hint}" Margin="2,6,0,0"/>
                  </StackPanel>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Open" Style="{StaticResource Title}"/>
                  <TextBlock x:Name="OpenHint" Style="{StaticResource Hint}" Margin="0,0,0,10" Text="Accounts open one at a time. Each one waits for the last to load first."/>
                  <Button x:Name="StartAllBtn" Content="Start everything" Style="{StaticResource PrimaryBtn}" Padding="14,14" FontSize="16" Margin="0,0,0,4"/>
                  <TextBlock Text="Opens your main first. When it's in the game, every alt follows it." Style="{StaticResource Hint}" HorizontalAlignment="Center" Margin="0,0,0,12"/>
                  <Button x:Name="OpenTickedBtn" Content="Open ticked accounts" Style="{StaticResource BigBtn}" Background="{StaticResource Raised}" Margin="0,0,0,8"/>
                  <Button x:Name="OpenAltsBtn" Content="Open ALL alts" Style="{StaticResource BigBtn}" Background="Transparent" BorderBrush="{StaticResource LineStrong}"/>
                  <Border x:Name="ProgressCard" Background="{StaticResource SurfaceAlt}" CornerRadius="10" Padding="12" Margin="0,12,0,0" Visibility="Collapsed">
                    <StackPanel>
                      <TextBlock x:Name="ProgressText" Foreground="{StaticResource Ink}" TextWrapping="Wrap"/>
                      <ProgressBar x:Name="ProgressBar" Height="8" Margin="0,8,0,8" Minimum="0" Maximum="1" Foreground="{StaticResource Accent}" Background="{StaticResource Input}" BorderThickness="0"/>
                      <WrapPanel>
                        <Button x:Name="CancelBtn" Content="Cancel" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                        <Button x:Name="RetryBtn" Content="Retry the ones that didn't load" Style="{StaticResource Btn}" Background="{StaticResource CautionStrong}" Visibility="Collapsed"/>
                      </WrapPanel>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <!-- ============================= GROUPS ============================= -->
      <TabItem x:Name="TabGroups" Header="Groups">
        <Grid x:Name="GroupsGrid">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="290"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/>
            <ColumnDefinition x:Name="GActGap" Width="12"/><ColumnDefinition x:Name="GActCol" Width="300"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

          <Border Grid.RowSpan="2" Style="{StaticResource Card}" Margin="0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Top">
                <TextBlock Text="Groups" Style="{StaticResource Title}"/>
                <TextBlock Text="Pick a group to see who's in it." Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              </StackPanel>
              <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
                <Button x:Name="GNewBtn" Content="+  New group" Style="{StaticResource Btn}" Background="{StaticResource Accent}" Margin="0,0,8,6"/>
                <Button x:Name="GUpBtn" Content="Move up" Style="{StaticResource Btn}" Margin="0,0,8,6" ToolTip="Move the picked group up the list"/>
                <Button x:Name="GDownBtn" Content="Move down" Style="{StaticResource Btn}" Margin="0,0,0,6" ToolTip="Move the picked group down the list"/>
              </WrapPanel>
              <Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="GroupList"/></ScrollViewer>
                <StackPanel x:Name="GroupEmpty" VerticalAlignment="Top" Margin="0,8,0,0">
                  <Image Source="{DynamicResource Bk.Mascot.Idle}" Width="88" Height="88" HorizontalAlignment="Left"/>
                  <TextBlock Text="No groups yet. Click &quot;+ New group&quot;, or tick accounts on the Accounts tab and click &quot;Save ticked as group&quot;." Style="{StaticResource Hint}" Margin="0,6,0,0"/>
                </StackPanel>
              </Grid>
            </DockPanel>
          </Border>

          <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0">
            <DockPanel>
              <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock x:Name="GName" Style="{StaticResource Title}" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="GSummary" Style="{StaticResource Hint}"/>
                </StackPanel>
                <WrapPanel Grid.Column="1" VerticalAlignment="Top">
                  <Button x:Name="GRenameBtn" Content="Rename" Style="{StaticResource Btn}" Margin="8,0,0,6"/>
                  <Button x:Name="GCopyBtn" Content="Duplicate" Style="{StaticResource Btn}" Margin="8,0,0,6"/>
                  <Button x:Name="GDeleteBtn" Content="Delete" Style="{StaticResource Btn}" Background="{StaticResource DangerStrong}" Margin="8,0,0,6"/>
                </WrapPanel>
              </Grid>
              <WrapPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
                <Button x:Name="GEditBtn" Content="Edit members" Style="{StaticResource Btn}" Background="{StaticResource Accent}"/>
              </WrapPanel>
              <Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="GMemberList"/></ScrollViewer>
                <TextBlock x:Name="GMemberEmpty" Style="{StaticResource Hint}" VerticalAlignment="Top"/>
              </Grid>
            </DockPanel>
          </Border>

          <Border x:Name="GActCard" Grid.Column="4" Style="{StaticResource Card}" Margin="0" VerticalAlignment="Top">
            <StackPanel>
              <TextBlock Text="Open this group" Style="{StaticResource Title}"/>
              <TextBlock x:Name="GOpenHint" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              <Button x:Name="GOpenBtn" Content="Open members that aren't open" Style="{StaticResource PrimaryBtn}"/>
              <Button x:Name="GTickBtn" Content="Tick just these on the Accounts tab" Style="{StaticResource Btn}" Margin="0,8,0,0"/>
              <TextBlock x:Name="GProblems" Style="{StaticResource Hint}" Foreground="{StaticResource WarningInk}" Margin="0,12,0,0"/>
            </StackPanel>
          </Border>
        </Grid>
      </TabItem>

      <!-- ============================ SCHEDULE ============================ -->
      <TabItem x:Name="TabSchedule" Header="Schedule">
        <Grid x:Name="SchedGrid">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="340"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/>
            <ColumnDefinition x:Name="SOptGap" Width="12"/><ColumnDefinition x:Name="SOptCol" Width="320"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

          <Border Grid.RowSpan="2" Style="{StaticResource Card}" Margin="0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Top">
                <TextBlock Text="Groups, in order" Style="{StaticResource Title}"/>
                <TextBlock Text="Each group runs for its minutes, then the next one starts." Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              </StackPanel>
              <StackPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <ComboBox x:Name="SAddGroup" AutomationProperties.Name="Group to add"/>
                  <Button x:Name="SAddBtn" Grid.Column="1" Content="+  Add" Style="{StaticResource Btn}" Background="{StaticResource Accent}" Margin="8,0,0,0"/>
                </Grid>
                <TextBlock x:Name="SEditHint" Style="{StaticResource Hint}" Margin="0,8,0,0"/>
              </StackPanel>
              <Grid>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="SStepList"/></ScrollViewer>
                <StackPanel x:Name="SStepEmpty" VerticalAlignment="Top" Margin="0,8,0,0">
                  <Image Source="{DynamicResource Bk.Mascot.Idle}" Width="88" Height="88" HorizontalAlignment="Left"/>
                  <TextBlock Text="No groups in the schedule yet. Pick one below and click '+ Add'." Style="{StaticResource Hint}" Margin="0,6,0,0"/>
                </StackPanel>
              </Grid>
            </DockPanel>
          </Border>

          <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Top">
                <TextBlock x:Name="SStateText" Style="{StaticResource Eyebrow}" Margin="0,0,0,4"/>
                <TextBlock x:Name="SGroupText" Foreground="{StaticResource Ink}" FontFamily="{StaticResource Display}" FontSize="22" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="STimeText" Foreground="{StaticResource Ink}" FontFamily="{StaticResource Display}" FontSize="40" FontWeight="SemiBold" Margin="0,4,0,0"/>
                <ProgressBar x:Name="SProgress" Height="8" Margin="0,8,0,8" Minimum="0" Maximum="1" Foreground="{StaticResource Accent}" Background="{StaticResource Input}" BorderThickness="0"/>
                <TextBlock x:Name="SNextText" Style="{StaticResource Hint}"/>
                <TextBlock x:Name="SReasonText" Style="{StaticResource Hint}" Foreground="{StaticResource WarningInk}" Margin="0,4,0,0"/>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="SStartBtn" Content="Start" Style="{StaticResource PrimaryBtn}" Margin="0,0,8,8" MinWidth="110"/>
                  <Button x:Name="SPauseBtn" Content="Pause" Style="{StaticResource BigBtn}" Background="{StaticResource Raised}" Margin="0,0,8,8" MinWidth="110"/>
                  <Button x:Name="SNextBtn" Content="Next group" Style="{StaticResource BigBtn}" Background="{StaticResource Raised}" Margin="0,0,8,8"/>
                  <Button x:Name="SStopBtn" Content="Stop" Style="{StaticResource BigBtn}" Background="{StaticResource DangerStrong}" Margin="0,0,8,8" MinWidth="90"/>
                </WrapPanel>
                <TextBlock x:Name="SMembersText" Style="{StaticResource Hint}" Margin="0,4,0,0"/>
                <TextBlock Text="HISTORY" Style="{StaticResource Eyebrow}"/>
              </StackPanel>
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="SHistory" Foreground="{StaticResource InkSoft}" FontSize="13" TextWrapping="Wrap" LineHeight="20"/>
              </ScrollViewer>
            </DockPanel>
          </Border>

          <Border x:Name="SOptCard" Grid.Column="4" Style="{StaticResource Card}" Margin="0" VerticalAlignment="Top">
            <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,6,0">
              <TextBlock Text="Options" Style="{StaticResource Title}"/>
              <TextBlock Text="WHEN A GROUP'S TIME IS UP" Style="{StaticResource Eyebrow}"/>
              <ComboBox x:Name="SWhenBox" AutomationProperties.Name="When a group's time is up" Margin="0,0,0,8"/>
              <ComboBox x:Name="SThenBox" AutomationProperties.Name="Then"/>
              <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
                <TextBlock Text="Break between groups" Style="{StaticResource Label}"/>
                <ComboBox x:Name="SBreakBox" Grid.Column="1" AutomationProperties.Name="Break between groups"/>
              </Grid>
              <CheckBox x:Name="SLoopBox" Margin="0,12,0,0" Content="After the last group, start again"/>
              <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
                <TextBlock Text="Stop after (in total)" Style="{StaticResource Label}"/>
                <ComboBox x:Name="SMaxBox" Grid.Column="1" AutomationProperties.Name="Stop after, in total"/>
              </Grid>
              <TextBlock Text="WHEN AN ACCOUNT DOESN'T LOAD" Style="{StaticResource Eyebrow}"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
                <TextBlock Text="Try again" Style="{StaticResource Label}"/>
                <ComboBox x:Name="SRetryBox" Grid.Column="1" AutomationProperties.Name="Try again"/>
              </Grid>
              <ComboBox x:Name="SFailBox" Margin="0,8,0,0" AutomationProperties.Name="If it still doesn't load"/>
              <CheckBox x:Name="SFollowBox" Margin="0,12,0,0">
                <TextBlock TextWrapping="Wrap" Text="A group with my main: open the main first, the others join its server"/>
              </CheckBox>
              <TextBlock Style="{StaticResource Hint}" Margin="0,12,0,0" Text="The timer starts once everyone in the group has opened (or been given up on). Accounts in both groups stay open when the next group starts. If the app closes, the schedule comes back paused."/>
            </StackPanel></ScrollViewer>
          </Border>
        </Grid>
      </TabItem>

      <!-- ========================== LIVE SCREENS ========================== -->
      <TabItem x:Name="TabScreens" Header="Live screens">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="340"/></Grid.ColumnDefinitions>
          <Grid>
            <UniformGrid x:Name="Wall"/>
            <StackPanel x:Name="EmptyWall" VerticalAlignment="Center" HorizontalAlignment="Center">
              <Image Source="{DynamicResource Bk.Mascot.Idle}" Width="160" Height="160" Margin="0,0,0,8"/>
              <TextBlock Text="No Roblox windows yet" Foreground="{StaticResource Ink}" FontFamily="{StaticResource Display}" FontSize="20" FontWeight="SemiBold" HorizontalAlignment="Center"/>
              <TextBlock Text="Open accounts in the Accounts tab. They'll show up here live, already named." Style="{StaticResource Hint}" HorizontalAlignment="Center" Margin="0,6,0,0"/>
            </StackPanel>
          </Grid>
          <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Your PC right now" Style="{StaticResource Title}"/>
                  <TextBlock x:Name="PerfNowText" Foreground="{StaticResource InkSoft}" FontSize="13" TextWrapping="Wrap" LineHeight="20" Text="Measuring..."/>
                  <StackPanel x:Name="TipsList" Margin="0,6,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Anti-AFK" Style="{StaticResource Title}"/>
                  <Button x:Name="AfkToggle" Style="{StaticResource Btn}" Padding="12,14" FontSize="15" FontWeight="SemiBold" Margin="0,4,0,0"/>
                  <TextBlock x:Name="AfkStatus" Foreground="{StaticResource InkSoft}" Margin="2,8,0,0" TextWrapping="Wrap"/>

                  <TextBlock Text="WHAT IT DOES" Style="{StaticResource Eyebrow}"/>
                  <CheckBox x:Name="ActJump" Margin="0,0,0,8" Content="Jump  (Space)"/>
                  <CheckBox x:Name="ActWalk" Margin="0,0,0,8" Content="Step forward and back  (W, then S)"/>
                  <CheckBox x:Name="ActZoom" Margin="0,0,0,8" Content="Zoom the camera in and out  (I, then O)"/>
                  <CheckBox x:Name="ActClick" Margin="0,0,0,6">
                    <TextBlock TextWrapping="Wrap" Text="Click a spot on the screen (pick it with  ... &gt; Set click spot  on each screen)"/>
                  </CheckBox>
                  <TextBlock Style="{StaticResource Hint}" Text="Tick more than one and it picks one at random each time, so it looks less like a bot."/>

                  <TextBlock Text="HOW OFTEN" Style="{StaticResource Eyebrow}"/>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                    <TextBlock Text="Every" Style="{StaticResource Label}"/>
                    <ComboBox x:Name="MinutesBox" Width="74" Margin="8,0,8,0"/>
                    <TextBlock Text="minutes" Style="{StaticResource Label}"/>
                  </StackPanel>
                  <CheckBox x:Name="JitterBox" Margin="0,0,0,12">
                    <TextBlock TextWrapping="Wrap" Text="Random timing (up to 30 sec earlier or later)"/>
                  </CheckBox>
                  <Button x:Name="JumpNowBtn" Content="Do it now on all screens" Style="{StaticResource Btn}" HorizontalAlignment="Left"/>

                  <TextBlock Text="HOW IT SENDS INPUT" Style="{StaticResource Eyebrow}"/>
                  <RadioButton x:Name="ModeHidden" Margin="0,0,0,8">
                    <TextBlock TextWrapping="Wrap" Text="Hidden, no flicker: each window gets the key off-screen for a moment, so nothing pops up. Roblox sometimes ignores one, so it does it twice, 1.5 sec apart. Waits for a 2-second pause in your typing."/>
                  </RadioButton>
                  <RadioButton x:Name="ModeQuick">
                    <TextBlock TextWrapping="Wrap" Text="Quick switch: each window comes to the front for a moment. Only runs after I've been away from the PC for 10 seconds. ('Click a spot' always works this way.)"/>
                  </RadioButton>
                  <CheckBox x:Name="SkipActiveBox" Margin="0,12,0,0">
                    <TextBlock TextWrapping="Wrap" Text="Skip the window I'm playing in"/>
                  </CheckBox>
                  <WrapPanel Margin="0,12,0,0">
                    <Button x:Name="AfkAllBtn" Content="AFK on for all" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                    <Button x:Name="AfkNoneBtn" Content="AFK off for all" Style="{StaticResource Btn}"/>
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Sound and windows" Style="{StaticResource Title}"/>
                  <WrapPanel Margin="0,4,0,0">
                    <Button x:Name="MuteAltsBtn" Content="Mute all alts" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                    <Button x:Name="UnmuteAllBtn" Content="Unmute all" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                    <Button x:Name="CloseAllBtn" Content="Close all Roblox" Style="{StaticResource Btn}" Background="{StaticResource DangerStrong}" Margin="0,0,0,8"/>
                  </WrapPanel>
                  <CheckBox x:Name="EcoBox" Margin="0,4,0,10">
                    <TextBlock TextWrapping="Wrap" Text="Efficiency mode for alts: Windows runs them on power-saving cores at lower priority. Your main, and the window you're playing, stay at full speed."/>
                  </CheckBox>
                  <CheckBox x:Name="LowPowerBox" Margin="0,0,0,0">
                    <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Ink}" Text="Low-power mode: make alt windows small (PC runs cooler, alt screens look a bit blurry)"/>
                  </CheckBox>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Hotkeys" Style="{StaticResource Title}"/>
                  <TextBlock Style="{StaticResource Hint}" Foreground="{StaticResource InkSoft}" xml:space="preserve">Ctrl+Alt+G      back to this app
Ctrl+Alt+1..9   play screen #1..#9
Ctrl+Alt+J       anti-AFK now
Ctrl+Alt+A       anti-AFK on / off</TextBlock>
                  <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0" Text="Don't minimize Roblox windows. Minimized windows can't show a live screen. This app keeps them tucked behind itself."/>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <!-- ============================ SETTINGS ============================ -->
      <TabItem x:Name="TabSettings" Header="Settings">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <WrapPanel>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Opening accounts" Style="{StaticResource Title}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,10" Text="Accounts open one by one. The next one starts only after the last one's Roblox window shows up, plus a short wait."/>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Extra wait after each window appears" Style="{StaticResource Label}" TextWrapping="Wrap"/>
                  <ComboBox x:Name="SettleBox" Grid.Column="1"/>
                </Grid>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Give up on an account after" Style="{StaticResource Label}" TextWrapping="Wrap"/>
                  <ComboBox x:Name="TimeoutBox" Grid.Column="1"/>
                </Grid>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
                  <TextBlock Text="'Start everything': time for your main to get in-game before alts follow" Style="{StaticResource Label}" TextWrapping="Wrap"/>
                  <ComboBox x:Name="MainSettleBox" Grid.Column="1" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,12,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="180"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Close the Chrome tab a launch came from" Style="{StaticResource Label}" TextWrapping="Wrap"/>
                  <ComboBox x:Name="TabCloseBox" Grid.Column="1" VerticalAlignment="Center" AutomationProperties.Name="Close the Chrome tab a launch came from"/>
                </Grid>
                <TextBlock Style="{StaticResource Hint}" Margin="0,6,0,0" Text="'When it's in a game' is the safest. Only that one tab closes, and only once the launch is confirmed. If it fails, is cancelled, or can't be confirmed, the tab stays open. Needs the auto-click helper 2.2 in that Chrome profile (see the setup chip)."/>
                <TextBlock x:Name="TabCloseLast" Style="{StaticResource Hint}" Margin="0,6,0,0" Text="Last launch tab: none yet."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Performance" Style="{StaticResource Title}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,10" Text="For many clients at once. 'Your PC right now' on the Live screens tab shows what limits it."/>
                <Grid Margin="0,0,0,6">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Preset" Style="{StaticResource Label}"/>
                  <ComboBox x:Name="PerfPresetBox" Grid.Column="1" AutomationProperties.Name="Performance preset"/>
                </Grid>
                <TextBlock x:Name="PerfPresetHint" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Most Roblox windows at once" Style="{StaticResource Label}"/>
                  <ComboBox x:Name="MaxClientsBox" Grid.Column="1" AutomationProperties.Name="Most Roblox windows at once"/>
                </Grid>
                <TextBlock Text="ROBLOX GRAPHICS (EVERY CLIENT USES THE SAME)" Style="{StaticResource Eyebrow}"/>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Graphics quality" Style="{StaticResource Label}"/>
                  <ComboBox x:Name="RbxQualityBox" Grid.Column="1" AutomationProperties.Name="Roblox graphics quality"/>
                </Grid>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                  <TextBlock Text="Frame rate cap" Style="{StaticResource Label}"/>
                  <ComboBox x:Name="RbxFpsBox" Grid.Column="1" AutomationProperties.Name="Roblox frame rate cap"/>
                </Grid>
                <TextBlock x:Name="RbxNowText" Style="{StaticResource Hint}"/>
                <WrapPanel Margin="0,8,0,0">
                  <Button x:Name="RbxApplyBtn" Content="Save to Roblox" Style="{StaticResource Btn}" Background="{StaticResource Accent}" Margin="0,0,8,0"/>
                  <Button x:Name="RbxUndoBtn" Content="Undo" Style="{StaticResource Btn}" ToolTip="Put back Roblox's settings file from before the last change"/>
                </WrapPanel>
                <CheckBox x:Name="RbxAutoBox" Margin="0,10,0,0">
                  <TextBlock TextWrapping="Wrap" Text="Keep Roblox on these: BloxKit puts them into Roblox by itself whenever no Roblox is running (changes made in a game are put back)"/>
                </CheckBox>
                <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0" Text="These are Roblox's own settings (in Roblox: Esc &gt; Settings), in one file every client reads when it starts, so they can only change while no Roblox runs. Save to Roblox offers to close it first. The old file is kept for Undo."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="852" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Chrome setup" Style="{StaticResource Title}"/>
                <TextBlock x:Name="CsHint" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
                <StackPanel x:Name="CsList"/>
                <WrapPanel Margin="0,8,0,0">
                  <Button x:Name="CsAllOnBtn" Content="Auto-click on for all" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                  <Button x:Name="CsAllOffBtn" Content="Auto-click off for all" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                  <Button x:Name="CsRecheckBtn" Content="Check again" Style="{StaticResource Btn}" ToolTip="Read each Chrome profile's files again (after you changed something in Chrome)"/>
                </WrapPanel>
                <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0" Text="Read from Chrome's own files; this app never changes them. 'Always allow' is the box Chrome shows the first time an account opens Roblox: tick it, then click Open."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Kicks and crashes" Style="{StaticResource Title}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,10" Text="When a Roblox window closes by itself, you get a red alert with a Rejoin button."/>
                <CheckBox x:Name="SoundBox" Margin="0,0,0,8" Content="Play a sound"/>
                <CheckBox x:Name="AutoRejoinBox">
                  <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Ink}" Text="Rejoin automatically (max 3 times in 10 minutes per account)"/>
                </CheckBox>
                <CheckBox x:Name="SameServerBox" Margin="0,10,0,0">
                  <TextBlock TextWrapping="Wrap" Text="Rejoin the same server when possible (needs the auto-join helper)"/>
                </CheckBox>
                <CheckBox x:Name="DiscBox" Margin="0,10,0,0">
                  <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Ink}" Text="Watch for disconnects and kicks (reads Roblox's log files; for windows without a log it checks the screen every 30 sec)"/>
                </CheckBox>
                <TextBlock Style="{StaticResource Hint}" Margin="0,6,0,0" Text="It skips the window you're playing in, so the Esc menu won't set it off."/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Look, sound, tray and files" Style="{StaticResource Title}"/>
                <CheckBox x:Name="AnimBox" Margin="0,6,0,8">
                  <TextBlock TextWrapping="Wrap" Text="Animations: the startup intro, page changes and the mascot's reactions (always off when Windows' own animations are off)"/>
                </CheckBox>
                <CheckBox x:Name="AutoMuteBox" Margin="0,0,0,8" Content="Mute alts automatically when they open"/>
                <CheckBox x:Name="TrayBox" Margin="0,0,0,12">
                  <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Ink}" Text="When I minimize, hide in the tray (by the clock). Anti-AFK keeps running."/>
                </CheckBox>
                <Button x:Name="OpenFolderBtn" Content="Open settings folder" Style="{StaticResource Btn}" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Phone alerts (Discord)" Style="{StaticResource Title}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,8" Text="Get a Discord message (on your phone too) when an account is kicked or didn't load. In Discord: Server Settings &gt; Integrations &gt; Webhooks &gt; New Webhook &gt; Copy Webhook URL. Paste it here."/>
                <TextBox x:Name="HookBox" Background="{StaticResource Input}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}" Padding="8,7" CaretBrush="{StaticResource Ink}"/>
                <TextBlock x:Name="HookStatus" Style="{StaticResource Hint}" Margin="2,6,0,0"/>
                <CheckBox x:Name="HookDoneBox" Margin="0,8,0,8" Content="Also tell me when accounts finish opening"/>
                <WrapPanel>
                  <Button x:Name="HookSaveBtn" Content="Save" Style="{StaticResource Btn}" Background="{StaticResource Accent}" Margin="0,0,8,0"/>
                  <Button x:Name="HookTestBtn" Content="Send a test message" Style="{StaticResource Btn}"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Scheduled start" Style="{StaticResource Title}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,8" Text="Runs 'Start everything' by itself every day. This app must be running (tip: tick 'Open when Windows starts')."/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                  <CheckBox x:Name="SchedBox" VerticalAlignment="Center" Content="Every day at"/>
                  <TextBox x:Name="SchedTimeBox" Width="70" Margin="8,0,6,0" Background="{StaticResource Input}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}" Padding="6,4" CaretBrush="{StaticResource Ink}" ToolTip="24-hour time, like 08:00 or 19:30"/>
                  <TextBlock Text="(24-hour, like 19:30)" Style="{StaticResource Label}"/>
                </StackPanel>
                <TextBlock x:Name="SchedLinkText" Style="{StaticResource Hint}" Foreground="{StaticResource InkSoft}" Margin="0,0,0,8"/>
                <WrapPanel>
                  <Button x:Name="SchedUseLinkBtn" Content="Use the link from the Accounts tab" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
                </WrapPanel>
                <TextBlock x:Name="SchedStatus" Style="{StaticResource Hint}" Margin="2,8,0,0"/>
                <CheckBox x:Name="StartupBox" Margin="0,12,0,0">
                  <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Ink}" Text="Open BloxKit when Windows starts (it starts hidden in the tray)"/>
                </CheckBox>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Backup" Style="{StaticResource Title}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,10" Text="Save your accounts, groups, saved links and settings to one file. Use it on a new PC. No passwords or logins are in it (Chrome keeps those), and your Discord webhook link is left out. On a new PC, the app walks you through signing in each account once."/>
                <WrapPanel>
                  <Button x:Name="ExportBtn" Content="Save backup file" Style="{StaticResource Btn}" Background="{StaticResource Accent}" Margin="0,0,8,0"/>
                  <Button x:Name="ImportBtn" Content="Load backup file" Style="{StaticResource Btn}"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Image Source="{DynamicResource Bk.Mascot.Wave1}" Width="76" Height="76" VerticalAlignment="Top" Margin="-6,-4,10,0"/>
                <StackPanel Grid.Column="1">
                  <TextBlock Text="Help and feedback" Style="{StaticResource Title}"/>
                  <TextBlock x:Name="AboutText" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
                  <WrapPanel>
                    <Button x:Name="DiscordBtn" Content="Join the BloxKit Discord" Style="{StaticResource Btn}" Background="{StaticResource Accent}" Margin="0,0,8,8"/>
                    <Button x:Name="BugBtn" Content="Report a bug" Style="{StaticResource Btn}" Margin="0,0,8,8" ToolTip="Opens a short form on GitHub (needs a free GitHub account)"/>
                    <Button x:Name="IdeaBtn" Content="Suggest a feature" Style="{StaticResource Btn}" Margin="0,0,8,8" ToolTip="Opens a short form on GitHub (needs a free GitHub account)"/>
                    <Button x:Name="RepoBtn" Content="BloxKit on GitHub" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                    <Button x:Name="UpdateBtn" Content="Check for updates" Style="{StaticResource Btn}" Margin="0,0,8,8" ToolTip="Gets the newest BloxKit from GitHub into this folder; your accounts and settings stay"/>
                  </WrapPanel>
                </StackPanel>
              </Grid>
            </Border>
            <Border Style="{StaticResource Card}" Width="420" Margin="0,0,12,12" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Time online today" Style="{StaticResource Title}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,8" Text="How long each account has had a Roblox window open today. Resets at midnight."/>
                <TextBlock x:Name="StatsText" Foreground="{StaticResource Ink}" FontFamily="Consolas" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
          </WrapPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>

    <Border Grid.Row="3" Background="{StaticResource Nav}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10" Padding="12,8" Margin="0,10,0,0">
      <DockPanel>
        <Ellipse x:Name="FooterDot" Width="7" Height="7" Fill="{StaticResource Accent}" Margin="0,0,10,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="Footer" Text="Ready." Foreground="{StaticResource InkSoft}" TextWrapping="Wrap" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
  </Grid>

  <!-- Startup intro: over everything, never in the way (clicks go through), gone in about a second. -->
  <Grid x:Name="Splash" Background="{StaticResource Bg}" IsHitTestVisible="False" Visibility="Collapsed">
    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
      <Grid x:Name="SplashArt" Width="210" Height="210" HorizontalAlignment="Center" Opacity="0">
        <Grid.RenderTransform><TranslateTransform x:Name="SplashLift" Y="16"/></Grid.RenderTransform>
        <Image Source="{DynamicResource Bk.Mascot.Idle}"/>
        <Image x:Name="SplashLit" Source="{DynamicResource Bk.Mascot.Happy}" Opacity="0"/>
      </Grid>
      <Image x:Name="SplashWord" Source="{DynamicResource Bk.Wordmark}" Height="46" Margin="0,16,0,0" Opacity="0" AutomationProperties.Name="BloxKit"/>
    </StackPanel>
  </Grid>
  </Grid>
</Window>
'@

$app = New-Object System.Windows.Application
$app.ShutdownMode = "OnExplicitShutdown"
$app.Resources = [Windows.Markup.XamlReader]::Parse((Get-ThemeXaml))
# The mascot and logo (made by tools\build-brand.ps1). Without them the app still works, just without the art.
$ArtFile = Join-Path $PSScriptRoot "assets\brand\BloxKit.Art.xaml"
try {
    $art = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($ArtFile))
    foreach ($k in @($art.Keys)) { $v = $art[$k]; if ($v -is [System.Windows.Freezable] -and $v.CanFreeze) { $v.Freeze() } }
    $app.Resources.MergedDictionaries.Add($art)
} catch {}
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$IconFile = Join-Path $PSScriptRoot "assets\BloxKit.ico"
try { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $IconFile)) } catch {}   # taskbar and title bar
$ui = @{}
$xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq "Name" } | Select-Object -First 1
    if ($n) { $ui[$n.Value] = $win.FindName($n.Value) }
}
$BtnStyle = $win.FindResource("Btn")
function Brush([string]$v) {
    # A theme token ("Accent", "Muted", ...) or any color WPF understands ("Transparent", "#RRGGBB").
    $r = $app.Resources[$v]
    if ($r -is [System.Windows.Media.Brush]) { return $r }
    (New-Object System.Windows.Media.BrushConverter).ConvertFromString($v)
}

# ---- motion: short, subtle, and off when the user (or Windows) turned animations off ----
function Test-Motion { [bool]$script:State.animations -and [System.Windows.SystemParameters]::ClientAreaAnimation }
function Set-Anim($el, $dp, [double]$to, [int]$ms, $from = $null, [int]$delay = 0, [scriptblock]$done = $null) {
    # Animates one number (opacity, a move, a scale) with an ease-out; without motion it just jumps there.
    if (-not (Test-Motion)) { $el.BeginAnimation($dp, $null); $el.SetValue($dp, $to); if ($done) { & $done }; return }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $to; if ($null -ne $from) { $a.From = [double]$from }
    $a.Duration = [TimeSpan]::FromMilliseconds($ms); $a.BeginTime = [TimeSpan]::FromMilliseconds($delay)
    $e = New-Object System.Windows.Media.Animation.CubicEase; $e.EasingMode = "EaseOut"; $a.EasingFunction = $e
    if ($done) { $a.Add_Completed($done) }
    $el.BeginAnimation($dp, $a)
}
$OpacityDP = [System.Windows.UIElement]::OpacityProperty

function Say([string]$m) {
    if (-not $ui.Footer) { return }
    $ui.Footer.Text = (Get-Date -Format "HH:mm") + "  " + $m
    # The dot only adds a tone; the words always say what happened.
    $warn = $m -match "^(Couldn't|Can't|Sorry|Warning|Still blocked)|\b(failed|didn't load|didn't work|isn't|wasn't found|not found)\b"
    $ui.FooterDot.Fill = Brush $(if ($warn) { "Warning" } else { "Accent" })
    Set-Anim $ui.Footer $OpacityDP 1 200 0.35
}

# ---- the mascot: its look and the line under the name come from what the app is really doing ----
$script:MascotNow = "Default"; $script:MascotMoment = $null; $script:MascotWave = 0
function Set-MascotArt([string]$key) {
    if ($script:MascotNow -eq $key) { return }
    $src = $app.TryFindResource("Bk.Mascot.$key"); if (-not $src) { return }
    $script:MascotNow = $key
    if ($script:MascotWave -gt 0 -or -not (Test-Motion)) { $ui.MascotA.Source = $src; return }
    $ui.MascotB.BeginAnimation($OpacityDP, $null); $ui.MascotB.Source = $ui.MascotA.Source; $ui.MascotB.Opacity = 1
    $ui.MascotA.Source = $src
    Set-Anim $ui.MascotB $OpacityDP 0 180
    Set-Anim $ui.MascotScale ([System.Windows.Media.ScaleTransform]::ScaleXProperty) 1 240 0.92
    Set-Anim $ui.MascotScale ([System.Windows.Media.ScaleTransform]::ScaleYProperty) 1 240 0.92
}
function Get-MascotState {
    if ($script:MascotMoment -and [DateTime]::Now -lt $script:MascotMoment.Until) { return $script:MascotMoment }
    $script:MascotMoment = $null
    $n = @($script:Wins).Count
    if ($ui.AlertBar.Visibility -eq "Visible") { return @{ Art = "Error"; Text = $ui.AlertText.Text } }
    if ($script:QBusy) { return @{ Art = "Working"; Text = $(if ($ui.ProgressText.Text) { $ui.ProgressText.Text } else { "Opening accounts..." }) } }
    if (-not $NoRoblox -and $script:Locks.Count -eq 0) { return @{ Art = "Attention"; Text = "Multi-window is off, so only one Roblox window can stay open." } }
    if (@($script:State.accounts).Count -eq 0) { return @{ Art = "Default"; Text = "Hi! Add your first account to get started." } }
    $wins = $(if ($n -eq 1) { "1 Roblox window" } else { "$n Roblox windows" })
    if ($n -and $script:AfkOn) { return @{ Art = "Happy"; Text = "$wins open. Anti-AFK is keeping them online." } }
    if ($n) { return @{ Art = "Default"; Text = "$wins open." } }
    return @{ Art = "Idle"; Text = "Nothing running. Pick accounts and a game to start." }
}
function Show-MascotMoment([string]$art, [string]$text, [int]$sec = 4) {
    # A short reaction to something that just happened (it goes back to the usual look after $sec).
    $script:MascotMoment = @{ Art = $art; Text = $text; Until = [DateTime]::Now.AddSeconds($sec) }
    Update-Mascot
}
function Update-Mascot {
    if (-not $ui.MascotA) { return }
    $s = Get-MascotState
    if ($script:MascotWave -le 0) { Set-MascotArt $s.Art }
    if ($ui.MascotSays.Text -ne $s.Text) { $ui.MascotSays.Text = $s.Text; $ui.MascotSays.ToolTip = $s.Text }
    [System.Windows.Automation.AutomationProperties]::SetName($ui.MascotBox, "BloxKit: " + $s.Text)
}
$WaveTimer = New-Object System.Windows.Threading.DispatcherTimer
$WaveTimer.Interval = [TimeSpan]::FromMilliseconds(260)
$WaveTimer.Add_Tick({
    # A short hello: the raised hand swings a few times, then the usual look comes back.
    $script:MascotWave--
    if ($script:MascotWave -le 0) { $WaveTimer.Stop(); $script:MascotNow = ""; Update-Mascot; return }
    $ui.MascotA.Source = $app.TryFindResource($(if ($script:MascotWave % 2) { "Bk.Mascot.Wave2" } else { "Bk.Mascot.Wave1" }))
})
function Start-Wave { if (-not (Test-Motion) -or -not $app.TryFindResource("Bk.Mascot.Wave1")) { return }; $script:MascotWave = 7; $ui.MascotB.Opacity = 0; $WaveTimer.Start() }

# ---- startup intro: the mascot rises in, its eyes light up, the name appears, then it fades into the app ----
function Start-Intro {
    if (-not (Test-Motion) -or $Minimized -or -not $app.TryFindResource("Bk.Mascot.Idle")) { return }
    $ui.Splash.Visibility = "Visible"; $ui.Splash.Opacity = 1
    Set-Anim $ui.SplashArt $OpacityDP 1 320 0
    Set-Anim $ui.SplashLift ([System.Windows.Media.TranslateTransform]::YProperty) 0 420 16
    Set-Anim $ui.SplashLit $OpacityDP 1 260 0 340
    Set-Anim $ui.SplashWord $OpacityDP 1 300 0 460
    Set-Anim $ui.Splash $OpacityDP 0 280 1 $BkMotion.Splash { $ui.Splash.Visibility = "Collapsed"; Start-Wave }
}

# ---- page changes: the new page fades in with a small lift ----
$ui.Tabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -ne $ui.Tabs -or -not (Test-Motion)) { return }
    $c = $ui.Tabs.SelectedContent
    if ($c -isnot [System.Windows.UIElement]) { return }
    if ($c.RenderTransform -isnot [System.Windows.Media.TranslateTransform]) { $c.RenderTransform = New-Object System.Windows.Media.TranslateTransform }
    Set-Anim $c $OpacityDP 1 $BkMotion.Base 0
    Set-Anim $c.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) 0 ($BkMotion.Base + 40) 8
})

# ---- dark title bars, themed message boxes and tray menu ----
Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BkDwm {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
    // Dark title bar in BloxKit's colors (Windows 11; older Windows just keeps its own).
    public static void Dark(IntPtr h, int caption, int text, int border) {
        int on = 1;
        DwmSetWindowAttribute(h, 20, ref on, 4);
        DwmSetWindowAttribute(h, 35, ref caption, 4);
        DwmSetWindowAttribute(h, 36, ref text, 4);
        DwmSetWindowAttribute(h, 34, ref border, 4);
    }
}
// [BkBox]::Show(...) takes the same words as MessageBox.Show and shows BloxKit's own dialog
// (set up from the script); without it, the plain Windows box.
public static class BkBox {
    public static Func<string, string, string, string, string> Handler;
    public static string Show(string text) { return Show(text, "BloxKit", "OK", "None"); }
    public static string Show(string text, string caption) { return Show(text, caption, "OK", "None"); }
    public static string Show(string text, string caption, string buttons) { return Show(text, caption, buttons, "None"); }
    public static string Show(string text, string caption, string buttons, string icon) {
        if (Handler != null) { try { return Handler(text, caption, buttons, icon); } catch { } }
        var b = (System.Windows.MessageBoxButton)Enum.Parse(typeof(System.Windows.MessageBoxButton), buttons);
        var i = (System.Windows.MessageBoxImage)Enum.Parse(typeof(System.Windows.MessageBoxImage), icon);
        return System.Windows.MessageBox.Show(text, caption, b, i).ToString();
    }
}
public class BkMenuColors : System.Windows.Forms.ProfessionalColorTable {
    static System.Drawing.Color C(int rgb) { return System.Drawing.Color.FromArgb(255, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
    public override System.Drawing.Color ToolStripDropDownBackground { get { return C(0x1F2937); } }
    public override System.Drawing.Color ImageMarginGradientBegin { get { return C(0x1F2937); } }
    public override System.Drawing.Color ImageMarginGradientMiddle { get { return C(0x1F2937); } }
    public override System.Drawing.Color ImageMarginGradientEnd { get { return C(0x1F2937); } }
    public override System.Drawing.Color MenuBorder { get { return C(0x2E3A4D); } }
    public override System.Drawing.Color MenuItemBorder { get { return C(0x334155); } }
    public override System.Drawing.Color MenuItemSelected { get { return C(0x334155); } }
    public override System.Drawing.Color MenuItemSelectedGradientBegin { get { return C(0x334155); } }
    public override System.Drawing.Color MenuItemSelectedGradientEnd { get { return C(0x334155); } }
    public override System.Drawing.Color SeparatorDark { get { return C(0x2E3A4D); } }
    public override System.Drawing.Color SeparatorLight { get { return C(0x2E3A4D); } }
}
'@
function Get-ColorRef([string]$token) { $c = [System.Windows.Media.ColorConverter]::ConvertFromString($BkTokens[$token]); [int]$c.B * 65536 + [int]$c.G * 256 + [int]$c.R }
[System.Windows.EventManager]::RegisterClassHandler([System.Windows.Window], [System.Windows.FrameworkElement]::LoadedEvent, [System.Windows.RoutedEventHandler]{
    param($w, $e)
    try { [BkDwm]::Dark((New-Object System.Windows.Interop.WindowInteropHelper($w)).Handle, (Get-ColorRef "Midnight"), (Get-ColorRef "Cloud"), (Get-ColorRef "Line")) } catch {}
})
function Initialize-BkDialog($dlg) {
    # Every dialog: on top of the app, the app's icon and font, and a quick fade in.
    if ($win.IsVisible) { $dlg.Owner = $win } else { $dlg.WindowStartupLocation = "CenterScreen" }
    $dlg.Icon = $win.Icon; $dlg.ShowInTaskbar = $false
    $dlg.FontFamily = $win.FontFamily
    if (Test-Motion) { $dlg.Opacity = 0; $dlg.Add_ContentRendered({ param($d, $e) Set-Anim $d $OpacityDP 1 $BkMotion.Fast 0 }) }
}
function Show-BkMessage([string]$text, [string]$caption, [string]$buttons, [string]$icon) {
    # BloxKit's own message box: the mascot shows the kind of message, the words say it.
    [xml]$mx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BloxKit" Width="500" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        Background="{StaticResource Surface}" Foreground="{StaticResource Ink}" FontSize="14">
  <Grid Margin="22,20,22,18">
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Image x:Name="Art" Width="84" Height="84" VerticalAlignment="Top" Margin="-6,-4,14,0"/>
    <StackPanel Grid.Column="1">
      <TextBlock x:Name="Head" Style="{StaticResource Title}" TextWrapping="Wrap"/>
      <TextBlock x:Name="Body" Foreground="{StaticResource InkSoft}" TextWrapping="Wrap" LineHeight="20" Margin="0,4,0,0"/>
    </StackPanel>
    <StackPanel x:Name="Buttons" Grid.Row="1" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0"/>
  </Grid>
</Window>
'@
    $d = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $mx))
    Initialize-BkDialog $d
    $art = switch -Regex ($icon) { "Warning|Exclamation" { "Attention" } "Error|Hand|Stop" { "Error" } "Information|Asterisk" { "Happy" } default { "Default" } }
    $d.FindName("Art").Source = $app.TryFindResource("Bk.Mascot.$art")
    $d.FindName("Head").Text = $(if ($caption) { $caption } else { "BloxKit" })
    $d.FindName("Body").Text = $text
    $names = switch ($buttons) { "YesNo" { "Yes", "No" } "YesNoCancel" { "Yes", "No", "Cancel" } "OKCancel" { "OK", "Cancel" } default { , "OK" } }
    $cancel = $(if ($names -contains "Cancel") { "Cancel" } elseif ($names -contains "No") { "No" } else { "OK" })
    $script:BoxResult = $cancel   # closing the window counts as the "no / cancel" answer
    $first = $null
    foreach ($n in $names) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $BtnStyle; $b.Content = $n; $b.MinWidth = 88; $b.Padding = New-Object System.Windows.Thickness 16,8,16,8
        $b.Margin = New-Object System.Windows.Thickness 8,0,0,0; $b.Tag = $n
        if (-not $first) { $first = $b; $b.IsDefault = $true; $b.Background = Brush "Accent" }
        if ($n -eq $cancel) { $b.IsCancel = $true }
        $b.Add_Click({ param($s, $e) $script:BoxResult = [string]$s.Tag; [System.Windows.Window]::GetWindow($s).Close() })
        $d.FindName("Buttons").Children.Add($b) | Out-Null
    }
    $d.Add_ContentRendered({ $first.Focus() | Out-Null })
    $d.ShowDialog() | Out-Null
    return [string]$script:BoxResult
}
[BkBox]::Handler = [Func[string, string, string, string, string]]{ param($t, $c, $b, $i) Show-BkMessage $t $c $b $i }
function Same($a, $b) { [object]::ReferenceEquals($a, $b) }

# =========================================================== ACCOUNTS TAB ==
function Get-Main { @($script:State.accounts | Where-Object { $_.isMain }) | Select-Object -First 1 }
function Find-Account([string]$nick) { @($script:State.accounts | Where-Object { $_.nick -ieq $nick }) | Select-Object -First 1 }
function Get-WindowOf([string]$nick) { @($script:Wins | Where-Object { $_.Nick -and $_.Nick -ieq $nick }) | Select-Object -First 1 }

function Ask-Text([string]$title, [string]$prompt, [string]$default) {
    [xml]$dx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="420" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        Background="{StaticResource Surface}" FontFamily="Segoe UI" FontSize="14">
  <StackPanel Margin="20">
    <TextBlock x:Name="P" Foreground="{StaticResource Ink}" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <TextBox x:Name="T" Background="{StaticResource Input}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}" Padding="8,7" CaretBrush="{StaticResource Ink}"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="C" Content="Cancel" Padding="16,8" Margin="0,0,8,0" Background="{StaticResource Raised}" Foreground="{StaticResource Ink}" BorderThickness="0"/>
      <Button x:Name="O" Content="OK" Padding="20,8" Background="{StaticResource Accent}" Foreground="{StaticResource Ink}" BorderThickness="0" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    Initialize-BkDialog $dlg; $dlg.Title = $title
    $p = $dlg.FindName("P"); $t = $dlg.FindName("T"); $ok = $dlg.FindName("O"); $cancel = $dlg.FindName("C")
    $p.Text = $prompt; $t.Text = $default
    $script:AskResult = $null
    $ok.Add_Click({ $script:AskResult = $t.Text.Trim(); $dlg.Close() })
    $cancel.Add_Click({ $dlg.Close() })
    $dlg.Add_ContentRendered({ $t.Focus() | Out-Null; $t.SelectAll() })
    $dlg.ShowDialog() | Out-Null
    return $script:AskResult
}

# Chrome profile setup, read from the profile's own files (never changed by this app).
# Cached for 30 seconds: the main profile's files take ~100 ms to read.
$script:SetupCache = @{}
function Get-SetupFor($a) {
    $c = $script:SetupCache[$a.profileDir]
    if ($c -and ([DateTime]::Now - $c.At).TotalSeconds -lt 30) { return $c.R }
    $r = Get-ProfileSetup (Join-Path $ChromeData $a.profileDir) $HelperDir
    $script:SetupCache[$a.profileDir] = @{ At = [DateTime]::Now; R = $r }
    return $r
}
function Get-SetupIssues($a) {
    # Plain-language list of what still needs doing in this account's Chrome profile.
    $s = Get-SetupFor $a
    $out = @()
    if (-not $s.Exists) {
        if (-not $a.needsLogin) { $out += "Its Chrome profile ($($a.profileDir)) doesn't exist yet. Chrome makes a new one when it opens; sign in to Roblox there once." }
        return $out
    }
    $tabs = $script:State.tabCloseWhen -ne "off"
    $needs = @()
    if ($a.autoJoin) { $needs += "clicking Play / Join for you" }
    if ($tabs) { $needs += "closing the launch tab" }
    if ($needs.Count) {
        $for = " It's needed for " + ($needs -join " and ") + "."
        switch ($s.Helper) {
            "missing"   { $out += "The auto-click helper isn't installed in this Chrome profile.$for Fix: ... > Set up auto-click helper." }
            "off"       { $out += "The auto-click helper is turned off in this Chrome profile.$for Turn it on at chrome://extensions." }
            "elsewhere" { $out += "The auto-click helper is loaded from another folder ($($s.HelperPath)).$for Load it again from this app's folder: ... > Set up auto-click helper." }
        }
    }
    if ($tabs -and $s.Helper -eq "on" -and -not (Test-HelperCanCloseTabs $s.HelperVersion)) {
        $out += "The auto-click helper here is an older version that can't close tabs. In this Chrome profile, open chrome://extensions and click the helper's round reload arrow (it becomes 2.2)."
    }
    if ($s.AlwaysAllow -eq "no") { $out += "Chrome will ask 'Open Roblox?' the first time. Tick 'Always allow www.roblox.com to open links of this type', then click Open." }
    return $out
}

$script:SubTexts = @{}
function Get-WinState($w) { Get-ClientState $w.Sess ([bool]$w.LogPath) ($w.LogTries -ge 20) }
function Get-AccStatusInfo($a) {
    $winOf = Get-WindowOf $a.nick
    $st = $script:AccStatus[$a.nick.ToLower()]
    $up = Format-Dur (Get-TodaySecs $a.nick)
    $upText = $(if ($up) { "   |   $up today" } else { "" })
    if ($winOf -and $winOf.DiscFlag) { return @{ Color = "Danger"; Text = $(if ($winOf.DiscText) { "Disconnected: $($winOf.DiscText)" } else { "Might be disconnected" }) + "  (screen #$($winOf.Num))$upText" } }
    if ($winOf) {
        $where = "  (screen #$($winOf.Num))$upText"
        switch (Get-WinState $winOf) {
            "connected"    {
                $srv = $(switch (Get-ServerCheck $script:Planned[$a.nick.ToLower()] $winOf.Sess.Job) {
                    "confirmed" { "   |   on the planned server " + [char]0x2713 } "elsewhere" { "   |   on another server than planned (it was probably full)" } default { "" } })
                return @{ Color = "Success"; Text = "In game$srv$where" }
            }
            "joining"      { return @{ Color = "Accent"; Text = "Joining " + $(if ($script:Planned[$a.nick.ToLower()]) { "the planned server" } else { "a server" }) + "...$where" } }
            "disconnected" { return @{ Color = "Accent"; Text = "Connection dropped, waiting to see if it's a teleport...$where" } }
            "left"         { return @{ Color = "Muted"; Text = "Roblox open, not in a game$where" } }
            "unknown"      { return @{ Color = "Muted"; Text = "Roblox open (no Roblox log found, so I can't tell if it's in a game)$where" } }
            default        { return @{ Color = "Accent"; Text = "Roblox is starting...$where" } }
        }
    }
    if ($st -and $st.State -eq "failed") { return @{ Color = "Caution"; Text = "Didn't load ($($st.Time))$upText" } }
    if ($st -and $st.State -eq "limit") { return @{ Color = "Caution"; Text = "Not opened: limit of $($script:State.maxClients) Roblox windows ($($st.Time))$upText" } }
    if ($st -and $st.State -eq "disc") { return @{ Color = "Danger"; Text = "Window closed / kicked ($($st.Time))$upText" } }
    if ($st -and $st.State -eq "opening") { return @{ Color = "Accent"; Text = "Opening...$upText" } }
    if ($a.needsLogin) { return @{ Color = "Warning"; Text = "Needs sign-in on this PC (click Sign in)$upText" } }
    return @{ Color = "Off"; Text = "Not open$upText" }
}

function Render-Accounts {
    $script:SubTexts = @{}
    $ui.AccountList.Children.Clear()
    $accs = @($script:State.accounts)
    $ui.EmptyText.Visibility = $(if ($accs.Count -eq 0) { "Visible" } else { "Collapsed" })
    foreach ($a in $accs) {
        $row = New-Object System.Windows.Controls.Border
        $row.Background = Brush "SurfaceAlt"
        $row.CornerRadius = New-Object System.Windows.CornerRadius 8
        $row.Padding = New-Object System.Windows.Thickness 10,8,8,8
        $row.Margin = New-Object System.Windows.Thickness 0,0,0,6
        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in "Auto","Auto","*","Auto","Auto","Auto") {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.IsChecked = $a.checked; $cb.VerticalAlignment = "Center"
        $cb.Margin = New-Object System.Windows.Thickness 0,0,10,0
        $cb.LayoutTransform = New-Object System.Windows.Media.ScaleTransform 1.3,1.3
        $cb.Tag = $a
        $cb.Add_Click({ param($s,$e) $s.Tag.checked = [bool]$s.IsChecked; Save-Settings; Update-Buttons })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)

        # status dot + text
        $winOf = Get-WindowOf $a.nick
        $stInfo = Get-AccStatusInfo $a
        $dotColor = $stInfo.Color; $stText = $stInfo.Text
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 12; $dot.Height = 12; $dot.Fill = Brush $dotColor; $dot.VerticalAlignment = "Center"
        $dot.Margin = New-Object System.Windows.Thickness 0,0,10,0; $dot.ToolTip = $stText
        [System.Windows.Controls.Grid]::SetColumn($dot, 1)

        $info = New-Object System.Windows.Controls.StackPanel
        $info.VerticalAlignment = "Center"
        $line = New-Object System.Windows.Controls.StackPanel; $line.Orientation = "Horizontal"
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $a.nick; $nm.Foreground = Brush "Ink"; $nm.FontSize = 15; $nm.FontWeight = "SemiBold"
        $line.Children.Add($nm) | Out-Null
        if ($a.isMain) {
            $badge = New-Object System.Windows.Controls.Border
            $badge.Background = Brush "Star"; $badge.CornerRadius = New-Object System.Windows.CornerRadius 4
            $badge.Padding = New-Object System.Windows.Thickness 6,1,6,1; $badge.Margin = New-Object System.Windows.Thickness 8,0,0,0
            $bt = New-Object System.Windows.Controls.TextBlock
            $bt.Text = "MAIN"; $bt.FontSize = 11; $bt.FontWeight = "Bold"; $bt.Foreground = Brush "OnStar"
            $badge.Child = $bt; $line.Children.Add($badge) | Out-Null
        }
        $issues = @(Get-SetupIssues $a)
        if ($issues.Count) {
            # Small amber chip; the tooltip says exactly what to do.
            $chip = New-Object System.Windows.Controls.Border
            $chip.Background = Brush "WarningBg"; $chip.BorderBrush = Brush "WarnEdge"; $chip.BorderThickness = New-Object System.Windows.Thickness 1
            $chip.CornerRadius = New-Object System.Windows.CornerRadius 4
            $chip.Padding = New-Object System.Windows.Thickness 6,0,6,1; $chip.Margin = New-Object System.Windows.Thickness 8,0,0,0
            $chip.VerticalAlignment = "Center"
            $ct = New-Object System.Windows.Controls.TextBlock
            $ct.Text = [string][char]0x26A0 + " setup ($($issues.Count))"; $ct.FontSize = 11; $ct.Foreground = Brush "WarningInk"
            $chip.Child = $ct
            $chip.ToolTip = ($issues | ForEach-Object { [string][char]0x2022 + " " + $_ }) -join "`n"
            [System.Windows.Controls.ToolTipService]::SetShowDuration($chip, 30000)
            [System.Windows.Automation.AutomationProperties]::SetName($chip, "Setup needed: " + ($issues -join " "))
            $line.Children.Add($chip) | Out-Null
        }
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = $stText; $sub.FontSize = 12; $sub.Foreground = Brush $dotColor
        $script:SubTexts[$a.nick.ToLower()] = @{ Tb = $sub; Acc = $a; Dot = $dot }
        $info.Children.Add($line) | Out-Null; $info.Children.Add($sub) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($info, 2)

        $star = New-Object System.Windows.Controls.Button
        $star.Style = $BtnStyle; $star.Content = $(if ($a.isMain) { [char]0x2605 } else { [char]0x2606 })
        $star.ToolTip = "Make this my main account"; $star.Foreground = Brush "Star"
        $star.Padding = New-Object System.Windows.Thickness 10,6,10,6; $star.Margin = New-Object System.Windows.Thickness 4,0,0,0
        $star.Tag = $a; $star.Add_Click({ param($s,$e) Set-Main $s.Tag })
        [System.Windows.Controls.Grid]::SetColumn($star, 3)

        $open = New-Object System.Windows.Controls.Button
        $open.Style = $BtnStyle; $open.Background = Brush "Accent"
        $open.Content = $(if ($winOf) { "Show" } elseif ($a.needsLogin) { "Sign in" } else { "Open" })
        $open.ToolTip = $(if ($winOf) { "Play this account's window" } elseif ($a.needsLogin) { "This account's Chrome profile is new on this PC. Sign in to Roblox once." } else { "Open just this account (uses the link on the right)" })
        $open.Padding = New-Object System.Windows.Thickness 12,6,12,6; $open.Margin = New-Object System.Windows.Thickness 4,0,0,0
        $open.Tag = $a
        $open.Add_Click({
            param($s,$e)
            $w2 = Get-WindowOf $s.Tag.nick
            if ($w2) { Play-Window $w2 } elseif ($s.Tag.needsLogin) { Start-SignIn @($s.Tag) } else { Open-Accounts @($s.Tag) }
        })
        [System.Windows.Controls.Grid]::SetColumn($open, 4)

        $more = New-Object System.Windows.Controls.Button
        $more.Style = $BtnStyle; $more.Content = [char]0x22EF; $more.ToolTip = "More"
        $more.Padding = New-Object System.Windows.Thickness 10,6,10,6; $more.Margin = New-Object System.Windows.Thickness 4,0,0,0
        $more.Tag = $a
        $more.Add_Click({
            param($s,$e)
            $acct = $s.Tag
            $menu = New-Object System.Windows.Controls.ContextMenu
            $menu.Style = $win.FindResource("DarkMenu")
            foreach ($it in @(
                @{ H = "Edit name / profile link"; A = "edit" },
                @{ H = $(if ($acct.autoJoin) { "Auto-click Play / Join: ON  (turn off)" } else { "Auto-click Play / Join: OFF  (turn on)" }); A = "autojoin" },
                @{ H = "Check Chrome setup"; A = "setup" },
                @{ H = "Set up auto-click helper"; A = "helper" },
                @{ H = "Log in again (opens Roblox login)"; A = "login" },
                @{ H = "Move up"; A = "up" },
                @{ H = "Move down"; A = "down" },
                @{ H = "Remove from list"; A = "remove" })) {
                $mi = New-Object System.Windows.Controls.MenuItem
                $mi.Header = $it.H; $mi.Tag = @{ Acc = $acct; Act = $it.A }
                $mi.Style = $win.FindResource("DarkItem")
                if ($it.A -eq "remove") { $mi.Foreground = Brush "DangerSoftInk" }
                $mi.Add_Click({
                    param($m,$x)
                    $t = $m.Tag
                    switch ($t.Act) {
                        "edit"   { Show-AccountDialog $t.Acc }
                        "helper" { Setup-Helper $t.Acc }
                        "setup"  { Show-SetupCheck $t.Acc }
                        "autojoin" {
                            $t.Acc.autoJoin = -not $t.Acc.autoJoin; Save-Settings
                            Update-AutoJoinBox; Update-LinkStatus; Render-Accounts; Render-ChromeSetup
                            Say "Auto-click is $(if ($t.Acc.autoJoin) { 'on' } else { 'off' }) for $($t.Acc.nick)."
                        }
                        "login"  { Start-SignIn @($t.Acc) }
                        "up"     { Move-Account $t.Acc -1 }
                        "down"   { Move-Account $t.Acc 1 }
                        "remove" { Remove-Account $t.Acc }
                    }
                })
                $menu.Items.Add($mi) | Out-Null
            }
            $menu.PlacementTarget = $s; $menu.IsOpen = $true
        })
        [System.Windows.Controls.Grid]::SetColumn($more, 5)

        foreach ($c in $cb, $dot, $info, $star, $open, $more) { $g.Children.Add($c) | Out-Null }
        $row.Child = $g
        $ui.AccountList.Children.Add($row) | Out-Null
    }
    Update-Buttons
    if ($ui.TabGroups.IsSelected) { Render-GroupsTab }   # members show live status
}

function Move-Account($acc, [int]$dir) {
    $list = New-Object System.Collections.ArrayList
    foreach ($x in $script:State.accounts) { $list.Add($x) | Out-Null }
    $i = -1; for ($k = 0; $k -lt $list.Count; $k++) { if (Same $list[$k] $acc) { $i = $k } }
    $j = $i + $dir
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $list.Count) { return }
    $tmp = $list[$j]; $list[$j] = $list[$i]; $list[$i] = $tmp
    $script:State.accounts = @($list)
    Save-Settings; Render-Accounts
}

function Set-Main($acc) {
    foreach ($x in $script:State.accounts) { $x.isMain = $false }
    $acc.isMain = $true
    Save-Settings; Render-Accounts
    Apply-Efficiency
    Update-LinkStatus
    if ([string]::IsNullOrWhiteSpace($acc.profileUrl)) {
        Say "$($acc.nick) is now your main. Tip: add its Roblox profile link (... > Edit) so alts can join its server."
    } else { Say "$($acc.nick) is now your main." }
}

function Remove-Account($acc) {
    $inGroups = @($script:State.groups | Where-Object { @($_.nicks) -contains $acc.nick } | ForEach-Object { $_.name })
    $groupNote = $(if ($inGroups.Count) { "`n`nIt is also taken out of: " + ($inGroups -join ", ") + "." } else { "" })
    $r = [BkBox]::Show("Remove $($acc.nick) from the list?`n`nThis only removes it from this app. The Chrome profile stays.$groupNote", "Remove account", "YesNo", "Question")
    if ($r -ne "Yes") { return }
    Remove-AccountRecord $script:State $acc
    Render-Groups
    Save-Settings; Render-Accounts
    Say "Removed $($acc.nick)."
}

function Setup-Helper($acc) {
    if (-not (Test-Path (Join-Path $HelperDir "manifest.json"))) {
        [BkBox]::Show("I can't find the AutoJoinHelper folder. Keep it next to BloxKit.ps1.", "Helper missing", "OK", "Warning") | Out-Null
        return
    }
    try { Set-Clipboard -Value $HelperDir } catch {}
    Open-Chrome $acc "chrome://extensions" | Out-Null
    [BkBox]::Show(
        "Chrome just opened the Extensions page for $($acc.nick).`n`n" +
        "ALREADY INSTALLED? Find 'BloxKit Auto-Join Helper' (older copies are called 'BloxKit' or 'Roblox Launcher Auto-Join Helper') " +
        "and click its round reload arrow. That loads the new version (2.2, which can also close the launch tab).`n`n" +
        "NOT INSTALLED YET? Do this once:`n" +
        "1. Turn ON 'Developer mode' (switch at the top right).`n" +
        "2. Click 'Load unpacked'.`n" +
        "3. In the folder box, press Ctrl+V and then Enter.`n" +
        "    (The helper's folder is already copied for you.)`n" +
        "4. Click 'Select Folder'.`n`nRepeat this for each account.",
        "Set up auto-click for $($acc.nick)", "OK", "Information") | Out-Null
}

function Show-SetupCheck($acc) {
    $script:SetupCache.Remove($acc.profileDir)
    $s = Get-SetupFor $acc
    $helper = $(switch ($s.Helper) {
        "on" { "installed and on" + $(if ($s.HelperVersion) { ", version $($s.HelperVersion)" } else { " (older than 2.2)" }) } "off" { "installed but turned off" } "missing" { "not installed" }
        "elsewhere" { "loaded from another folder: $($s.HelperPath)" } default { "can't tell" } })
    $allow = $(switch ($s.AlwaysAllow) { "yes" { "yes" } "no" { "not yet" } default { "can't tell" } })
    $issues = @(Get-SetupIssues $acc)
    $msg = "Chrome profile: $($acc.profileDir)" + $(if ($s.Exists) { "" } else { " (not created yet)" }) + "`n" +
           "Auto-click helper: $helper" + $(if (-not $acc.autoJoin) { " (auto-click is off, so it isn't needed)" } else { "" }) + "`n" +
           "'Always allow' Roblox to open: $allow`n`n" +
           $(if ($issues.Count) { "To do:`n- " + ($issues -join "`n- ") } else { "Nothing to do. This account is set up." }) +
           "`n`nRead from Chrome's own files. This app never changes them."
    [BkBox]::Show($msg, "Chrome setup for $($acc.nick)", "OK", $(if ($issues.Count) { "Warning" } else { "Information" })) | Out-Null
}

function Update-AutoJoinBox {
    # The Accounts tab box: ticked = all accounts, empty = none, dash = some.
    $ui.AutoJoinBox.IsChecked = $(switch (Get-AutoJoinSummary $script:State) { "all" { $true } "none" { $false } default { $null } })
}

function Get-HelperFolderVersion {
    $m = Read-JsonFile (Join-Path $HelperDir "manifest.json")
    return $(if ($m) { "" + $m.version } else { "" })
}

function Render-ChromeSetup {
    # Settings > Chrome setup: every account's auto-click switch and what its Chrome profile has.
    $v = Get-HelperFolderVersion
    $ui.CsHint.Text = $(if ($v) { "Helper files: version $v in $HelperDir" } else { [string][char]0x26A0 + "  The AutoJoinHelper folder is missing. Keep it next to BloxKit.ps1." })
    $ui.CsHint.Foreground = Brush $(if ($v) { "Muted" } else { "DangerInk" })
    $ui.CsList.Children.Clear()
    $tabs = $script:State.tabCloseWhen -ne "off"
    foreach ($a in @($script:State.accounts)) {
        $s = Get-SetupFor $a
        $row = New-Object System.Windows.Controls.Border
        $row.Background = Brush "SurfaceAlt"; $row.CornerRadius = New-Object System.Windows.CornerRadius 8
        $row.Padding = New-Object System.Windows.Thickness 10,7,8,7; $row.Margin = New-Object System.Windows.Thickness 0,0,0,6
        $dock = New-Object System.Windows.Controls.DockPanel
        # the one button that fixes what's missing first
        $fix = $(if ($a.needsLogin) { @("Sign in", "login") }
                 elseif ($a.autoJoin -or $tabs) { $(switch ($s.Helper) { "missing" { @("Set up helper", "helper") } "elsewhere" { @("Set up helper", "helper") } "off" { @("How to turn on", "check") }
                                                    default { $(if ($tabs -and $s.Helper -eq "on" -and -not (Test-HelperCanCloseTabs $s.HelperVersion)) { @("Reload helper", "helper") } else { @("Details", "check") }) } }) }
                 else { @("Details", "check") })
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $BtnStyle; $btn.Content = $fix[0]; $btn.Padding = New-Object System.Windows.Thickness 10,5,10,5; $btn.Margin = New-Object System.Windows.Thickness 8,0,0,0
        if ($fix[1] -ne "check") { $btn.Background = Brush "Accent" }
        $btn.Tag = @{ Acc = $a; Act = $fix[1] }
        [System.Windows.Automation.AutomationProperties]::SetName($btn, "$($fix[0]) for $($a.nick)")
        $btn.Add_Click({ param($x,$e)
            switch ($x.Tag.Act) { "login" { Start-SignIn @($x.Tag.Acc) } "helper" { Setup-Helper $x.Tag.Acc } default { Show-SetupCheck $x.Tag.Acc } }
            $script:SetupCache = @{}; Render-ChromeSetup })
        [System.Windows.Controls.DockPanel]::SetDock($btn, "Right")
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.IsChecked = [bool]$a.autoJoin; $cb.VerticalAlignment = "Center"; $cb.Width = 170; $cb.Tag = $a
        $nm = New-Object System.Windows.Controls.TextBlock; $nm.Text = $a.nick + $(if ($a.isMain) { "  " + [char]0x2605 } else { "" }); $nm.Foreground = Brush "Ink"; $nm.TextTrimming = "CharacterEllipsis"
        $cb.Content = $nm; $cb.ToolTip = "Auto-click Play / Join for $($a.nick)"
        [System.Windows.Automation.AutomationProperties]::SetName($cb, "Auto-click for $($a.nick)")
        $cb.Add_Checked({ param($x,$e) if (-not $x.Tag.autoJoin) { $x.Tag.autoJoin = $true; Save-Settings; Update-AutoJoinBox; Update-LinkStatus; Render-Accounts } })
        $cb.Add_Unchecked({ param($x,$e) if ($x.Tag.autoJoin) { $x.Tag.autoJoin = $false; Save-Settings; Update-AutoJoinBox; Update-LinkStatus; Render-Accounts } })
        [System.Windows.Controls.DockPanel]::SetDock($cb, "Left")
        $chips = New-Object System.Windows.Controls.WrapPanel; $chips.VerticalAlignment = "Center"
        $ok = "Success"; $bad = "WarningInk"; $na = "Muted"
        $needHelper = $a.autoJoin -or $tabs
        $add = { param($text, $color, $tip) $chip = New-Chip $text $color; $chip.Margin = New-Object System.Windows.Thickness 0,2,6,2; $chip.ToolTip = $tip; $chips.Children.Add($chip) | Out-Null }
        if ($s.Exists) { & $add ("profile " + [char]0x2713) $ok "Chrome profile '$($a.profileDir)' is on this PC." }
        else { & $add "profile: new" $bad "Chrome profile '$($a.profileDir)' isn't on this PC yet; Chrome makes it the first time." }
        if ($a.needsLogin) { & $add "needs sign-in" $bad "Sign in to Roblox once in this Chrome profile." }
        else { & $add "signed in" $ok "Roblox has opened for this account on this PC, or you confirmed the sign-in." }
        switch ($s.Helper) {
            "on" {
                $hv = $(if ($s.HelperVersion) { $s.HelperVersion } else { "older than 2.2" })
                & $add "helper $hv" $(if ($tabs -and -not (Test-HelperCanCloseTabs $s.HelperVersion)) { $bad } else { $ok }) "Auto-click helper is installed and on."
            }
            "off"       { & $add "helper off" $(if ($needHelper) { $bad } else { $na }) "The helper is installed but turned off in chrome://extensions." }
            "elsewhere" { & $add "helper: other folder" $(if ($needHelper) { $bad } else { $na }) "Loaded from $($s.HelperPath). Load it again from this app's folder." }
            "missing"   { & $add "no helper" $(if ($needHelper) { $bad } else { $na }) "The auto-click helper isn't installed in this profile." }
            default     { & $add "helper: can't tell" $na "Chrome's files couldn't be read." }
        }
        switch ($s.AlwaysAllow) {
            "yes"   { & $add ("always allow " + [char]0x2713) $ok "Chrome opens Roblox without asking." }
            "no"    { & $add "will ask 'Open Roblox?'" $bad "The first time, tick 'Always allow' and click Open." }
            default { & $add "always allow: can't tell" $na "Chrome's files couldn't be read." }
        }
        foreach ($c in $btn, $cb, $chips) { $dock.Children.Add($c) | Out-Null }
        $row.Child = $dock
        $ui.CsList.Children.Add($row) | Out-Null
    }
    if (-not @($script:State.accounts).Count) {
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = "No accounts yet."; $t.Foreground = Brush "Muted"
        $ui.CsList.Children.Add($t) | Out-Null
    }
}

function Start-SignIn($accs) {
    # Opens each account's Chrome on the Roblox login page, one at a time.
    # The app never sees or stores passwords; you sign in yourself, in Chrome.
    foreach ($a in @($accs)) {
        if (-not (Open-Chrome $a "https://www.roblox.com/login")) { return }
        $r = [BkBox]::Show(
            "Chrome opened for $($a.nick).`n`n" +
            "Sign in to Roblox there as $($a.nick). Chrome remembers it after that.`n" +
            "Faster: on the login page pick 'Quick Login' (or 'Another logged in device') and approve the code on a phone or PC where you're already signed in.`n`n" +
            "Yes = I'm signed in     No = skip this one     Cancel = stop",
            "Sign in $($a.nick)", "YesNoCancel", "Information")
        if ($r -eq "Yes") { $a.needsLogin = $false; Save-Settings; Render-Accounts; Say "$($a.nick) is signed in." }
        elseif ($r -eq "Cancel") { break }
    }
    $left = @($script:State.accounts | Where-Object { $_.needsLogin }).Count
    if ($left) { Say "$left account(s) still need to sign in. Click 'Sign in' on them when you're ready." }
}

function Show-AccountDialog($existing) {
    $isEdit = $null -ne $existing
    [xml]$dx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add account" Width="460" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="{StaticResource Surface}" FontFamily="Segoe UI" FontSize="14">
  <StackPanel Margin="20">
    <TextBlock x:Name="DTitle" Text="Add an account" Foreground="{StaticResource Ink}" FontSize="18" FontWeight="Bold" Margin="0,0,0,14"/>
    <TextBlock Text="Nickname (anything that helps you, like Main or Alt1)" Foreground="{StaticResource InkSoft}" Margin="0,0,0,4"/>
    <TextBox x:Name="NickBox" Background="{StaticResource Input}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}" Padding="8,7" CaretBrush="{StaticResource Ink}"/>
    <TextBlock Text="Roblox profile link (optional)" Foreground="{StaticResource InkSoft}" Margin="0,14,0,2"/>
    <TextBlock Text="Needed for your main, so alts can join its server. Open the profile on roblox.com and copy the link." Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,4"/>
    <TextBox x:Name="UrlBox" Background="{StaticResource Input}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}" Padding="8,7" CaretBrush="{StaticResource Ink}"/>
    <StackPanel x:Name="ProfilePanel">
      <TextBlock Text="Which Chrome should this account use?" Foreground="{StaticResource InkSoft}" Margin="0,16,0,6"/>
      <RadioButton x:Name="NewRadio" Content="A new Chrome profile just for this account (recommended)" Foreground="{StaticResource Ink}" IsChecked="True" Margin="0,0,0,6"/>
      <RadioButton x:Name="OldRadio" Content="A Chrome profile I already have:" Foreground="{StaticResource Ink}"/>
      <ComboBox x:Name="ProfileCombo" Margin="22,6,0,0" IsEnabled="False"/>
    </StackPanel>
    <TextBlock x:Name="DError" Foreground="{StaticResource DangerInk}" TextWrapping="Wrap" Margin="0,12,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="CancelBtn" Content="Cancel" Padding="16,8" Margin="0,0,8,0" Background="{StaticResource Raised}" Foreground="{StaticResource Ink}" BorderThickness="0"/>
      <Button x:Name="SaveBtn" Content="Add and open Chrome" Padding="16,8" Background="{StaticResource Accent}" Foreground="{StaticResource Ink}" BorderThickness="0" FontWeight="SemiBold"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    Initialize-BkDialog $dlg
    $d = @{}
    foreach ($n in "DTitle","NickBox","UrlBox","ProfilePanel","NewRadio","OldRadio","ProfileCombo","DError","CancelBtn","SaveBtn") { $d[$n] = $dlg.FindName($n) }
    $profiles = @(Get-ChromeProfiles)
    foreach ($p in $profiles) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = "$($p.Name)   ($($p.Dir))"; $item.Tag = $p.Dir
        $d.ProfileCombo.Items.Add($item) | Out-Null
    }
    if ($profiles.Count -gt 0) { $d.ProfileCombo.SelectedIndex = 0 } else { $d.OldRadio.IsEnabled = $false }
    $d.OldRadio.Add_Checked({ $d.ProfileCombo.IsEnabled = $true })
    $d.NewRadio.Add_Checked({ $d.ProfileCombo.IsEnabled = $false })
    if ($isEdit) {
        $dlg.Title = "Edit account"; $d.DTitle.Text = "Edit $($existing.nick)"
        $d.NickBox.Text = $existing.nick; $d.UrlBox.Text = $existing.profileUrl
        $d.ProfilePanel.Visibility = "Collapsed"; $d.SaveBtn.Content = "Save"
    } else {
        $d.NickBox.Text = Get-DefaultNick $script:State
    }
    $dlg.Add_ContentRendered({ $d.NickBox.Focus() | Out-Null; $d.NickBox.SelectAll() })   # typing replaces the suggested name
    $d.CancelBtn.Add_Click({ $dlg.Close() })
    $d.SaveBtn.Add_Click({
        $nick = $d.NickBox.Text.Trim(); $url = $d.UrlBox.Text.Trim()
        if ($nick -eq "") { $d.DError.Text = "Please type a nickname."; return }
        $dupe = @($script:State.accounts | Where-Object { $_.nick -ieq $nick -and -not (Same $_ $existing) })
        if ($dupe.Count -gt 0) { $d.DError.Text = "You already have an account called $nick."; return }
        if ($url -ne "") {
            $info = Get-LinkInfo $url
            if ($info.Kind -ne "profile") { $d.DError.Text = "That profile link doesn't look right. It should look like roblox.com/users/12345/profile"; return }
            $url = $info.Url
        }
        if ($isEdit) {
            $old = $existing.nick
            Set-AccountNick $script:State $existing $nick
            $existing.profileUrl = $url
            foreach ($w in $script:Wins) { if ($w.Nick -ieq $old) { $w.Nick = $nick; $w.Name = $nick } }
            Move-NickKey $script:AccStatus $old $nick; Move-NickKey $script:RejoinLog $old $nick; Move-NickKey $script:LastServer $old $nick
            Save-Settings; Render-Accounts; Render-Groups; Build-Wall
            Say "Saved $nick."; $dlg.Close(); return
        }
        if ($d.OldRadio.IsChecked) { $dir = $d.ProfileCombo.SelectedItem.Tag }
        else {
            $base = "RobloxLauncher_" + (Get-SafeName $nick); $dir = $base; $i = 2
            while ((Test-Path (Join-Path $ChromeData $dir)) -or @($script:State.accounts | Where-Object { $_.profileDir -eq $dir }).Count -gt 0) { $dir = "$base$i"; $i++ }
        }
        $isFirst = (@($script:State.accounts).Count -eq 0)
        $acc = New-Account $nick $dir
        $acc.profileUrl = $url; $acc.isMain = $isFirst; $acc.checked = (-not $isFirst); $acc.autoJoin = [bool]$script:State.autoJoin   # starts like your last "all accounts" choice
        $script:State.accounts = @($script:State.accounts) + $acc
        Save-Settings; Render-Accounts; $dlg.Close()
        if ($d.OldRadio.IsChecked) {
            Open-Chrome $acc "https://www.roblox.com/home" | Out-Null
            Say "Added $nick. If Chrome isn't logged in to Roblox yet, log in as $nick there."
        } else {
            Open-Chrome $acc "https://www.roblox.com/login" | Out-Null
            [BkBox]::Show("A new Chrome window just opened.`n`nLog in to Roblox there as $nick. You only do this once. Chrome will remember it.", "One last step", "OK", "Information") | Out-Null
            Say "Added $nick. Log in once in the Chrome window that opened."
        }
    })
    $dlg.ShowDialog() | Out-Null
}

# ----- link box, favorites, groups -----
# Player names for profile links, from Roblox's public users API (no login needed).
# Looked up in the background so typing never freezes; cached for the session.
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(6)
$script:UserNames = @{}      # user id -> "Display (@name)", or "" if the lookup failed
$script:NameJob = $null      # @{ Id; Task }
$NameTimer = New-Object System.Windows.Threading.DispatcherTimer
$NameTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$NameTimer.Add_Tick({
    $j = $script:NameJob
    if (-not $j -or -not $j.Task.IsCompleted) { return }
    $NameTimer.Stop(); $script:NameJob = $null
    $name = ""
    try {
        $u = $j.Task.Result | ConvertFrom-Json
        $name = $(if ($u.displayName -and $u.displayName -ne $u.name) { "$($u.displayName) (@$($u.name))" } else { "@$($u.name)" })
    } catch {}
    $script:UserNames[$j.Id] = $name
    Update-LinkStatus
})
function Request-UserName([string]$id) {
    if (-not $id -or $script:UserNames.ContainsKey($id) -or ($script:NameJob -and $script:NameJob.Id -eq $id)) { return }
    $script:NameJob = @{ Id = $id; Task = $script:Http.GetStringAsync("https://users.roblox.com/v1/users/$id") }
    $NameTimer.Start()
}

function Get-LinkStatusText($info) {
    # Says in plain words where the opened accounts will go.
    $main = Get-Main
    $mainInfo = $(if ($main -and $main.profileUrl) { Get-LinkInfo $main.profileUrl } else { $null })
    switch ($info.Kind) {
        "profile" {
            $joinable = " They need to be in a game your accounts are allowed to join."
            if ($info.UserId -and $mainInfo -and $mainInfo.UserId -eq $info.UserId) {
                return "$($main.nick)'s profile (your main). Accounts will join $($main.nick)'s server." + $joinable
            }
            if (-not $info.UserId) { return "Profile share link. Accounts will join that player's server." + $joinable }
            Request-UserName $info.UserId
            if (-not $script:UserNames.ContainsKey($info.UserId)) { return "Profile link (user $($info.UserId)). Looking up the name..." }
            $who = $script:UserNames[$info.UserId]
            if (-not $who) { $who = "user $($info.UserId)" }
            return "Profile of $who. Accounts will join their server." + $joinable
        }
        "game" {
            $t = "$($info.Label). " + $(if ($script:State.spread -gt 0) { "Accounts are spread over servers with room, up to $($script:State.spread) per server." } else { "Accounts join a random server of this game." })
            if ($mainInfo -and $mainInfo.Kind -eq "profile") { $t += " To join $($main.nick)'s server instead, click 'Use my main's server'." }
            return $t
        }
        "private" { return "$($info.Label). Accounts join this private server." }
        default   { return "$($info.Label)." }
    }
}

function Update-LinkStatus {
    $info = Get-LinkInfo $ui.LinkBox.Text
    $ui.LinkPlaceholder.Visibility = $(if ($ui.LinkBox.Text -eq "") { "Visible" } else { "Collapsed" })
    $how = $(switch (Get-AutoJoinSummary $script:State) { "all" { " The helper will start the game." } "some" { " The helper starts the game for accounts with auto-click on; click Play / Join in the others." } default { " You'll click Play / Join in each window." } })
    switch ($info.Kind) {
        "empty" { $ui.LinkStatus.Text = "Nothing pasted yet."; $ui.LinkStatus.Foreground = Brush "Muted" }
        "bad"   { $ui.LinkStatus.Text = [string][char]0x26A0 + "  " + $info.Label; $ui.LinkStatus.Foreground = Brush "DangerInk" }
        "other" { $ui.LinkStatus.Text = [string][char]0x26A0 + "  " + $info.Label; $ui.LinkStatus.Foreground = Brush "CautionInk" }
        default { $ui.LinkStatus.Text = [string][char]0x2713 + "  " + (Get-LinkStatusText $info) + $how; $ui.LinkStatus.Foreground = Brush "SuccessInk" }
    }
    Update-SpreadPanel
    Update-Buttons
}

function Update-SpreadPanel {
    # Only game links have a choice of server (profile links follow a player, private links are one server).
    $ui.SpreadPanel.Visibility = $(if ((Get-LinkInfo $ui.LinkBox.Text).Kind -eq "game") { "Visible" } else { "Collapsed" })
    $on = $script:State.spread -gt 0
    $ui.SpreadHint.Text = $(if ($on) { "Picks public servers with room (emptiest first, like the game page's server list). Needs auto-click and the helper; the others go where Roblox puts them. Each account's status says whether it landed on the planned server." } else { "" })
    $ui.SpreadHint.Visibility = $(if ($on) { "Visible" } else { "Collapsed" })
}

function Render-Favorites {
    $script:FillingFav = $true
    $ui.FavBox.Items.Clear()
    foreach ($f in @($script:State.favorites)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = $f.name; $it.Tag = $f; $it.ToolTip = $f.url
        $ui.FavBox.Items.Add($it) | Out-Null
    }
    $ui.FavBox.SelectedIndex = -1
    $ui.DelFavBtn.IsEnabled = $false
    $script:FillingFav = $false
}

function Render-Groups {
    $script:FillingGroup = $true
    $ui.GroupBox.Items.Clear()
    foreach ($g in @($script:State.groups)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = "$($g.name)  ($(@($g.nicks).Count))"; $it.Tag = $g; $it.ToolTip = (@($g.nicks) -join ", ")
        $ui.GroupBox.Items.Add($it) | Out-Null
    }
    $ui.GroupBox.SelectedIndex = -1
    $ui.DelGroupBtn.IsEnabled = $false
    $script:FillingGroup = $false
    Render-GroupsTab
    Render-ScheduleTab   # step names and the add-group list
}

function Update-Buttons {
    $accs = @($script:State.accounts)
    $alts = @($accs | Where-Object { -not $_.isMain })
    $main = Get-Main
    $ticked = @($accs | Where-Object { $_.checked }).Count
    $busy = $script:QBusy
    $info = Get-LinkInfo $ui.LinkBox.Text
    $linkOk = @("game","private","share","profile","other") -contains $info.Kind
    $ui.OpenTickedBtn.Content = "Open ticked accounts ($ticked)"
    $ui.OpenAltsBtn.Content = "Open ALL alts ($($alts.Count))"
    $ui.OpenTickedBtn.IsEnabled = (-not $busy) -and $ticked -gt 0
    $ui.OpenAltsBtn.IsEnabled = (-not $busy) -and $alts.Count -gt 0
    $ui.StartAllBtn.IsEnabled = (-not $busy) -and $main -and $alts.Count -gt 0
    $ui.TickAltsBtn.IsEnabled = $alts.Count -gt 0
    $ui.UntickBtn.IsEnabled = $accs.Count -gt 0
    $ui.SaveGroupBtn.IsEnabled = $ticked -gt 0
    $ui.SaveFavBtn.IsEnabled = $linkOk
    $ui.MainServerBtn.IsEnabled = [bool]($main -and -not [string]::IsNullOrWhiteSpace($main.profileUrl))
    $ui.MainServerBtn.ToolTip = $(if ($ui.MainServerBtn.IsEnabled) { "Fills in $($main.nick)'s profile link so alts join its server" } else { "Star your main and add its Roblox profile link first (... > Edit)" })
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($ui.MainServerBtn, $true)
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($ui.StartAllBtn, $true)
    $ui.StartAllBtn.ToolTip = "Opens your main with the link above. When it's in the game, all alts open one by one and join its server."
}

# ============================================================= GROUPS TAB ==
# Left: the groups. Middle: the picked group's members, live. Right: open it.
$script:SelGroupId = ""
$GroupStatusColor = @{ "Draft" = "Muted"; "Ready" = "Success"; "Running" = "Success"; "Partly open" = "Accent"; "Opening" = "Accent"; "Needs setup" = "Warning" }

function Get-AccInfo {
    # What the app knows about each account right now (lower-case nick -> @{ Running; Ready; Groups }).
    $info = @{}
    foreach ($a in @($script:State.accounts)) {
        $info[$a.nick.ToLower()] = @{
            Running = [bool](Get-WindowOf $a.nick)
            Ready   = (-not $a.needsLogin) -and @(Get-SetupIssues $a).Count -eq 0
            Groups  = @($script:State.groups | Where-Object { @($_.nicks) -icontains $a.nick } | ForEach-Object { $_.name })
        }
    }
    return $info
}
function Get-SelectedGroup { @($script:State.groups | Where-Object { $_.id -eq $script:SelGroupId }) | Select-Object -First 1 }
function Test-GroupOpening($g) {
    # True while the launch queue is opening one of its members.
    if (-not $script:QBusy) { return $false }
    $busy = @($script:Q | ForEach-Object { $_.Acc.nick }) + @($(if ($script:QCur) { $script:QCur.Acc.nick }))
    return [bool]@($busy | Where-Object { @($g.nicks) -icontains $_ }).Count
}
function New-Chip([string]$text, [string]$color) {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = New-Object System.Windows.CornerRadius 4
    $b.Padding = New-Object System.Windows.Thickness 6,0,6,1; $b.Margin = New-Object System.Windows.Thickness 8,0,0,0
    $b.BorderThickness = New-Object System.Windows.Thickness 1; $b.BorderBrush = Brush $color; $b.VerticalAlignment = "Center"
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = 11; $t.Foreground = Brush $color
    $b.Child = $t
    return $b
}

function Render-GroupsTab {
    $groups = @($script:State.groups)
    if ($groups.Count -and -not (Get-SelectedGroup)) { $script:SelGroupId = $groups[0].id }
    if (-not $groups.Count) { $script:SelGroupId = "" }
    $info = Get-AccInfo
    $ui.TabGroups.Header = "Groups ($($groups.Count))"
    $ui.GroupEmpty.Visibility = $(if ($groups.Count) { "Collapsed" } else { "Visible" })

    # ---- the list of groups ----
    $ui.GroupList.Children.Clear()
    foreach ($g in $groups) {
        $sum = Get-GroupSummary $g $script:State.accounts $info (Test-GroupOpening $g)
        $sel = $g.id -eq $script:SelGroupId
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $BtnStyle; $btn.HorizontalContentAlignment = "Stretch"
        $btn.Background = Brush $(if ($sel) { "AccentSoft" } else { "SurfaceAlt" })
        $btn.BorderBrush = Brush $(if ($sel) { "Accent" } else { "Transparent" })
        $btn.Padding = New-Object System.Windows.Thickness 12,9,12,9; $btn.Margin = New-Object System.Windows.Thickness 0,0,0,6
        $sp = New-Object System.Windows.Controls.StackPanel
        $l1 = New-Object System.Windows.Controls.DockPanel
        $chip = New-Chip $(if ($sum.Status -eq "Running" -or $sum.Status -eq "Partly open") { "$($sum.Status) $($sum.Running)/$($sum.Members)" } else { $sum.Status }) $GroupStatusColor[$sum.Status]
        [System.Windows.Controls.DockPanel]::SetDock($chip, "Right")
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $g.name; $nm.FontWeight = "SemiBold"; $nm.FontSize = 15; $nm.Foreground = Brush "Ink"; $nm.TextTrimming = "CharacterEllipsis"
        $l1.Children.Add($chip) | Out-Null; $l1.Children.Add($nm) | Out-Null
        $l2 = New-Object System.Windows.Controls.TextBlock
        $l2.FontSize = 12; $l2.Foreground = Brush "Muted"; $l2.Margin = New-Object System.Windows.Thickness 0,2,0,0
        $l2.Text = "$($sum.Members) account" + $(if ($sum.Members -ne 1) { "s" } else { "" }) + $(if ($sum.HasMain) { "  " + [char]0x00B7 + "  " + [char]0x2605 + " main" } else { "" })
        $sp.Children.Add($l1) | Out-Null; $sp.Children.Add($l2) | Out-Null
        $tag = Get-GroupScheduleTag $g $script:Run $script:State.plan $script:State.groups (Get-Mono)
        if ($tag) {
            $l3 = New-Object System.Windows.Controls.TextBlock
            $l3.Text = $tag; $l3.FontSize = 12; $l3.Foreground = Brush "Focus"; $l3.Margin = New-Object System.Windows.Thickness 0,2,0,0
            $sp.Children.Add($l3) | Out-Null
        }
        $btn.Content = $sp; $btn.Tag = $g
        [System.Windows.Automation.AutomationProperties]::SetName($btn, "$($g.name): $($sum.Members) accounts, $($sum.Status)")
        $btn.Add_Click({ param($s,$e) $script:SelGroupId = $s.Tag.id; Render-GroupsTab })
        $ui.GroupList.Children.Add($btn) | Out-Null
    }

    # ---- the picked group ----
    $g = Get-SelectedGroup
    $has = [bool]$g
    foreach ($b in $ui.GRenameBtn, $ui.GCopyBtn, $ui.GDeleteBtn, $ui.GEditBtn, $ui.GTickBtn) { $b.IsEnabled = $has }
    $idx = $(if ($has) { [Array]::IndexOf(@($groups), $g) } else { -1 })
    $ui.GUpBtn.IsEnabled = $has -and $idx -gt 0
    $ui.GDownBtn.IsEnabled = $has -and $idx -lt $groups.Count - 1
    $ui.GMemberList.Children.Clear()
    $ui.GProblems.Text = ""
    if (-not $has) {
        $ui.GName.Text = "No group picked"; $ui.GSummary.Text = ""
        $ui.GMemberEmpty.Text = "Make a group on the left."; $ui.GMemberEmpty.Visibility = "Visible"
        $ui.GOpenBtn.IsEnabled = $false; $ui.GOpenHint.Text = "Pick a group first."
        return
    }
    $sum = Get-GroupSummary $g $script:State.accounts $info (Test-GroupOpening $g)
    $ui.GName.Text = $g.name
    $ui.GSummary.Text = "$($sum.Members) account(s), $($sum.Running) open" + $(if ($sum.HasMain) { ", includes your main" } else { "" }) + "  " + [char]0x00B7 + "  $($sum.Status)"
    $gt = Get-GroupScheduleTag $g $script:Run $script:State.plan $script:State.groups (Get-Mono)
    if ($gt) { $ui.GSummary.Text += "  " + [char]0x00B7 + "  " + $gt }
    $members = @($script:State.accounts | Where-Object { @($g.nicks) -icontains $_.nick })
    $ui.GMemberEmpty.Text = "Nobody in this group yet. Click 'Edit members'."
    $ui.GMemberEmpty.Visibility = $(if ($members.Count) { "Collapsed" } else { "Visible" })
    $problems = @()
    foreach ($a in $members) {
        $st = Get-AccStatusInfo $a
        $row = New-Object System.Windows.Controls.Border
        $row.Background = Brush "SurfaceAlt"; $row.CornerRadius = New-Object System.Windows.CornerRadius 8
        $row.Padding = New-Object System.Windows.Thickness 10,8,8,8; $row.Margin = New-Object System.Windows.Thickness 0,0,0,6
        $dock = New-Object System.Windows.Controls.DockPanel
        $rm = New-Object System.Windows.Controls.Button
        $rm.Style = $BtnStyle; $rm.Content = "Remove"; $rm.Padding = New-Object System.Windows.Thickness 10,5,10,5
        $rm.ToolTip = "Take $($a.nick) out of this group. The account stays."
        $rm.Tag = @{ G = $g; Nick = $a.nick }
        $rm.Add_Click({ param($s,$e)
            Remove-GroupMember $s.Tag.G $s.Tag.Nick; Save-Settings; Render-Groups
            Say "Took $($s.Tag.Nick) out of '$($s.Tag.G.name)'. The account is still on the Accounts tab." })
        [System.Windows.Controls.DockPanel]::SetDock($rm, "Right")
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 10; $dot.Height = 10; $dot.Fill = Brush $st.Color; $dot.VerticalAlignment = "Center"
        $dot.Margin = New-Object System.Windows.Thickness 0,0,10,0
        [System.Windows.Controls.DockPanel]::SetDock($dot, "Left")
        $txt = New-Object System.Windows.Controls.StackPanel
        $l1 = New-Object System.Windows.Controls.StackPanel; $l1.Orientation = "Horizontal"
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $a.nick; $nm.FontWeight = "SemiBold"; $nm.Foreground = Brush "Ink"
        $l1.Children.Add($nm) | Out-Null
        if ($a.isMain) { $l1.Children.Add((New-Chip "MAIN" "Star")) | Out-Null }
        $issues = @(Get-SetupIssues $a)
        if ($a.needsLogin) { $issues = @("Needs to sign in on this PC.") + $issues }
        if ($issues.Count) { $c = New-Chip ([string][char]0x26A0 + " setup") "WarningInk"; $c.ToolTip = $issues -join "`n"; $l1.Children.Add($c) | Out-Null; $problems += "$($a.nick): " + $issues[0] }
        $others = @($info[$a.nick.ToLower()].Groups | Where-Object { $_ -ne $g.name })
        $l2 = New-Object System.Windows.Controls.TextBlock
        $l2.FontSize = 12; $l2.Foreground = Brush $st.Color; $l2.TextTrimming = "CharacterEllipsis"
        $l2.Text = $st.Text + $(if ($others.Count) { "   |   also in: " + ($others -join ", ") } else { "" })
        $txt.Children.Add($l1) | Out-Null; $txt.Children.Add($l2) | Out-Null
        foreach ($c in $rm, $dot, $txt) { $dock.Children.Add($c) | Out-Null }
        $row.Child = $dock
        $ui.GMemberList.Children.Add($row) | Out-Null
    }

    # ---- open it ----
    $closed = @($members | Where-Object { -not (Get-WindowOf $_.nick) })
    $link = Get-LinkInfo $ui.LinkBox.Text
    $ui.GOpenBtn.Content = $(if ($closed.Count -eq $members.Count) { "Open all $($closed.Count)" } else { "Open the $($closed.Count) not open" })
    $ui.GOpenBtn.IsEnabled = $closed.Count -gt 0 -and -not $script:QBusy -and @("empty", "bad") -notcontains $link.Kind
    $ui.GOpenHint.Text = $(if (@("empty", "bad") -contains $link.Kind) { "Paste a game, private server or profile link on the Accounts tab first." }
                           elseif ($script:QBusy) { "Accounts are opening right now. Wait until that's done." }
                           elseif ($closed.Count -eq 0) { "Everyone in this group is open." }
                           else { "Opens them one at a time, with the link on the Accounts tab: " + (Get-LinkStatusText $link) })
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($ui.GOpenBtn, $true)
    $ui.GOpenBtn.ToolTip = $ui.GOpenHint.Text
    if ($problems.Count) { $ui.GProblems.Text = [string][char]0x26A0 + "  Not ready yet:`n" + (($problems | ForEach-Object { [string][char]0x2022 + " " + $_ }) -join "`n") }
}

function Confirm-DeleteGroup($g) {
    $inPlan = @($script:State.plan.steps | Where-Object { $_.groupId -eq $g.id }).Count
    $r = [BkBox]::Show("Delete the group '$($g.name)'?`n`nOnly the group is deleted. Its $(@($g.nicks).Count) account(s) stay on the Accounts tab." +
        $(if ($inPlan) { "`n`nIt's used in the schedule ($inPlan step(s)). Those steps will need another group before the schedule can start." } else { "" }), "Delete group", "YesNo", "Warning")
    if ($r -ne "Yes") { return }
    Remove-Group $script:State $g
    Save-Settings; Render-Groups
    Say "Deleted group '$($g.name)'. Its accounts are still there."
}

function Show-MembersDialog($g) {
    # Pick who's in a group: search, a filter, and tick boxes. Nothing changes until Save.
    [xml]$dx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="520" Height="600" MinHeight="400" WindowStartupLocation="CenterOwner"
        Background="{StaticResource Surface}" FontFamily="Segoe UI" FontSize="14">
  <DockPanel Margin="20">
    <StackPanel DockPanel.Dock="Top">
      <TextBlock x:Name="T" Foreground="{StaticResource Ink}" FontSize="18" FontWeight="Bold" Margin="0,0,0,12" TextTrimming="CharacterEllipsis"/>
      <Grid Margin="0,0,0,8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions>
        <TextBox x:Name="Q" Background="{StaticResource Input}" Foreground="{StaticResource Ink}" BorderBrush="{StaticResource Line}" Padding="8,7" CaretBrush="{StaticResource Ink}" AutomationProperties.Name="Search accounts" ToolTip="Search by nickname"/>
        <ComboBox x:Name="F" Grid.Column="1" Margin="8,0,0,0" AutomationProperties.Name="Show"/>
      </Grid>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
        <Button x:Name="All" Content="Tick all shown" Padding="12,6" Margin="0,0,8,0" Background="{StaticResource Raised}" Foreground="{StaticResource Ink}" BorderThickness="0"/>
        <Button x:Name="None" Content="Untick all shown" Padding="12,6" Background="{StaticResource Raised}" Foreground="{StaticResource Ink}" BorderThickness="0"/>
      </StackPanel>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom">
      <TextBlock x:Name="N" Foreground="{StaticResource Muted}" Margin="0,8,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
        <Button x:Name="C" Content="Cancel" Padding="16,8" Margin="0,0,8,0" Background="{StaticResource Raised}" Foreground="{StaticResource Ink}" BorderThickness="0" IsCancel="True"/>
        <Button x:Name="O" Content="Save" Padding="20,8" Background="{StaticResource Accent}" Foreground="{StaticResource Ink}" BorderThickness="0" FontWeight="SemiBold"/>
      </StackPanel>
    </StackPanel>
    <Border Background="{StaticResource Input}" CornerRadius="8" Padding="10">
      <Grid>
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="L"/></ScrollViewer>
        <TextBlock x:Name="E" Text="No accounts match." Foreground="{StaticResource Muted}" Visibility="Collapsed"/>
      </Grid>
    </Border>
  </DockPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    Initialize-BkDialog $dlg; $dlg.Title = "Members of $($g.name)"
    try { $dlg.Resources.MergedDictionaries.Add($win.Resources) } catch {}   # the app's dark check boxes and drop-downs
    $d = @{}; foreach ($n in "T","Q","F","All","None","N","C","O","L","E") { $d[$n] = $dlg.FindName($n) }
    $d.T.Text = "Who's in '$($g.name)'?"
    $picked = New-Object System.Collections.Generic.HashSet[string]
    foreach ($n in @($g.nicks)) { [void]$picked.Add($n.ToLower()) }
    $info = Get-AccInfo
    foreach ($o in @(@("all", "All accounts"), @("main", "Main"), @("alt", "Alts"), @("running", "Open now"), @("offline", "Not open"), @("assigned", "In a group"), @("unassigned", "In no group"))) {
        $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $o[1]; $it.Tag = $o[0]; $d.F.Items.Add($it) | Out-Null
    }
    $d.F.SelectedIndex = 0
    # Handlers run while the dialog is open (inside this function), so they see $d, $picked and $info.
    $count = { $d.N.Text = "$($picked.Count) of $(@($script:State.accounts).Count) accounts picked" }
    $fill = {
        $d.L.Children.Clear()
        $shown = @(Select-Accounts $script:State.accounts $d.Q.Text ("" + $d.F.SelectedItem.Tag) $info)
        foreach ($a in $shown) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.IsChecked = $picked.Contains($a.nick.ToLower()); $cb.Tag = $a.nick.ToLower(); $cb.Margin = New-Object System.Windows.Thickness 0,0,0,8
            $i = $info[$a.nick.ToLower()]
            $sp = New-Object System.Windows.Controls.StackPanel
            $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = $a.nick + $(if ($a.isMain) { "   " + [char]0x2605 + " main" } else { "" }); $t1.Foreground = Brush "Ink"
            $t2 = New-Object System.Windows.Controls.TextBlock; $t2.FontSize = 12; $t2.Foreground = Brush "Muted"
            $t2.Text = $(if ($i.Running) { "open" } else { "not open" }) + "   |   " + $(if (@($i.Groups).Count) { "in: " + (@($i.Groups) -join ", ") } else { "in no group" }) + $(if (-not $i.Ready) { "   |   needs setup" } else { "" })
            $sp.Children.Add($t1) | Out-Null; $sp.Children.Add($t2) | Out-Null
            $cb.Content = $sp
            [System.Windows.Automation.AutomationProperties]::SetName($cb, $a.nick)
            # Checked/Unchecked (not Click): also fires for keyboard, screen readers and "Tick all shown"
            $cb.Add_Checked({ param($s,$e) [void]$picked.Add($s.Tag); & $count })
            $cb.Add_Unchecked({ param($s,$e) [void]$picked.Remove($s.Tag); & $count })
            $d.L.Children.Add($cb) | Out-Null
        }
        $d.E.Visibility = $(if ($shown.Count) { "Collapsed" } else { "Visible" })
        & $count
    }

    $d.Q.Add_TextChanged({ & $fill })
    $d.F.Add_SelectionChanged({ & $fill })
    $d.All.Add_Click({ foreach ($cb in $d.L.Children) { $cb.IsChecked = $true; [void]$picked.Add($cb.Tag) }; & $count })
    $d.None.Add_Click({ foreach ($cb in $d.L.Children) { $cb.IsChecked = $false; [void]$picked.Remove($cb.Tag) }; & $count })
    $script:MembersSaved = $false
    $d.O.Add_Click({ $script:MembersSaved = $true; $dlg.Close() })
    $d.C.Add_Click({ $dlg.Close() })
    $dlg.Add_ContentRendered({ $d.Q.Focus() | Out-Null })
    & $fill
    $dlg.ShowDialog() | Out-Null
    if (-not $script:MembersSaved) { return }
    Set-GroupMembers $script:State $g @($script:State.accounts | Where-Object { $picked.Contains($_.nick.ToLower()) } | ForEach-Object { $_.nick })
    Save-Settings; Render-Groups
    Say "'$($g.name)' now has $(@($g.nicks).Count) account(s)."
}

# Narrow window: the "Open this group" card moves under the members instead of a third column.
function Update-GroupsLayout {
    $narrow = $ui.GroupsGrid.ActualWidth -gt 0 -and $ui.GroupsGrid.ActualWidth -lt 1080
    $ui.GActCol.Width = $(if ($narrow) { New-Object System.Windows.GridLength 0 } else { New-Object System.Windows.GridLength 300 })
    $ui.GActGap.Width = $(if ($narrow) { New-Object System.Windows.GridLength 0 } else { New-Object System.Windows.GridLength 12 })
    [System.Windows.Controls.Grid]::SetColumn($ui.GActCard, $(if ($narrow) { 2 } else { 4 }))
    [System.Windows.Controls.Grid]::SetRow($ui.GActCard, $(if ($narrow) { 1 } else { 0 }))
    $ui.GActCard.Margin = $(if ($narrow) { New-Object System.Windows.Thickness 0,12,0,0 } else { New-Object System.Windows.Thickness 0 })
}

# =========================================================== SCHEDULE TAB ==
# The run itself is Invoke-PlanEvent (top of this file); this part feeds it what the app
# sees, carries out what it returns, saves it, and shows it.
$script:PlanClock = [System.Diagnostics.Stopwatch]::StartNew()   # never jumps, unlike the PC clock
function Get-Mono { $script:PlanClock.Elapsed.TotalSeconds }
$script:Run = ConvertFrom-SavedRun $State.planRun
$script:RunLink = $(if ($State.planRun -and $State.planRun.Link) { "" + $State.planRun.Link } else { "" })
$script:RunSavedAt = 0.0
$PlanStateNames = @{ idle = "NOT STARTED"; launching = "OPENING ACCOUNTS"; running = "RUNNING"; cooldown = "BREAK"; waiting = "WAITING FOR YOU"
                     paused = "PAUSED"; completed = "FINISHED"; stopped = "STOPPED" }

function Test-PlanActive { @("launching", "running", "cooldown", "waiting", "paused") -contains $script:Run.State }
function Get-PlanFacts {
    $members = @($script:Run.Members)
    $busy = $false
    if ($script:QBusy) {
        $q = @($script:Q | ForEach-Object { $_.Acc.nick }) + @($(if ($script:QCur) { $script:QCur.Acc.nick }))
        $busy = [bool]@($q | Where-Object { $members -icontains $_ }).Count
    }
    @{ Open = @($members | Where-Object { Get-WindowOf $_ })
       Failed = @($members | Where-Object { $st = $script:AccStatus[$_.ToLower()]; $st -and @("failed", "limit") -contains $st.State })   # "limit": refused by the client limit
       Busy = $busy }
}
function Save-PlanRun {
    $saved = ConvertTo-SavedRun $script:Run (Get-Mono)
    $saved | Add-Member -NotePropertyName Link -NotePropertyValue $script:RunLink -Force
    $script:State.planRun = $saved
    $script:RunSavedAt = Get-Mono
    Save-Settings
}
function Add-PlanHistory([string]$text) {
    $script:State.planHistory = @(@($script:State.planHistory) + [pscustomobject]@{ at = (Get-Date -Format "yyyy-MM-dd HH:mm"); text = $text } | Select-Object -Last 100)
}

function Open-PlanAccounts($nicks, [bool]$follow) {
    # Opens the schedule's accounts with the link saved when it started. A group with your main:
    # the main goes first and the others join its server (like "Start everything").
    $accs = @($script:State.accounts | Where-Object { @($nicks) -icontains $_.nick })
    if (-not $accs.Count) { return }
    $info = Get-LinkInfo $script:RunLink
    if (@("empty", "bad") -contains $info.Kind) { Say "Schedule: the link it started with isn't valid anymore."; return }
    $main = Get-Main
    $mainUrl = $(if ($main -and $main.profileUrl) { (Get-LinkInfo $main.profileUrl).Url } else { "" })
    $groupHasMain = $main -and @($script:Run.Members) -icontains $main.nick
    $items = @()
    if ($follow -and $mainUrl -and $groupHasMain -and @("game", "private", "share") -contains $info.Kind -and @($accs | Where-Object { Same $_ $main }).Count) {
        $others = @($accs | Where-Object { -not (Same $_ $main) } | ForEach-Object { $_.nick })
        $items += [pscustomobject]@{ Acc = $main; Url = $info.Url; Kind = "main"; Followers = $others }
        foreach ($n in $others) { Set-AccStatus $n "opening" }   # waiting for the main (not a stale "didn't load" from an earlier group)
    } elseif ($follow -and $mainUrl -and $groupHasMain -and (Get-WindowOf $main.nick)) {
        foreach ($a in $accs) { $items += [pscustomobject]@{ Acc = $a; Url = $mainUrl; Kind = "normal" } }
    } else {
        foreach ($a in $accs) { $items += [pscustomobject]@{ Acc = $a; Url = $info.Url; Kind = "normal" } }
    }
    Queue-Items $items
}

function Remove-FromQueue($nicks) {
    # Takes these accounts out of the opening queue. Other accounts keep opening.
    foreach ($it in @($script:Q)) {
        if (@($nicks) -icontains $it.Acc.nick) { $script:Q.Remove($it); Set-AccStatus $it.Acc.nick $null; $script:QTotal-- }
    }
    if (-not ($script:QBusy -and $script:QCur)) { return }
    $f = $script:QCur.PSObject.Properties["Followers"]
    if ($f) { $f.Value = @($f.Value | Where-Object { @($nicks) -inotcontains $_ }) }   # a main's group won't be sent after it
    if (@($nicks) -icontains $script:QCur.Acc.nick -and $script:QPhase -eq "wait") {
        if ($script:QCur.Op) { $script:QCur.Op.Cancelled = $true }   # its tab stays open
        Set-AccStatus $script:QCur.Acc.nick $null
        $script:QTotal--; $script:QPhase = "idle"   # go on with the rest (or finish)
    }
    Render-Accounts
}

function Invoke-Plan([string]$event, [bool]$closeOnStop = $false) {
    $before = "$($script:Run.State)/$($script:Run.Step)"
    $acts = @(Invoke-PlanEvent $script:Run $script:State.plan $script:State.groups $event (Get-Mono) (Get-PlanFacts) $closeOnStop)
    foreach ($x in $acts) {
        switch ($x.Do) {
            "log"   { Add-PlanHistory $x.Text; Say "Schedule: $($x.Text)" }
            "open"  { Open-PlanAccounts $x.Nicks $x.Follow }
            "close" { foreach ($n in $x.Nicks) { $w = Get-WindowOf $n; if ($w) { Close-RobloxWindow $w -NoAsk } } }
            "cancel" { Remove-FromQueue $x.Nicks }
        }
    }
    $after = "$($script:Run.State)/$($script:Run.Step)"
    if ($after -ne $before -and @("completed", "stopped") -contains $script:Run.State -and $script:State.webhookOnDone) {
        Send-Webhook "BloxKit schedule: $($script:Run.Reason)" | Out-Null
    }
    if ($after -ne $before -or $acts.Count) { Save-PlanRun; Render-ScheduleTab }
    elseif ((Test-PlanActive) -and (Get-Mono) - $script:RunSavedAt -ge 30) { Save-PlanRun }   # keep the time saved in case the app closes
}


function Update-ScheduleLive {
    # The parts that change every second (time, progress, buttons).
    $r = $script:Run; $p = $script:State.plan
    $v = Get-PlanView $r $p $script:State.groups (Get-Mono)
    $ui.SStateText.Text = $PlanStateNames[$r.State] + $(if ($r.Cycle -gt 1) { "  (round $($r.Cycle))" } else { "" })
    $ui.SGroupText.Text = $(if ($r.GroupName) { $r.GroupName } else { "No group running" })
    switch ($v.PhaseState) {
        "running"   { $ui.STimeText.Text = (Format-Clock $v.RemainingSec) + " left"; $ui.SProgress.Value = $(if ($v.LengthSec) { $v.ElapsedSec / $v.LengthSec } else { 0 }) }
        "cooldown"  { $ui.STimeText.Text = "Break: " + (Format-Clock $v.RemainingSec); $ui.SProgress.Value = $(if ($v.LengthSec) { $v.ElapsedSec / $v.LengthSec } else { 0 }) }
        "launching" { $ui.STimeText.Text = "Opening..."; $ui.SProgress.Value = 0 }
        "waiting"   { $ui.STimeText.Text = "Done. Click 'Next group'"; $ui.SProgress.Value = 1 }
        default     { $ui.STimeText.Text = $(if ($r.State -eq "completed") { "All done" } elseif ($r.State -eq "stopped") { "Stopped" } else { "--:--" }); $ui.SProgress.Value = 0 }
    }
    $ui.SNextText.Text = $(if ($v.NextName -and (Test-PlanActive)) { "Next: $($v.NextName)" } else { "" }) +
                         $(if ($v.TotalSec -ge 60) { $(if ($v.NextName -and (Test-PlanActive)) { "   " + [char]0x00B7 + "   " } else { "" }) + "Run time so far: " + (Format-Dur $v.TotalSec) } else { "" })
    $ui.SReasonText.Text = $(if (@("stopped", "completed") -contains $r.State -and $r.Reason) { $r.Reason } else { "" })
    $ui.SStartBtn.IsEnabled = Test-PlanCan $r "start"
    $ui.SStartBtn.Content = $(if ($r.State -eq "idle") { "Start" } else { "Start again" })
    $canPause = Test-PlanCan $r "pause" $p; $canResume = Test-PlanCan $r "resume" $p
    $ui.SPauseBtn.Content = $(if ($canResume) { "Resume" } else { "Pause" })
    $ui.SPauseBtn.IsEnabled = $canPause -or $canResume
    $ui.SPauseBtn.ToolTip = $(if ($r.State -eq "launching") { "You can pause once the group's accounts are open." } elseif ($canResume) { "Go on. Accounts that aren't open are opened again." } else { "Stop the timer for now." })
    $ui.SNextBtn.IsEnabled = Test-PlanCan $r "next" $p
    $ui.SNextBtn.ToolTip = $(if ($r.State -eq "running") { "End this group now and go on to the next one." } else { "Go on to the next group." })
    $ui.SStopBtn.IsEnabled = Test-PlanCan $r "stop"
    foreach ($b in $ui.SPauseBtn, $ui.SNextBtn, $ui.SStopBtn, $ui.SStartBtn) { [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true) }
    if ($r.State -eq "launching" -or $r.State -eq "running") {
        $open = @((Get-PlanFacts).Open)
        $ui.SMembersText.Text = "Open: $($open.Count) of $(@($r.Members).Count)" + $(if (@($r.Skipped).Count) { "   " + [char]0x00B7 + "   given up on: " + (@($r.Skipped) -join ", ") } else { "" })
    } else { $ui.SMembersText.Text = "" }
}

function Render-ScheduleTab {
    $p = $script:State.plan
    $active = Test-PlanActive
    $ui.TabSchedule.Header = $(if ($active) { "Schedule (" + $PlanStateNames[$script:Run.State].ToLower() + ")" } else { "Schedule" })
    # ---- steps ----
    $ui.SStepList.Children.Clear()
    $steps = @($p.steps)
    $ui.SStepEmpty.Visibility = $(if ($steps.Count) { "Collapsed" } else { "Visible" })
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $st = $steps[$i]
        $g = Get-GroupById $script:State.groups $st.groupId
        $now = $active -and $script:Run.Step -eq $i
        $row = New-Object System.Windows.Controls.Border
        $row.Background = Brush $(if ($now) { "AccentSoft" } else { "SurfaceAlt" }); $row.CornerRadius = New-Object System.Windows.CornerRadius 8
        $row.Padding = New-Object System.Windows.Thickness 10,6,6,6; $row.Margin = New-Object System.Windows.Thickness 0,0,0,6
        $dock = New-Object System.Windows.Controls.DockPanel
        $btns = New-Object System.Windows.Controls.StackPanel; $btns.Orientation = "Horizontal"
        [System.Windows.Controls.DockPanel]::SetDock($btns, "Right")
        foreach ($b in @(@([string][char]0x25B2, "up", "Move up"), @([string][char]0x25BC, "down", "Move down"), @([string][char]0x2715, "del", "Remove from the schedule"))) {
            $bt = New-Object System.Windows.Controls.Button
            $bt.Style = $BtnStyle; $bt.Content = $b[0]; $bt.ToolTip = $b[2]; $bt.Padding = New-Object System.Windows.Thickness 8,4,8,4
            $bt.Margin = New-Object System.Windows.Thickness 4,0,0,0; $bt.Tag = @{ I = $i; Act = $b[1] }; $bt.IsEnabled = -not $active
            [System.Windows.Automation.AutomationProperties]::SetName($bt, "$($b[2]) step $($i + 1)")
            $bt.Add_Click({ param($s,$e)
                $list = [System.Collections.ArrayList]@($script:State.plan.steps); $k = $s.Tag.I
                switch ($s.Tag.Act) {
                    "up"   { if ($k -gt 0) { $t = $list[$k - 1]; $list[$k - 1] = $list[$k]; $list[$k] = $t } }
                    "down" { if ($k -lt $list.Count - 1) { $t = $list[$k + 1]; $list[$k + 1] = $list[$k]; $list[$k] = $t } }
                    "del"  { $list.RemoveAt($k) }
                }
                $script:State.plan.steps = @($list); Save-Settings; Render-ScheduleTab })
            $btns.Children.Add($bt) | Out-Null
        }
        $mins = New-Object System.Windows.Controls.TextBox
        $mins.Text = "" + $st.minutes; $mins.Width = 56; $mins.Padding = New-Object System.Windows.Thickness 6,4,6,4; $mins.IsEnabled = -not $active
        $mins.Tag = $st; $mins.ToolTip = "Minutes (1 to 1440)"
        [System.Windows.Automation.AutomationProperties]::SetName($mins, "Minutes for step $($i + 1)")
        $mins.Add_LostFocus({ param($s,$e)
            $m = 0
            if ([int]::TryParse($s.Text.Trim(), [ref]$m) -and $m -ge 1 -and $m -le 1440) { if ($s.Tag.minutes -ne $m) { $s.Tag.minutes = $m; Save-Settings } }
            else { Say "Type the minutes as a number from 1 to 1440." }
            $s.Text = "" + $s.Tag.minutes })
        $mt = New-Object System.Windows.Controls.TextBlock; $mt.Text = " min"; $mt.Foreground = Brush "Muted"; $mt.VerticalAlignment = "Center"
        $mp = New-Object System.Windows.Controls.StackPanel; $mp.Orientation = "Horizontal"; $mp.Margin = New-Object System.Windows.Thickness 8,0,0,0
        $mp.Children.Add($mins) | Out-Null; $mp.Children.Add($mt) | Out-Null
        [System.Windows.Controls.DockPanel]::SetDock($mp, "Right")
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.VerticalAlignment = "Center"; $nm.TextTrimming = "CharacterEllipsis"
        $nm.Text = "$($i + 1).  " + $(if ($g) { "$($g.name)  ($(@($g.nicks).Count))" } else { "(deleted group)" })
        $nm.Foreground = Brush $(if ($g) { "Ink" } else { "DangerInk" }); $nm.FontWeight = $(if ($now) { "SemiBold" } else { "Normal" })
        foreach ($c in $btns, $mp, $nm) { $dock.Children.Add($c) | Out-Null }
        $row.Child = $dock
        $ui.SStepList.Children.Add($row) | Out-Null
    }
    $ui.SAddGroup.Items.Clear()
    foreach ($g in @($script:State.groups)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = "$($g.name)  ($(@($g.nicks).Count))"; $it.Tag = $g.id
        $ui.SAddGroup.Items.Add($it) | Out-Null
    }
    if ($ui.SAddGroup.Items.Count) { $ui.SAddGroup.SelectedIndex = 0 }
    $ui.SAddGroup.IsEnabled = -not $active -and $ui.SAddGroup.Items.Count -gt 0
    $ui.SAddBtn.IsEnabled = $ui.SAddGroup.IsEnabled
    $ui.SEditHint.Text = $(if ($active) { "Stop the schedule to change it." } elseif (-not $ui.SAddGroup.Items.Count) { "Make a group on the Groups tab first." } else { "" })
    # ---- history ----
    $h = @($script:State.planHistory | Select-Object -Last 30)
    [array]::Reverse($h)
    $ui.SHistory.Text = $(if ($h.Count) { ($h | ForEach-Object { "$($_.at.Substring([Math]::Max(0, $_.at.Length - 5)))   $($_.text)" }) -join "`n" } else { "Nothing yet." })
    Update-ScheduleLive
}

function Start-Plan {
    $v = Test-Plan $script:State.plan $script:State (Get-AccInfo) (Get-LinkInfo $ui.LinkBox.Text).Kind
    if ($v.Errors.Count) {
        [BkBox]::Show("The schedule can't start yet:`n`n- " + ($v.Errors -join "`n- "), "Schedule", "OK", "Information") | Out-Null
        return
    }
    if ($v.Warnings.Count) {
        $r = [BkBox]::Show("Start anyway?`n`n- " + ($v.Warnings -join "`n- "), "Schedule", "YesNo", "Question")
        if ($r -ne "Yes") { return }
    }
    if (-not (Check-MultiWindow)) { return }
    $script:RunLink = $ui.LinkBox.Text.Trim()
    $script:State.lastLink = $ui.LinkBox.Text; Save-Settings
    Add-PlanHistory "Schedule started with: $((Get-LinkInfo $script:RunLink).Label)"
    Invoke-Plan "start"
}

# Narrow window: options go under the run card.
function Update-ScheduleLayout {
    $narrow = $ui.SchedGrid.ActualWidth -gt 0 -and $ui.SchedGrid.ActualWidth -lt 1120
    $ui.SOptCol.Width = $(if ($narrow) { New-Object System.Windows.GridLength 0 } else { New-Object System.Windows.GridLength 320 })
    $ui.SOptGap.Width = $(if ($narrow) { New-Object System.Windows.GridLength 0 } else { New-Object System.Windows.GridLength 12 })
    [System.Windows.Controls.Grid]::SetColumn($ui.SOptCard, $(if ($narrow) { 2 } else { 4 }))
    [System.Windows.Controls.Grid]::SetRow($ui.SOptCard, $(if ($narrow) { 1 } else { 0 }))
    $ui.SOptCard.Margin = $(if ($narrow) { New-Object System.Windows.Thickness 0,12,0,0 } else { New-Object System.Windows.Thickness 0 })
    # Under the run card it gets a part of the height and scrolls, so the timer stays visible.
    $ui.SOptCard.MaxHeight = $(if ($narrow) { [Math]::Max([double]180, $ui.SchedGrid.ActualHeight * 0.42) } else { [double]::PositiveInfinity })
}

# ============================================================ PERFORMANCE ==
# Live numbers (every 5 s, ~10 ms each), tips, presets, and Roblox's own graphics settings.
# Tests can point RML_ROBLOX_DIR at a copy; in test mode (-NoRoblox) the real file is never written.
$RobloxDataDir = $(if ($env:RML_ROBLOX_DIR) { $env:RML_ROBLOX_DIR } else { Join-Path $env:LOCALAPPDATA "Roblox" })
$script:CanWriteRoblox = (-not $NoRoblox) -or [bool]$env:RML_ROBLOX_DIR
$script:LoadPrev = $null; $script:LoadComps = @(); $script:LoadByPid = @{}; $script:GpuAdapters = $null
$PerfPresets = [ordered]@{
    low      = @{ Name = "Low resource"; Settle = 12; Eco = $true; Small = $true;  Quality = 1; Fps = 30
                  Hint = "Alts small and in efficiency mode, 12 s between launches, Roblox quality 1 at 30 FPS. Best for many clients." }
    balanced = @{ Name = "Balanced"; Settle = 8; Eco = $true; Small = $false; Quality = 4; Fps = 60
                  Hint = "Alts in efficiency mode at normal size, 8 s between launches, Roblox quality 4 at 60 FPS." }
}
function Get-RobloxSettingsFile { Get-ChildItem $RobloxDataDir -Filter "GlobalBasicSettings_*.xml" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
function Get-RobloxRunningCount { $(if ($env:RML_ROBLOX_DIR) { 0 } else { Get-RobloxCount }) }   # a test copy isn't used by any Roblox
function Get-CurrentRobloxGraphics {
    $f = Get-RobloxSettingsFile
    if (-not $f) { return @{ Quality = $null; FpsCap = $null } }
    try { return Read-RobloxGraphics ([IO.File]::ReadAllText($f.FullName)) } catch { return @{ Quality = $null; FpsCap = $null } }
}
function Format-RobloxGraphics($g) {
    "quality " + $(if ($null -eq $g.Quality) { "unknown" } elseif ($g.Quality -eq 0) { "Automatic" } else { "$($g.Quality) of 10" }) +
    ", frame rate cap " + $(if ($null -eq $g.FpsCap) { "unknown" } elseif ($g.FpsCap -le 0) { "Roblox default" } else { "$($g.FpsCap) FPS" })
}

function Save-RobloxGraphicsChoice {
    $q = [int]$ui.RbxQualityBox.SelectedItem.Tag; $fps = [int]$ui.RbxFpsBox.SelectedItem.Tag
    if (-not $script:CanWriteRoblox) { Say "(test mode) Roblox's settings file isn't changed."; return }
    if (-not (Confirm-RobloxClosed "save these")) { Update-PerfUi; return }
    $r = Write-RobloxGraphics $q $fps
    if ($r.Ok) {
        Say "Saved to Roblox: $(Format-RobloxGraphics (Get-CurrentRobloxGraphics)). Open a client and check Esc > Settings shows it."
        Show-MascotMoment "Success" "Roblox's graphics are saved."
    } else { Say $r.Msg }
    Update-PerfUi
}
function Confirm-RobloxClosed([string]$what) {
    # Roblox's settings can only change while no Roblox runs: every client writes its own copy
    # when it closes. Offers to close all of it, background leftovers included. $true = all closed.
    $n = Get-RobloxRunningCount
    if ($n -eq 0) { return $true }
    $r = [BkBox]::Show("Roblox is running ($n program(s), counting background ones). Every client writes its own copy of these settings when it closes, so it all has to close first.`n`nClose all Roblox now and $what?", "Roblox graphics", "YesNo", "Question")
    if ($r -ne "Yes") { return $false }
    foreach ($w in $script:Wins) { [void]$script:ExpectedClose.Add($w.Handle.ToInt64()) }   # no "kicked" alerts for these
    Get-Process -Name "RobloxPlayerBeta" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 40 -and (Get-RobloxRunningCount) -gt 0; $i++) { Start-Sleep -Milliseconds 250 }
    if ((Get-RobloxRunningCount) -gt 0) { Say "Some Roblox didn't close. End RobloxPlayerBeta.exe in Task Manager, then try again."; return $false }
    return $true
}
function Write-RobloxGraphics([int]$q, [int]$fps) {
    # Writes quality and frame rate into Roblox's settings file (only while no Roblox runs).
    # The old file is kept for Undo; only the last 5 copies are kept.
    $f = Get-RobloxSettingsFile
    if (-not $f) { return @{ Ok = $false; Msg = "Couldn't find Roblox's settings file in $RobloxDataDir. Open Roblox once, then try again." } }
    $new = Set-RobloxGraphics ([IO.File]::ReadAllText($f.FullName)) $q $fps
    if (-not $new) { return @{ Ok = $false; Msg = "Roblox's settings file doesn't have the graphics settings this app knows. Nothing was changed." } }
    $keep = Join-Path $AppDir ("roblox-settings-before-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "__" + $f.Name)   # remembers which file it came from
    try {
        Copy-Item -LiteralPath $f.FullName $keep -ErrorAction Stop
        $tmp = "$($f.FullName).rml-tmp"
        [IO.File]::WriteAllText($tmp, $new, (New-Object Text.UTF8Encoding $false))
        [IO.File]::Replace($tmp, $f.FullName, [NullString]::Value)   # $null would arrive as "" (an invalid path)
        Get-ChildItem $AppDir -Filter "roblox-settings-before-*.xml" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
        return @{ Ok = $true; Msg = "" }
    } catch {
        Remove-Item -LiteralPath "$($f.FullName).rml-tmp" -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Msg = "Couldn't change Roblox's settings: $($_.Exception.Message)" }
    }
}
$script:RbxSyncOff = $false
function Sync-RobloxGraphics {
    # "Keep Roblox on these settings": while no Roblox is running, BloxKit puts the picked quality
    # and frame rate into Roblox's file itself (every client reads it when it starts), so nobody
    # has to close everything and click Save to Roblox. Changes made in a game are put back.
    if ($script:RbxSyncOff -or -not $script:State.rbxAuto -or -not $script:CanWriteRoblox) { return }
    $q = [int]$script:State.rbxQuality; $fps = [int]$script:State.rbxFps
    if ($q -lt 1 -or $fps -eq 0) { return }                     # nothing picked
    if ((Get-RobloxRunningCount) -gt 0) { return }               # a running client would overwrite it
    $g = Get-CurrentRobloxGraphics
    if ($null -eq $g.Quality) { return }                         # Roblox hasn't made its file yet (never opened)
    if ($g.Quality -eq $q -and (Get-FpsChoice $g.FpsCap) -eq (Get-FpsChoice $fps)) { return }
    $r = Write-RobloxGraphics $q $fps
    $now = Get-CurrentRobloxGraphics
    if (-not $r.Ok -or $now.Quality -ne $q) { $script:RbxSyncOff = $true; if ($r.Msg) { Say $r.Msg }; return }   # don't keep trying this session
    Say "Roblox is set to $(Format-RobloxGraphics $now) (Settings > Performance), ready for the next client."
    Update-PerfUi
}
function Undo-RobloxGraphics {
    if (-not $script:CanWriteRoblox) { Say "(test mode) Roblox's settings file isn't changed."; return }
    $b = Get-ChildItem $AppDir -Filter "roblox-settings-before-*.xml" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $b) { Say "Nothing to undo: Roblox's settings weren't changed by this app."; return }
    if (-not (Confirm-RobloxClosed "put the old settings back")) { Update-PerfUi; return }
    # Back into the same file it was copied from (its name is in the backup's name).
    $target = $(if ($b.Name -match '__(GlobalBasicSettings_\d+\.xml)$') { Join-Path $RobloxDataDir $Matches[1] } else { $x = Get-RobloxSettingsFile; if ($x) { $x.FullName } else { "" } })
    if (-not $target) { Say "Couldn't find Roblox's settings file."; return }
    try {
        Copy-Item -LiteralPath $b.FullName $target -Force -ErrorAction Stop
        Remove-Item -LiteralPath $b.FullName -ErrorAction SilentlyContinue   # so the next Undo goes one step further back
        Say "Put back Roblox's settings from $($b.LastWriteTime.ToString('g')): $(Format-RobloxGraphics (Get-CurrentRobloxGraphics))."
        $g = Get-CurrentRobloxGraphics
        if ($g.Quality -ge 1) { Show-GraphicsPicks $g.Quality (Get-FpsChoice $g.FpsCap); Save-Settings }   # the picks follow what was put back
    } catch { Say "Couldn't put back Roblox's settings: $($_.Exception.Message)" }
    Update-PerfUi
}

function Get-FpsChoice($fps) { $(if (@(30, 60, 144, 240) -contains $fps) { [int]$fps } else { -1 }) }   # the frame rate box's choices; anything else shows as Roblox's default
function Get-GraphicsPicks {
    # The quality and frame rate picked in Settings > Performance (saved with the app's
    # settings), or Roblox's own until something is picked.
    if ($script:State.rbxQuality -ge 1 -and $script:State.rbxFps -ne 0) { return @{ Quality = $script:State.rbxQuality; FpsCap = $script:State.rbxFps } }
    return Get-CurrentRobloxGraphics
}
function Show-GraphicsPicks([int]$quality, [int]$fps) {
    # Puts picks in the two boxes and the settings (the caller saves).
    $script:FillingPerf = $true
    Select-ComboTag $ui.RbxQualityBox $quality; Select-ComboTag $ui.RbxFpsBox $fps
    $script:FillingPerf = $false
    $script:State.rbxQuality = $quality; $script:State.rbxFps = $fps
}
function Save-GraphicsPicks {
    if ($script:FillingPerf -or -not $ui.RbxQualityBox.SelectedItem -or -not $ui.RbxFpsBox.SelectedItem) { return }
    $script:State.rbxQuality = [int]$ui.RbxQualityBox.SelectedItem.Tag; $script:State.rbxFps = [int]$ui.RbxFpsBox.SelectedItem.Tag
    Save-Settings; Update-PerfUi
}

function Get-PerfPresetMatch {
    $g = Get-GraphicsPicks
    foreach ($k in $PerfPresets.Keys) {
        $p = $PerfPresets[$k]
        if ($script:State.launchSettle -eq $p.Settle -and $script:State.ecoAlts -eq $p.Eco -and $script:State.lowPower -eq $p.Small -and
            ($null -eq $g.Quality -or ($g.Quality -eq $p.Quality -and $g.FpsCap -eq $p.Fps))) { return $k }
    }
    return "custom"
}
function Select-ComboTag($box, $value) { foreach ($it in $box.Items) { if ("" + $it.Tag -eq "" + $value) { $box.SelectedItem = $it; return } } }
function Update-PerfUi {
    $g = Get-CurrentRobloxGraphics
    $running = Get-RobloxRunningCount
    $pick = Get-GraphicsPicks
    $differs = $null -ne $g.Quality -and ($g.Quality -ne $pick.Quality -or (Get-FpsChoice $g.FpsCap) -ne (Get-FpsChoice $pick.FpsCap))
    $ui.RbxNowText.Text = $(if ($null -eq $g.Quality) { "Roblox hasn't made its settings file yet: open Roblox once, then BloxKit can set it." } else { "Roblox now: " + (Format-RobloxGraphics $g) + "." }) +
        $(if (-not $script:CanWriteRoblox) { "  (test mode: not changed)" } elseif ($running) { "  Roblox is running ($running), so it can't change now." } else { "" }) +
        $(if (-not $differs) { "" } elseif ($script:State.rbxAuto) { "  Your picks go in by themselves once no Roblox is running, or click Save to Roblox." } else { "  Your picks above aren't in Roblox yet: click Save to Roblox." })
    # Always clickable: with Roblox running it offers to close it first (leftover background ones too).
    $ui.RbxApplyBtn.IsEnabled = $script:CanWriteRoblox
    $ui.RbxUndoBtn.IsEnabled = $script:CanWriteRoblox
    foreach ($b in $ui.RbxApplyBtn, $ui.RbxUndoBtn) { [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true) }
    $ui.RbxApplyBtn.ToolTip = $(if ($running) { "Asks to close all Roblox first ($running running), then saves." } else { "Write these two settings into Roblox's settings file." })
    $script:FillingPerf = $true
    $m = Get-PerfPresetMatch
    Select-ComboTag $ui.PerfPresetBox $m
    $ui.PerfPresetHint.Text = $(if ($m -eq "custom") { "Your own mix. Pick a preset to set everything at once." } else { $PerfPresets[$m].Hint })
    $script:FillingPerf = $false
}
function Set-PerfPreset([string]$key) {
    $p = $PerfPresets[$key]; if (-not $p) { return }
    $script:State.launchSettle = $p.Settle; Select-ComboTag $ui.SettleBox $p.Settle
    $script:State.ecoAlts = $p.Eco; $ui.EcoBox.IsChecked = $p.Eco; foreach ($w in $script:Wins) { $w.EcoFailed = $false }
    $script:State.lowPower = $p.Small; $ui.LowPowerBox.IsChecked = $p.Small
    Show-GraphicsPicks $p.Quality $p.Fps
    Save-Settings
    if (-not $NoRoblox) { Apply-Efficiency; Apply-LowPower }
    $g = Get-CurrentRobloxGraphics
    if ($g.Quality -eq $p.Quality -and $g.FpsCap -eq $p.Fps) { Say "$($p.Name) is on." }
    elseif ($script:State.rbxAuto) { Say "$($p.Name) is on. Roblox gets quality $($p.Quality) at $($p.Fps) FPS by itself once no Roblox is running (or click Save to Roblox)."; Sync-RobloxGraphics }
    else { Say "$($p.Name) is on for the app. Click 'Save to Roblox' for quality $($p.Quality) at $($p.Fps) FPS." }
    Update-PerfUi
}

function Get-StateFacts {
    @{ MultiWindowOff = (-not $NoRoblox) -and $script:Locks.Count -eq 0; RobloxRunning = $(if ($NoRoblox) { 0 } else { Get-RobloxCount })
       NeedSignIn = @($script:State.accounts | Where-Object { $_.needsLogin } | ForEach-Object { $_.nick })
       SetupIssue = @($script:State.accounts | Where-Object { -not $_.needsLogin -and @(Get-SetupIssues $_).Count } | ForEach-Object { $_.nick })
       LimitBlocked = @($script:State.accounts | Where-Object { $st = $script:AccStatus[$_.nick.ToLower()]; $st -and $st.State -eq "limit" } | ForEach-Object { $_.nick })
       MaxClients = $script:State.maxClients
       SharedProfile = @(@($script:State.accounts | Where-Object { $_.profileDir } | Group-Object { $_.profileDir.ToLower() } | Where-Object { $_.Count -gt 1 }) | ForEach-Object { (@($_.Group | ForEach-Object { $_.nick }) -join " and ") + " ($($_.Group[0].profileDir))" }) }
}
function Start-LoadWarmUp {
    # Windows' GPU counters can take ~5 s to answer the first time, and compiling the C# helpers
    # about a second. Do both on a background thread when the app starts, so the window never
    # freezes: the compiled types and the warmed-up counters are shared by the whole process.
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($gpuSrc, $sysSrc)
        try { if (-not ("RbxSys" -as [type])) { Add-Type -TypeDefinition $sysSrc } } catch {}
        try { if (-not ("RbxGpu" -as [type])) { Add-Type -TypeDefinition $gpuSrc } } catch {}
        try { [void](New-Object System.Diagnostics.PerformanceCounterCategory "GPU Engine").ReadCategory() } catch {}
        try { [void](New-Object System.Diagnostics.PerformanceCounterCategory "Memory").ReadCategory() } catch {}
    }).AddArgument($RbxGpuSource).AddArgument($RbxSysSource)
    return @{ Ps = $ps; Handle = $ps.BeginInvoke() }
}
$script:LoadWarm = $null

function Update-LoadMonitor {
    # One reading every 5 s; numbers are averaged over the last 30 s.
    if (-not $script:LoadWarm) { $script:LoadWarm = Start-LoadWarmUp }
    if (-not $script:LoadWarm.Handle.IsCompleted) { $ui.PerfNowText.Text = "Measuring... (getting Windows' counters ready)"; return }
    if (-not $script:GpuAdapters) { $script:GpuAdapters = Get-GpuAdapters }
    $now = Get-LoadReading $PID
    if ($script:LoadPrev) {
        $c = Compare-LoadReadings $script:LoadPrev $now
        $script:LoadComps = @(@($script:LoadComps) + $c | Select-Object -Last 6)
        $script:LoadByPid = @{}; foreach ($x in $c.Clients) { $script:LoadByPid[$x.Pid] = $x }
    }
    $script:LoadPrev = $now
    Render-LoadMonitor
}
function Render-LoadMonitor {
    $tips = @(Get-StateFindings (Get-StateFacts))
    if (@($script:LoadComps).Count) {
        $onBattery = $false
        try { $onBattery = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq "Offline" } catch {}
        $s = ConvertTo-LoadFacts $script:LoadComps $script:GpuAdapters (Get-CurrentRobloxGraphics) $onBattery
        $f = $s.Facts; $last = $script:LoadComps[-1]
        $gpuText = $(if ($f.Adapters) { ($f.Adapters | Where-Object { $_.BusyPct -ge 1 -or $_.RobloxCount } | ForEach-Object { "{0} {1:N0}%" -f ($_.Name -replace '^(NVIDIA GeForce|AMD Radeon|Intel\(R\)) ', ''), $_.BusyPct }) -join ", " } else { "not available" })
        $ui.PerfNowText.Text = ("Roblox clients: {0}`nProcessor: {1}`nFree memory: {2}`nGraphics: {3}`nThis app: {4}" -f @($last.Clients).Count,
            $(if ($null -ne $f.CpuTotalPct) { "{0:N0}% busy" -f $f.CpuTotalPct } else { "not available" }),
            $(if ($null -ne $last.RamFreeGB) { "{0:N1} of {1:N0} GB" -f $last.RamFreeGB, $last.RamTotalGB } else { "not available" }),
            $gpuText,
            $(if ($null -ne $f.ManagerCpuPct) { "{0:N1}% of the processor" -f $f.ManagerCpuPct } else { "-" }))
        $tips = @($tips) + @(Get-LoadFindings $f)
        $rank = @{ high = 0; medium = 1; info = 2 }
        $tips = @($tips | Sort-Object { $rank[$_.Severity] })
    }
    $ui.TipsList.Children.Clear()
    foreach ($t in @($tips | Select-Object -First 4)) {
        $box = New-Object System.Windows.Controls.Border
        $box.Background = Brush $(switch ($t.Severity) { "high" { "DangerBg" } "medium" { "WarningBg" } default { "SurfaceAlt" } })
        $box.CornerRadius = New-Object System.Windows.CornerRadius 8; $box.Padding = New-Object System.Windows.Thickness 10,8,10,8; $box.Margin = New-Object System.Windows.Thickness 0,6,0,0
        $sp = New-Object System.Windows.Controls.StackPanel
        $h = New-Object System.Windows.Controls.TextBlock; $h.Text = $t.Title; $h.FontWeight = "SemiBold"; $h.TextWrapping = "Wrap"
        $h.Foreground = Brush $(switch ($t.Severity) { "high" { "DangerSoftInk" } "medium" { "WarningInk" } default { "InkSoft" } })
        $b1 = New-Object System.Windows.Controls.TextBlock; $b1.Text = $t.Seen; $b1.FontSize = 12; $b1.Foreground = Brush "Muted"; $b1.TextWrapping = "Wrap"
        $b2 = New-Object System.Windows.Controls.TextBlock; $b2.Text = $t.Fix; $b2.FontSize = 12; $b2.Foreground = Brush "Ink"; $b2.TextWrapping = "Wrap"; $b2.Margin = New-Object System.Windows.Thickness 0,3,0,0
        $box.ToolTip = $t.Why
        foreach ($c in $h, $b1, $b2) { $sp.Children.Add($c) | Out-Null }
        $nav = $(if ($t.Nav) { $t.Nav } elseif ($t.Title -match "graphics quality|frame rate|maxed out") { "settings" } else { "" })
        if ($nav) {
            $go = New-Object System.Windows.Controls.Button
            $go.Style = $BtnStyle; $go.Content = $(if ($nav -eq "accounts") { "Go to Accounts" } else { "Go to Settings" })
            $go.HorizontalAlignment = "Left"; $go.Padding = New-Object System.Windows.Thickness 10,4,10,4; $go.Margin = New-Object System.Windows.Thickness 0,6,0,0
            $go.Tag = $nav
            $go.Add_Click({ param($s,$e) $ui.Tabs.SelectedItem = $(if ($s.Tag -eq "accounts") { $ui.TabAccounts } else { $ui.TabSettings }) })
            $sp.Children.Add($go) | Out-Null
        }
        $box.Child = $sp
        $ui.TipsList.Children.Add($box) | Out-Null
    }
}

# ============================================================ LAUNCH QUEUE ==
# Opens accounts ONE AT A TIME. For each: open Chrome -> wait for a new Roblox
# window -> name that window after the account -> wait a few more seconds -> next.
$script:Q = New-Object System.Collections.ArrayList
$script:QBusy = $false
$script:QPhase = "idle"
$script:QCur = $null
$script:Ops = New-Object System.Collections.ArrayList   # recent launches (last 30 min), to match new windows to them
$script:QStart = [DateTime]::Now
$script:QUntil = [DateTime]::Now
$script:QTotal = 0
$script:QDone = 0
$script:QLoaded = 0
$script:QFailed = New-Object System.Collections.ArrayList

function Set-AccStatus([string]$nick, [string]$state) {
    if ($state) { $script:AccStatus[$nick.ToLower()] = @{ State = $state; Time = (Get-Date -Format "HH:mm") } }
    else { $script:AccStatus.Remove($nick.ToLower()) }
}

function Get-LinkUrlOrWarn {
    $info = Get-LinkInfo $ui.LinkBox.Text
    if ($info.Kind -eq "empty") { Say "Paste a link first (or click 'Use my main's server')."; $ui.LinkBox.Focus() | Out-Null; return $null }
    if ($info.Kind -eq "bad") { Say "Fix the link first."; return $null }
    return $info.Url
}

function Check-MultiWindow {
    if ($script:Locks.Count -gt 0) { return $true }
    $r = [BkBox]::Show("Multi-window is OFF, so only one Roblox window will stay open.`n`nOpen anyway?", "Heads up", "YesNo", "Warning")
    return ($r -eq "Yes")
}

# items: objects with Acc, Url, Kind ("normal" | "main")
function Queue-Items($items) {
    # Never open the same account twice (double clicks, a retry while it's still opening).
    $busyNicks = @($script:Q | ForEach-Object { $_.Acc.nick })
    if ($script:QBusy -and $script:QCur -and $script:QPhase -eq "wait") { $busyNicks += $script:QCur.Acc.nick }
    $skipped = @()
    $items = @(foreach ($it in @($items)) {
        if (($busyNicks -contains $it.Acc.nick) -or (Get-WindowOf $it.Acc.nick)) { $skipped += $it.Acc.nick } else { $busyNicks += $it.Acc.nick; $it }
    })
    if ($skipped.Count) { Say ("Already opening or open: " + ($skipped -join ", ") + ".") }
    $items = @(Limit-Launches $items)
    if ($items.Count -eq 0) { return }
    foreach ($it in $items) { $script:Q.Add($it) | Out-Null; Set-AccStatus $it.Acc.nick "opening" }
    if (-not $script:QBusy) {
        Sync-RobloxGraphics   # the picked graphics, if no Roblox is running yet
        $script:QBusy = $true; $script:QTotal = 0; $script:QDone = 0; $script:QLoaded = 0; $script:QFailed.Clear()
        $script:QPhase = "idle"
        $ui.RetryBtn.Visibility = "Collapsed"
        $QueueTimer.Start()
    }
    $script:QTotal += $items.Count
    $ui.ProgressCard.Visibility = "Visible"
    Render-Accounts; Update-Progress "Starting..."
    Step-Queue
}

function Limit-Launches($items) {
    # Settings > Performance "Most Roblox windows at once": items over the limit aren't opened.
    $items = @($items)
    $queued = $script:Q.Count + $(if ($script:QBusy -and $script:QCur -and $script:QPhase -eq "wait") { 1 } else { 0 })
    $n = Get-LaunchAllowance $script:Wins.Count $queued $items.Count $script:State.maxClients
    if ($n -ge $items.Count) { return $items }
    foreach ($it in $items[$n..($items.Count - 1)]) { Set-AccStatus $it.Acc.nick "limit" }
    Say ("Not opened: " + (($items[$n..($items.Count - 1)] | ForEach-Object { $_.Acc.nick }) -join ", ") + ". The limit is $($script:State.maxClients) Roblox windows at once (Settings > Performance).")
    Render-Accounts
    if ($n -eq 0) { return @() }
    return $items[0..($n - 1)]
}

function Open-Accounts($accs) {
    $accs = @($accs)
    if ($accs.Count -eq 0) { Say "Those accounts are already open (check the Live screens tab)."; return }
    $url = Get-LinkUrlOrWarn
    if (-not $url) { return }
    if (-not (Check-MultiWindow)) { return }
    $script:State.lastLink = $ui.LinkBox.Text; Save-Settings
    if ($script:State.spread -gt 0 -and (Get-LinkInfo $ui.LinkBox.Text).Kind -eq "game") { Start-Spread $accs $url; return }
    $items = @(); foreach ($a in @($accs)) { $items += [pscustomobject]@{ Acc = $a; Url = $url; Kind = "normal" } }
    Queue-Items $items
}

# ----- spreading accounts over servers -----
$script:Planned = @{}     # nick (lower case) -> the server id its last launch aimed for
$script:SpreadJob = $null
$SpreadTimer = New-Object System.Windows.Threading.DispatcherTimer
$SpreadTimer.Interval = [TimeSpan]::FromMilliseconds(250)
function Get-PlaceId([string]$url) { if ($url -match '/games/(\d+)') { return $Matches[1] }; return "" }
function Request-Servers($job) {
    $u = "https://games.roblox.com/v1/games/$($job.Place)/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
    $job.Task = $script:Http.GetStringAsync($u); $job.Tries++
}
function Start-Spread($accs, [string]$url) {
    # Asks Roblox for the game's public servers (in the background), then opens the accounts on them.
    $place = Get-PlaceId $url
    if (-not $place -or $script:SpreadJob) { Queue-Items @($accs | ForEach-Object { [pscustomobject]@{ Acc = $_; Url = $url; Kind = "normal" } }); return }
    $script:SpreadJob = @{ Accs = @($accs); Url = $url; Place = $place; Tries = 0; Task = $null; RetryAt = $null }
    Request-Servers $script:SpreadJob
    $SpreadTimer.Start()
    Say "Finding servers with room..."
}
$SpreadTimer.Add_Tick({
    $j = $script:SpreadJob
    if (-not $j) { $SpreadTimer.Stop(); return }
    if ($j.RetryAt) { if ([DateTime]::Now -lt $j.RetryAt) { return }; $j.RetryAt = $null; Request-Servers $j; return }
    if (-not $j.Task.IsCompleted) { return }
    $servers = $null; $err = ""
    try { $servers = @(($j.Task.Result | ConvertFrom-Json).data) } catch { $err = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) }
    if ($null -eq $servers) {
        if ($j.Tries -lt 2) { $j.RetryAt = [DateTime]::Now.AddSeconds(3); return }   # once more, then give up
        $SpreadTimer.Stop(); $script:SpreadJob = $null
        Say "Couldn't get the game's server list ($err). Roblox picks the servers this time."
        Queue-Items @($j.Accs | ForEach-Object { [pscustomobject]@{ Acc = $_; Url = $j.Url; Kind = "normal" } })
        return
    }
    $SpreadTimer.Stop(); $script:SpreadJob = $null
    # Your accounts already on a server of this game count toward its limit.
    $already = @{}
    foreach ($w in @($script:Wins)) { if ($w.Sess.Place -eq $j.Place -and $w.Sess.Job -and @("joining", "connected") -contains $w.Sess.State) { $already[$w.Sess.Job] = [int]$already[$w.Sess.Job] + 1 } }
    # Only accounts whose helper can join a chosen server get one.
    $can = @($j.Accs | Where-Object { $_.autoJoin -and @("on", "elsewhere", "unknown") -contains (Get-SetupFor $_).Helper })
    $pick = Select-Servers $servers $can.Count $script:State.spread $already
    $items = @(); $i = 0
    foreach ($a in $j.Accs) {
        $job = $(if (@($can) -contains $a -and $i -lt $pick.Jobs.Count) { $pick.Jobs[$i++] } else { "" })
        $items += $(if ($job) { [pscustomobject]@{ Acc = $a; Url = "https://www.roblox.com/games/$($j.Place)"; Kind = "normal"; Job = $job; Place = $j.Place } }
                    else { [pscustomobject]@{ Acc = $a; Url = $j.Url; Kind = "normal" } })
    }
    $used = @($pick.Jobs | Select-Object -Unique).Count
    $msg = "Spreading: $($pick.Jobs.Count) account(s) on $used server(s), up to $($script:State.spread) per server."
    if ($pick.Short -gt 0) { $msg += " $($pick.Short) didn't fit (servers are full) and go wherever Roblox puts them." }
    $noHelper = $j.Accs.Count - $can.Count
    if ($noHelper -gt 0) { $msg += " $noHelper without auto-click / helper go wherever Roblox puts them." }
    Say $msg
    Queue-Items $items
})

function Start-Everything([string]$LinkOverride, [switch]$Silent) {
    $main = Get-Main
    if (-not $main) { Say "Star your main account first."; if ($Silent) { Send-Webhook "Scheduled start skipped: no main account is set." }; return }
    if ([string]::IsNullOrWhiteSpace($main.profileUrl)) {
        if ($Silent) { Say "Scheduled start skipped: your main has no profile link."; Send-Webhook "Scheduled start skipped: add your main's profile link in BloxKit."; return }
        [BkBox]::Show("Add your main's Roblox profile link first (... > Edit on $($main.nick)).`n`nThe alts use it to join your main's server.", "One thing missing", "OK", "Information") | Out-Null
        return
    }
    $linkText = $(if ($LinkOverride) { $LinkOverride } else { $ui.LinkBox.Text })
    $info = Get-LinkInfo $linkText
    if (@("game","private","share") -notcontains $info.Kind) {
        if ($Silent) { Say "Scheduled start skipped: no game link set."; Send-Webhook "Scheduled start skipped: pick a game link in Settings > Scheduled start."; return }
        [BkBox]::Show("Paste the game (or private server) link your main should join first.", "Which game?", "OK", "Information") | Out-Null
        $ui.LinkBox.Focus() | Out-Null; return
    }
    if (-not $Silent) {
        if (-not (Check-MultiWindow)) { return }
        $script:State.lastLink = $ui.LinkBox.Text; Save-Settings
    }
    if (Get-WindowOf $main.nick) {
        # main is already playing: just send the alts
        $alts = @($script:State.accounts | Where-Object { -not $_.isMain -and -not (Get-WindowOf $_.nick) })
        $items = @(); foreach ($a in $alts) { $items += [pscustomobject]@{ Acc = $a; Url = (Get-LinkInfo $main.profileUrl).Url; Kind = "normal" } }
        Say "$($main.nick) is already in a game. Sending the alts to it."
        Queue-Items $items
        return
    }
    Queue-Items @([pscustomobject]@{ Acc = $main; Url = $info.Url; Kind = "main" })
}

function Update-Progress([string]$msg) {
    $ui.ProgressText.Text = $msg
    $ui.ProgressBar.Value = $(if ($script:QTotal -gt 0) { $script:QDone / $script:QTotal } else { 0 })
}

function Step-Queue {
    if (-not $script:QBusy) { return }
    $now = [DateTime]::Now
    switch ($script:QPhase) {
        "idle" {
            if ($script:Q.Count -eq 0) { Finish-Queue; return }
            $script:QCur = $script:Q[0]; $script:Q.RemoveAt(0)
            # Every launch gets its own record; the Roblox window it opens is matched to it
            # by when that window's process started (see Select-LaunchForWindow).
            $op = [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Acc = $script:QCur.Acc; Url = $script:QCur.Url; Start = $now; Hwnd = [long]0
                                     Cancelled = $false; TabTracked = $false; TabDone = $false }
            $script:QCur | Add-Member -NotePropertyName Op -NotePropertyValue $op -Force
            foreach ($o in @($script:Ops)) { if (($now - $o.Start).TotalMinutes -gt 30) { $script:Ops.Remove($o) } }
            $script:Ops.Add($op) | Out-Null
            $setup = Get-SetupFor $script:QCur.Acc
            # Without the helper in that profile, a marker only gets in the way
            # (Roblox's page moves a private server's code behind it).
            $auto = $script:QCur.Acc.autoJoin -and @("on", "elsewhere", "unknown") -contains $setup.Helper
            $tabOp = ""
            $skip = Get-TabSkipReason $script:State.tabCloseWhen $setup
            if (-not $skip -and -not (Start-TabServer)) { $skip = "Windows didn't allow a local port for tab closing." }
            $op | Add-Member -NotePropertyName TabAsked -NotePropertyValue 0 -Force
            if ($skip) {
                # Tab closing is on, but can't work for this launch: say why (once per launch).
                if ($script:State.tabCloseWhen -ne "off") { Set-TabReport $script:QCur.Acc.nick "won't close" $skip }
            } else { $tabOp = $op.Id; $op.TabTracked = $true }
            # Remember which server this launch aims for (checked against the Roblox log once it joins).
            $script:Planned[$script:QCur.Acc.nick.ToLower()] = $(if ($auto -and ("" + $script:QCur.Job)) { "" + $script:QCur.Job } else { "" })
            $url = Add-Marker $script:QCur.Url $auto ("" + $script:QCur.Job) ("" + $script:QCur.Place) $tabOp $script:TabPort
            if (-not (Open-Chrome $script:QCur.Acc $url)) { $script:Ops.Remove($op); Cancel-Queue; return }
            $script:QStart = $now; $script:QPhase = "wait"
            Update-Progress ("Opening {0} ({1} of {2})... waiting for its Roblox window" -f $script:QCur.Acc.nick, ($script:QDone + 1), $script:QTotal)
        }
        "wait" {
            Refresh-Windows   # names the new window if it belongs to this launch
            if ($script:QCur.Op.Hwnd -ne 0) {
                Set-AccStatus $script:QCur.Acc.nick $null
                $script:QLoaded++
                $wait = $(if ($script:QCur.Kind -eq "main") { $script:State.mainSettle } else { $script:State.launchSettle })
                $script:QUntil = $now.AddSeconds($wait); $script:QPhase = "settle"
                Render-Accounts
                return
            }
            $left = [int]($script:State.launchTimeout - ($now - $script:QStart).TotalSeconds)
            if ($left -le 0) {
                $script:QFailed.Add($script:QCur) | Out-Null
                Set-AccStatus $script:QCur.Acc.nick "failed"
                $script:QDone++
                Say "$($script:QCur.Acc.nick) didn't load in time."
                if ($script:QCur.Kind -eq "main") {
                    # Nothing that was waiting is sent now; don't leave it showing "Opening...".
                    foreach ($it in @($script:Q)) { Set-AccStatus $it.Acc.nick $null }
                    $fl = $script:QCur.PSObject.Properties["Followers"]
                    if ($fl) { foreach ($n in @($fl.Value)) { Set-AccStatus $n $null } }
                    $script:Q.Clear()
                    Update-Progress "$($script:QCur.Acc.nick) (your main) didn't load, so the alts weren't sent. Check its Chrome window, then try again."
                    Finish-Queue -Quiet; return
                }
                $script:QPhase = "idle"; Render-Accounts
                return
            }
            Update-Progress ("Opening {0} ({1} of {2})... waiting for its Roblox window ({3}s left)" -f $script:QCur.Acc.nick, ($script:QDone + 1), $script:QTotal, $left)
        }
        "settle" {
            $left = [int][Math]::Ceiling(($script:QUntil - $now).TotalSeconds)
            if ($left -gt 0) {
                if ($script:QCur.Kind -eq "main") { Update-Progress ("{0} is loading into the game... alts follow in {1}s" -f $script:QCur.Acc.nick, $left) }
                else { Update-Progress ("{0} loaded. Next one in {1}s..." -f $script:QCur.Acc.nick, $left) }
                return
            }
            $script:QDone++
            if ($script:QCur.Kind -eq "main") {
                $mainUrl = (Get-LinkInfo $script:QCur.Acc.profileUrl).Url
                # Followers = a schedule's group; otherwise ("Start everything") every alt.
                $who = $script:QCur.PSObject.Properties["Followers"]
                $inQueue = @($script:Q | ForEach-Object { $_.Acc.nick })   # never queue an account twice
                $alts = @($script:State.accounts | Where-Object { -not $_.isMain -and -not (Get-WindowOf $_.nick) -and $inQueue -inotcontains $_.nick -and (-not $who -or @($who.Value) -icontains $_.nick) })
                # the main is open now; the limit applies to the alts that follow it
                $altItems = @(Limit-Launches @($alts | ForEach-Object { [pscustomobject]@{ Acc = $_; Url = $mainUrl; Kind = "normal" } }))
                foreach ($it in $altItems) {
                    $script:Q.Add($it) | Out-Null
                    Set-AccStatus $it.Acc.nick "opening"
                }
                $script:QTotal += $altItems.Count
                Render-Accounts
            }
            $script:QPhase = "idle"
        }
    }
}

function Finish-Queue([switch]$Quiet) {
    $QueueTimer.Stop()
    $script:QBusy = $false; $script:QPhase = "idle"; $script:QCur = $null
    $ui.ProgressBar.Value = 1
    if (-not $Quiet) {
        $msg = "Done! $($script:QLoaded) of $($script:QTotal) loaded."
        if ($script:QFailed.Count -gt 0) {
            $msg += " Didn't load: " + ((@($script:QFailed) | ForEach-Object { $_.Acc.nick }) -join ", ") + "."
        }
        Update-Progress $msg
        Say $msg
        # The mascot reacts to how it really went: everyone opened (a small celebration for a batch), or some didn't.
        if ($script:QFailed.Count -gt 0) { Show-MascotMoment "Error" $msg 8 }
        elseif ($script:QTotal -ge 2) { Show-MascotMoment "Celebrate" $msg 4 }
        elseif ($script:QTotal -eq 1) { Show-MascotMoment "Success" $msg 4 }
        if ($script:QFailed.Count -gt 0 -or $script:State.webhookOnDone) { Send-Webhook "BloxKit: $msg" }
    }
    $ui.RetryBtn.Visibility = $(if ($script:QFailed.Count -gt 0) { "Visible" } else { "Collapsed" })
    Render-Accounts; Update-Buttons
}

function Cancel-Queue {
    if ($script:QCur -and $script:QCur.Op) { $script:QCur.Op.Cancelled = $true }   # its tab stays open
    foreach ($it in @($script:Q)) { Set-AccStatus $it.Acc.nick $null }
    if ($script:QCur) { Set-AccStatus $script:QCur.Acc.nick $null }
    $script:Q.Clear()
    Finish-Queue -Quiet
    Update-Progress "Stopped. Accounts already open stay open."
    Say "Stopped opening accounts."
}

$QueueTimer = New-Object System.Windows.Threading.DispatcherTimer
$QueueTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$QueueTimer.Add_Tick({ Step-Queue })

# ----- closing the Chrome tab a launch came from (needs helper 2.2) -----
# The helper asks every 2 seconds; this answers on 127.0.0.1 only. Started the first time
# it's needed, checked only while a launch is waiting for an answer.
$script:TabListener = $null
$script:TabPort = 0
$TabTimer = New-Object System.Windows.Threading.DispatcherTimer
$TabTimer.Interval = [TimeSpan]::FromMilliseconds(400)
function Start-TabServer {
    if (-not $script:TabListener) {
        try { $script:TabListener = Start-TabListener; $script:TabPort = $script:TabListener.LocalEndpoint.Port }
        catch { Say "Tab closing is off for now: Windows didn't allow a local port ($($_.Exception.Message))."; return $false }
    }
    $TabTimer.Start()
    return $true
}
$TabAnswer = {
    param($req)
    $op = @($script:Ops | Where-Object { $_.Id -eq $req.Op }) | Select-Object -First 1
    if ($op -and $op.TabDone) { return $op.TabFinal }   # an answer once given never changes ("keep" stays "keep")
    $w = $(if ($op -and $op.Hwnd) { @($script:Wins | Where-Object { $_.Handle.ToInt64() -eq $op.Hwnd }) | Select-Object -First 1 } else { $null })
    $ws = $(if ($w) { Get-WinState $w } else { "" })
    $v = Get-TabVerdict $op $ws ([DateTime]::Now) $script:State.tabCloseWhen ($script:State.launchTimeout * 2)
    $a = $v.State
    if ($op) { $op.TabAsked = [int]$op.TabAsked + 1 }
    if ($op -and $a -ne "wait" -and -not $op.TabDone) {
        $op.TabDone = $true; $op | Add-Member -NotePropertyName TabFinal -NotePropertyValue $a -Force   # the helper stops asking after any answer but "wait"
        Set-TabReport $op.Acc.nick $(if ($a -eq "close") { "closed" } else { "kept open" }) $v.Why
    }
    return $a
}
function Set-TabReport([string]$nick, [string]$what, [string]$why) {
    # "Last launch tab" under the setting, and the footer: what happened to a launch's tab, and why.
    $t = "Last launch tab ($nick, $(Get-Date -Format 'HH:mm')): $what. $why"
    $ui.TabCloseLast.Text = $t
    $ui.TabCloseLast.Foreground = Brush $(if ($what -eq "closed") { "SuccessInk" } else { "WarningInk" })
    Say $t
}
$TabTimer.Add_Tick({
    Step-TabListener $script:TabListener $TabAnswer | Out-Null
    foreach ($o in @($script:Ops | Where-Object { $_.TabTracked -and -not $_.TabDone -and -not $_.TabWarned -and [int]$_.TabAsked -eq 0 -and ([DateTime]::Now - $_.Start).TotalSeconds -ge 30 })) {
        # The page opened with a launch id 30 s ago, but the helper never asked about it.
        $o | Add-Member -NotePropertyName TabWarned -NotePropertyValue $true -Force
        Set-TabReport $o.Acc.nick "not asked about yet" "The helper in Chrome hasn't contacted BloxKit. Check on chrome://extensions in that profile that 'BloxKit Auto-Join Helper' 2.2 is on and shows no errors; if it is, something on this PC blocks Chrome from reaching 127.0.0.1."
    }
    $waiting = @($script:Ops | Where-Object { $_.TabTracked -and -not $_.TabDone -and ([DateTime]::Now - $_.Start).TotalMinutes -lt 16 })
    if ($waiting.Count -eq 0) { $TabTimer.Stop() }   # nothing to answer; the port stays open for later launches
})

# ======================================================= ALERTS / REJOIN ==
$script:AlertNick = $null
function Raise-Alert([string]$nick, [string]$kind = "closed", [string]$detail = "") {
    $acc = Find-Account $nick
    $time = Get-Date -Format "HH:mm"
    if ($kind -eq "disc" -and $detail) {
        $msg = "$nick was disconnected at ${time}: $detail."
    } elseif ($kind -eq "disc") {
        $msg = "$nick might be disconnected (Roblox's message box is showing) at $time."
    } else {
        Set-AccStatus $nick "disc"
        $msg = "$nick's Roblox window closed at $time (kicked, crashed, or closed)."
    }
    $script:AlertNick = $nick
    $auto = $false
    if ($script:State.autoRejoin -and $acc) {
        $key = $nick.ToLower()
        $recent = @($script:RejoinLog[$key] | Where-Object { $_ -gt [DateTime]::Now.AddMinutes(-10) })
        if ($recent.Count -lt 3) {
            $script:RejoinLog[$key] = @($recent + [DateTime]::Now)
            $auto = $true
        } else {
            $msg += " Auto-rejoin paused (3 tries in 10 minutes)."
        }
    }
    if ($auto) { $msg += " Rejoining automatically..." }
    $ui.AlertText.Text = [string][char]0x26A0 + "  " + $msg
    $ui.AlertRejoinBtn.Visibility = $(if ($acc -and -not $auto) { "Visible" } else { "Collapsed" })
    $ui.AlertBar.Visibility = "Visible"
    if ($script:State.alertSound) { [System.Media.SystemSounds]::Exclamation.Play() }
    if ($Tray -and (-not $win.IsVisible -or $win.WindowState -eq "Minimized" -or -not $win.IsActive)) {
        $Tray.ShowBalloonTip(5000, "BloxKit", $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    Say $msg
    Send-Webhook ([string][char]0x26A0 + " " + $msg)
    Render-Accounts
    if ($auto) { $script:PendingRejoin.Add($acc) | Out-Null }   # handled on the next tick
}
$script:PendingRejoin = New-Object System.Collections.ArrayList

function Rejoin-Account($acc) {
    if (-not $acc) { return }
    $old = Get-WindowOf $acc.nick
    if ($old) { Close-RobloxWindow $old -NoAsk }   # e.g. stuck on a 'Disconnected' box
    $url = $acc.lastUrl
    if (-not $url) {
        $info = Get-LinkInfo $ui.LinkBox.Text
        if (@("empty","bad") -contains $info.Kind) { Say "Don't know where $($acc.nick) was. Paste a link and click Open."; return }
        $url = $info.Url
    }
    # Same server when we know it from Roblox's log. Alts that follow the main keep
    # following it, and private servers keep using their private link.
    $job = ""; $place = ""
    $srv = $script:LastServer[$acc.nick.ToLower()]
    $kind = (Get-LinkInfo $url).Kind
    if ($srv -and $script:State.rejoinSameServer -and $acc.autoJoin -and @("profile","private") -notcontains $kind) {
        $url = "https://www.roblox.com/games/$($srv.Place)"; $job = $srv.Job; $place = $srv.Place
    }
    Queue-Items @([pscustomobject]@{ Acc = $acc; Url = $url; Kind = "normal"; Job = $job; Place = $place })
}

# ========================================================= LIVE SCREENS ==
function Label-Of($w) { if ($w.Name) { "#$($w.Num) $($w.Name)" } else { "#$($w.Num)" } }

function Get-ProcStart([IntPtr]$h) {
    try { return (Get-Process -Id ([RbxCore]::PidOf($h)) -ErrorAction Stop).StartTime } catch { return $null }
}

function Refresh-Windows {
    if ($NoRoblox) { return }   # test mode never looks at (or changes) real Roblox windows
    $handles = @([RbxCore]::FindRobloxWindows())
    $hs = @($handles | ForEach-Object { $_.ToInt64() })
    $changed = $false
    foreach ($w in @($script:Wins)) {
        if ($hs -notcontains $w.Handle.ToInt64()) {
            [RbxCore]::RemoveScreen($w.Thumb)
            $script:Wins.Remove($w); $changed = $true
            if ($w.Nick) { Add-Uptime $w.Nick $w.Since }
            $key = $w.Handle.ToInt64()
            if ($script:ExpectedClose.Contains($key)) { [void]$script:ExpectedClose.Remove($key) }
            elseif ($w.Nick) { Raise-Alert $w.Nick }
        }
    }
    $claim = @()
    foreach ($h in $handles) {
        $key = $h.ToInt64()
        if (@($script:Wins | Where-Object { $_.Handle.ToInt64() -eq $key }).Count) { continue }
        [RbxCore]::Unminimize($h)
        $started = Get-ProcStart $h
        $old = $script:SessionRestore[$key]
        # Window handles get reused after a restart: only trust a saved name for the same process.
        if ($old -and $old.ps -and $started -and [long]$old.ps -ne $started.Ticks) { $old = $null }
        $obj = [pscustomobject]@{
            Handle = $h; Num = 0; Name = ""; Nick = ""; Afk = $true; Muted = $false
            Thumb = [IntPtr]::Zero; Screen = $null; Info = $null; MuteBtn = $null; LastJump = ""
            Since = [DateTime]::Now; DiscHits = 0; DiscFlag = $false; DiscText = ""
            ClickX = 0.5; ClickY = 0.5; Tile = $null
            Eco = $false; EcoFailed = $false
            LogPath = ""; LogPos = [long]0; LogTries = 0; Sess = (New-Session ([DateTime]::Now)); ProcStart = $started
        }
        if ($old) {
            $obj.Name = "" + $old.name; $obj.Nick = "" + $old.nick; $obj.Afk = [bool]$old.afk; $obj.Muted = [bool]$old.muted
            $sp = Get-SpotFor $obj.Nick; $obj.ClickX = $sp[0]; $obj.ClickY = $sp[1]
            if ($null -ne $old.cx -and -not $obj.Nick) { $obj.ClickX = [double]$old.cx; $obj.ClickY = [double]$old.cy }
            if ($old.num -and -not (@($script:Wins | Where-Object { $_.Num -eq [int]$old.num }).Count)) { $obj.Num = [int]$old.num }
        }
        if ($obj.Num -eq 0) {
            $n = 1; while (@($script:Wins | Where-Object { $_.Num -eq $n }).Count) { $n++ }
            $obj.Num = $n
        }
        $script:Wins.Add($obj) | Out-Null
        if ($obj.Muted) { [RbxCore]::SetProcessMute([RbxCore]::PidOf($h), $true) | Out-Null }
        if (-not $obj.Nick -and $started) {
            # Which launch opened it? (a window opened some other way stays unnamed)
            $op = Select-LaunchForWindow $started $script:Ops $script:State.launchTimeout   # its program must have started within the launch's time limit
            if ($op) { $op.Hwnd = $key; $claim += @{ H = $h; Op = $op } }
        }
        $changed = $true
    }
    foreach ($c in $claim) { Claim-Window $c.H $c.Op }
    if ($changed) {
        $sorted = @($script:Wins | Sort-Object Num)
        $script:Wins.Clear(); foreach ($x in $sorted) { $script:Wins.Add($x) | Out-Null }
        $script:SessionDirty = $true
        Build-Wall; Render-Accounts
        Apply-Efficiency
    }
}

function Claim-Window([IntPtr]$h, $op) {
    # Names a new window after the account whose launch opened it.
    $acc = $op.Acc
    if (-not (Find-Account $acc.nick)) { return }   # account was removed meanwhile
    Assign-Window $h $acc
    # Roblox only opens for a signed-in account, so it's signed in on this PC now.
    $acc.lastUrl = $op.Url; $acc.needsLogin = $false; Save-Settings
    if (-not ($script:QCur -and (Same $script:QCur.Op $op))) {
        # A window from a launch that had already given up: it did load after all.
        Set-AccStatus $acc.nick $null
        foreach ($f in @($script:QFailed)) { if (Same $f.Op $op) { $script:QFailed.Remove($f) } }
        if ($script:QFailed.Count -eq 0) { $ui.RetryBtn.Visibility = "Collapsed" }
        Say "$($acc.nick)'s Roblox window showed up late. It's named now, so it won't be opened again."
    }
}

function Assign-Window([IntPtr]$h, $acc) {
    $w = @($script:Wins | Where-Object { $_.Handle -eq $h }) | Select-Object -First 1
    if (-not $w) { return }
    $w.Nick = $acc.nick; $w.Name = $acc.nick; $w.Since = [DateTime]::Now; $w.Afk = Get-ScreenAfk $acc.nick
    $sp = Get-SpotFor $acc.nick; $w.ClickX = $sp[0]; $w.ClickY = $sp[1]
    Set-Mute $w (Get-AccountMuted $script:State $acc) -Quiet -Auto   # sound by account: the main always has it
    # One account can only be in one server: an older window of it is finished (Roblox
    # disconnects it), so close it instead of leaving it on a 'Disconnected' box.
    foreach ($o in @($script:Wins | Where-Object { $_.Nick -ieq $acc.nick -and $_.Handle -ne $h })) { Close-ReplacedWindow $o "$($acc.nick) opened in a new window" }
    if ($script:State.lowPower) { Apply-LowPower }
    Apply-Efficiency
    $script:SessionDirty = $true
    Build-Wall
}

function New-SmallButton([string]$text, [string]$tip, [string]$bg) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $BtnStyle; $b.Content = $text; $b.ToolTip = $tip
    $b.Padding = New-Object System.Windows.Thickness 9,4,9,4
    $b.Margin = New-Object System.Windows.Thickness 5,0,0,0
    if ($bg) { $b.Background = Brush $bg }
    [System.Windows.Controls.DockPanel]::SetDock($b, "Right")
    return $b
}

function Build-Wall {
    # Main first, then the other accounts in list order; screen numbers (Ctrl+Alt+1..9) follow.
    $order = @(Get-ScreenOrder $script:Wins $script:State.accounts)
    for ($i = 0; $i -lt $order.Count; $i++) { if ($order[$i].Num -ne $i + 1) { $order[$i].Num = $i + 1; $script:SessionDirty = $true } }
    $script:Wins.Clear(); foreach ($x in $order) { $script:Wins.Add($x) | Out-Null }
    foreach ($w in $script:Wins) { [RbxCore]::RemoveScreen($w.Thumb); $w.Thumb = [IntPtr]::Zero }
    $ui.Wall.Children.Clear()
    $n = $script:Wins.Count
    $ui.TabScreens.Header = "Live screens ($n)"
    $ui.EmptyWall.Visibility = $(if ($n -eq 0) { "Visible" } else { "Collapsed" })
    if ($n -eq 0) { return }
    $cols = [int][Math]::Ceiling([Math]::Sqrt($n))
    $ui.Wall.Columns = $cols
    $ui.Wall.Rows = [int][Math]::Ceiling($n / $cols)

    foreach ($w in $script:Wins) {
        $tile = New-Object System.Windows.Controls.Border
        $tile.Background = Brush "Surface"; $tile.CornerRadius = New-Object System.Windows.CornerRadius 10
        $tile.BorderBrush = Brush "Line"; $tile.BorderThickness = New-Object System.Windows.Thickness 2
        $tile.Margin = New-Object System.Windows.Thickness 4; $tile.Padding = New-Object System.Windows.Thickness 6
        $w.Tile = $tile
        $dock = New-Object System.Windows.Controls.DockPanel

        $bar = New-Object System.Windows.Controls.DockPanel
        $bar.Margin = New-Object System.Windows.Thickness 2,0,2,6
        [System.Windows.Controls.DockPanel]::SetDock($bar, "Top")

        $num = New-Object System.Windows.Controls.TextBlock
        $num.Text = "#$($w.Num)"; $num.Foreground = Brush "Star"; $num.FontWeight = "Bold"; $num.FontSize = 15
        $num.VerticalAlignment = "Center"; $num.Margin = New-Object System.Windows.Thickness 0,0,8,0
        [System.Windows.Controls.DockPanel]::SetDock($num, "Left")

        # Everyday buttons stay visible; the rest live in the "..." menu.
        $more = New-SmallButton ([string][char]0x22EF) "More: test anti-AFK, set click spot, close" ""
        $more.Tag = $w
        $more.Add_Click({
            param($s,$e)
            $ww = $s.Tag
            $menu = New-Object System.Windows.Controls.ContextMenu
            $menu.Style = $win.FindResource("DarkMenu")
            foreach ($it in @(
                @{ H = "Test anti-AFK on this screen"; A = "test" },
                @{ H = "Set click spot (for the 'Click a spot' action)"; A = "spot" },
                @{ H = "Reset click spot to the middle"; A = "spotreset" },
                @{ H = "Close this Roblox window"; A = "close" })) {
                $mi = New-Object System.Windows.Controls.MenuItem
                $mi.Style = $win.FindResource("DarkItem")
                $mi.Header = $it.H; $mi.Tag = @{ W = $ww; Act = $it.A }
                if ($it.A -eq "close") { $mi.Foreground = Brush "DangerSoftInk" }
                $mi.Add_Click({
                    param($m,$x)
                    $tg = $m.Tag
                    switch ($tg.Act) {
                        "test"      { Test-HiddenJump $tg.W }
                        "spot"      { Start-PickSpot $tg.W }
                        "spotreset" {
                            $tg.W.ClickX = 0.5; $tg.W.ClickY = 0.5
                            if ($tg.W.Nick) { $script:State.clickSpots.Remove($tg.W.Nick.ToLower()); Save-Settings }
                            Update-TileInfo $tg.W; Say "Click spot for $(Label-Of $tg.W) is the middle again."
                        }
                        "close"     { Close-RobloxWindow $tg.W }
                    }
                })
                $menu.Items.Add($mi) | Out-Null
            }
            $menu.PlacementTarget = $s; $menu.IsOpen = $true
        })
        $play = New-SmallButton "Play" "Play this window (Ctrl+Alt+G to come back)" "Accent"
        $play.Tag = $w; $play.Add_Click({ param($s,$e) Play-Window $s.Tag })
        $mute = New-SmallButton $(if ($w.Muted) { "Unmute" } else { "Mute" }) "Turn this window's sound off or on" $(if ($w.Muted) { "Violet" } else { "" })
        $mute.Tag = $w; $mute.Add_Click({ param($s,$e) Set-Mute $s.Tag (-not $s.Tag.Muted) })
        $w.MuteBtn = $mute

        $afk = New-Object System.Windows.Controls.CheckBox
        $afk.Content = "AFK"; $afk.IsChecked = $w.Afk; $afk.VerticalAlignment = "Center"
        $afk.Margin = New-Object System.Windows.Thickness 10,0,4,0; $afk.ToolTip = "Keep this screen awake with anti-AFK"
        $afk.Tag = $w; $afk.Add_Click({ param($s,$e) Set-ScreenAfk $s.Tag ([bool]$s.IsChecked); Save-Settings })
        [System.Windows.Controls.DockPanel]::SetDock($afk, "Right")

        $name = New-Object System.Windows.Controls.TextBox
        $name.Text = $w.Name
        $name.Padding = New-Object System.Windows.Thickness 8,4,8,4; $name.VerticalAlignment = "Center"
        $name.ToolTip = "Name of this window. Type an account's nickname to link it to that account."
        $name.Tag = $w
        $name.Add_LostFocus({
            param($s,$e)
            $ww = $s.Tag; $ww.Name = $s.Text.Trim()
            $acc = Find-Account $ww.Name
            if ($ww.Nick -and (-not $acc -or $acc.nick -ine $ww.Nick)) { Add-Uptime $ww.Nick $ww.Since }
            if ($acc -and $acc.nick -ine $ww.Nick) { $ww.Since = [DateTime]::Now }
            $ww.Nick = $(if ($acc) { $acc.nick } else { "" })
            if ($acc) { $sp = Get-SpotFor $acc.nick; $ww.ClickX = $sp[0]; $ww.ClickY = $sp[1] }
            $script:SessionDirty = $true; Render-Accounts
        })

        foreach ($c in $num, $more, $play, $mute, $afk, $name) { $bar.Children.Add($c) | Out-Null }
        if (Same $script:PickFor $w) { $tile.BorderBrush = Brush "Star" }

        $info = New-Object System.Windows.Controls.TextBlock
        $info.FontSize = 12; $info.Foreground = Brush "Muted"; $info.Margin = New-Object System.Windows.Thickness 4,6,0,0
        $info.TextTrimming = "CharacterEllipsis"
        [System.Windows.Controls.DockPanel]::SetDock($info, "Bottom")
        $w.Info = $info; Update-TileInfo $w

        $screen = New-Object System.Windows.Controls.Border
        $screen.Background = Brush "Screen"; $screen.CornerRadius = New-Object System.Windows.CornerRadius 6
        $screen.Cursor = [System.Windows.Input.Cursors]::Hand; $screen.ToolTip = "Click to play this window"
        $msg = New-Object System.Windows.Controls.TextBlock
        $msg.Text = "Loading screen... (if this stays, the window may be minimized. Click to open it.)"
        $msg.Foreground = Brush "Faint"; $msg.TextWrapping = "Wrap"; $msg.TextAlignment = "Center"
        $msg.HorizontalAlignment = "Center"; $msg.VerticalAlignment = "Center"; $msg.Margin = New-Object System.Windows.Thickness 20
        $screen.Child = $msg; $screen.Tag = $w
        $screen.Add_MouseLeftButtonUp({
            param($s,$e)
            if (Same $script:PickFor $s.Tag) { Set-SpotFromScreen $s.Tag ($e.GetPosition($s)); return }
            Play-Window $s.Tag
        })

        $dock.Children.Add($bar) | Out-Null
        $dock.Children.Add($info) | Out-Null
        $dock.Children.Add($screen) | Out-Null
        $tile.Child = $dock
        $ui.Wall.Children.Add($tile) | Out-Null
        $w.Screen = $screen
        if ($script:PanelHwnd -ne [IntPtr]::Zero) { $w.Thumb = [RbxCore]::AddScreen($script:PanelHwnd, $w.Handle) }
    }
    $win.Dispatcher.BeginInvoke([Action]{ Place-Screens }, [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
}

function Update-TileInfo($w) {
    if (-not $w.Info) { return }
    $parts = @()
    $parts += $(switch (Get-WinState $w) {
        "connected" { "in game" } "joining" { "joining" } "disconnected" { "connection dropped" }
        "left" { "not in a game" } "unknown" { "game status unknown" } default { "starting" } })
    $ld = $script:LoadByPid[[RbxCore]::PidOf($w.Handle)]   # Your PC right now: this client's share
    if ($ld) { $parts += ("CPU {0:N0}%" -f $ld.CpuPct) + $(if ($null -ne $ld.GpuPct) { " GPU {0:N0}%" -f $ld.GpuPct } else { "" }) + (" {0:N1} GB" -f ($ld.MemMB / 1024)) }
    $parts += $(if ($w.Afk) { "AFK on" } else { "AFK off" })
    if ($w.LastJump) { $parts += "last: $($w.LastJump)" }
    $parts += $(if ($w.Muted) { "sound off" } else { "sound on" })
    if ($w.Eco) { $parts += "efficiency mode" }
    if (@($script:State.afkActions) -contains "click") {
        $parts += $(if ($w.ClickX -eq 0.5 -and $w.ClickY -eq 0.5) { "clicks the middle" } else { "click spot {0:0}%, {1:0}%" -f ($w.ClickX * 100), ($w.ClickY * 100) })
    }
    if ($w.Nick) {
        $acc = Find-Account $w.Nick; if ($acc -and $acc.isMain) { $parts += "MAIN" }
        $up = Format-Dur (Get-TodaySecs $w.Nick); if ($up) { $parts += "online $up today" }
    }
    if ($w.DiscFlag) { $parts = @($(if ($w.DiscText) { "DISCONNECTED: $($w.DiscText)" } else { "MIGHT BE DISCONNECTED" })) + $parts }
    $w.Info.Text = ($parts -join ("  " + [char]0x00B7 + "  "))
    $w.Info.Foreground = $(if ($w.DiscFlag) { Brush "DangerInk" } else { Brush "Muted" })
}

function Place-Screens {
    if ($script:PanelHwnd -eq [IntPtr]::Zero) { return }
    $src = [System.Windows.PresentationSource]::FromVisual($win)
    if (-not $src) { return }
    $m = $src.CompositionTarget.TransformToDevice
    $showing = $ui.TabScreens.IsSelected -and $win.IsVisible -and $win.WindowState -ne "Minimized"
    foreach ($w in $script:Wins) {
        if ($w.Thumb -eq [IntPtr]::Zero -or -not $w.Screen) { continue }
        if (-not $showing -or -not $w.Screen.IsVisible -or $w.Screen.ActualWidth -lt 10) { [RbxCore]::PlaceScreen($w.Thumb, $w.Handle, 0, 0, 0, 0, $false); continue }
        $pt = $w.Screen.TransformToAncestor($win).Transform((New-Object System.Windows.Point 0, 0))
        [RbxCore]::PlaceScreen($w.Thumb, $w.Handle, [int]($pt.X * $m.M11), [int]($pt.Y * $m.M22),
            [int]($w.Screen.ActualWidth * $m.M11), [int]($w.Screen.ActualHeight * $m.M22), $true)
    }
}

function Play-Window($w) {
    if (-not [RbxCore]::IsWindow($w.Handle)) { Refresh-Windows; Say "That window is closed."; return }
    [RbxCore]::Maximize($w.Handle)
    [RbxCore]::ForceFront($w.Handle)
    $script:Playing = $w.Handle
    Apply-Efficiency   # full speed for the window you play
    Say "Playing $(Label-Of $w). Press Ctrl+Alt+G to come back."
}

function Show-App {
    if (-not $win.IsVisible) { $win.Show() }
    if ($win.WindowState -eq "Minimized") { $win.WindowState = "Normal" }
    [RbxCore]::ForceFront($script:PanelHwnd)
    $win.Activate() | Out-Null
}

function Back-To-App {
    if ($script:Playing -ne [IntPtr]::Zero -and [RbxCore]::IsWindow($script:Playing)) { [RbxCore]::Restore($script:Playing) }
    $script:Playing = [IntPtr]::Zero
    Apply-Efficiency
    Show-App
    $ui.Tabs.SelectedItem = $ui.TabScreens
    foreach ($w in $script:Wins) { [RbxCore]::Unminimize($w.Handle) }
    if ($script:State.lowPower) { Apply-LowPower }
    Place-Screens
    Say "Back to Live screens."
}

function Set-Mute($w, [bool]$on, [switch]$Quiet, [switch]$Auto) {
    # -Auto: set by the app (a new window), not your choice, so it isn't remembered for the account.
    $w.Muted = $on
    if ($w.Nick -and -not $Auto) {
        $k = $w.Nick.ToLower()
        if (-not $script:State.soundOff.ContainsKey($k) -or [bool]$script:State.soundOff[$k] -ne $on) { $script:State.soundOff[$k] = $on; Save-Settings }   # kept for its next window
    }
    $n = [RbxCore]::SetProcessMute([RbxCore]::PidOf($w.Handle), $on)
    if ($w.MuteBtn) {
        $w.MuteBtn.Content = $(if ($on) { "Unmute" } else { "Mute" })
        $w.MuteBtn.Background = $(if ($on) { Brush "Violet" } else { Brush "Raised" })
    }
    Update-TileInfo $w
    $script:SessionDirty = $true
    if (-not $Quiet) {
        if ($on -and $n -eq 0) { Say "$(Label-Of $w) will be muted as soon as it makes sound." }
        else { Say "$(Label-Of $w) sound $(if ($on) { 'off' } else { 'on' })." }
    }
}

function Set-ScreenAfk($w, [bool]$on) {
    # A screen's AFK tick. For an account's screen it's remembered for that account
    # (the caller saves), so the next window it opens starts the same way.
    $w.Afk = $on; $script:SessionDirty = $true
    if (-not $w.Nick) { return }
    $k = $w.Nick.ToLower()
    $script:State.afkOff = @(@($script:State.afkOff | Where-Object { $_ -ne $k }) + @(if (-not $on) { $k }))
}
function Get-ScreenAfk([string]$nick) { -not ($nick -and @($script:State.afkOff) -contains $nick.ToLower()) }

function Close-ReplacedWindow($w, [string]$why) {
    # Closes an account's old window quietly: no alert, no automatic rejoin (that would
    # knock the new one out of its server).
    if (-not [RbxCore]::IsWindow($w.Handle)) { return }
    [void]$script:ExpectedClose.Add($w.Handle.ToInt64())
    $w.DiscFlag = $false
    [RbxCore]::CloseWindow($w.Handle)
    Say "Closed the old window $(Label-Of $w): $why."
}

function Close-RobloxWindow($w, [switch]$NoAsk) {
    if (-not $NoAsk) {
        $r = [BkBox]::Show("Close $(Label-Of $w)? That account leaves the game.", "Close window", "YesNo", "Question")
        if ($r -ne "Yes") { return }
    }
    [void]$script:ExpectedClose.Add($w.Handle.ToInt64())
    [RbxCore]::CloseWindow($w.Handle)
    if ($w.Nick) { Set-AccStatus $w.Nick $null }
    Say "Closed $(Label-Of $w)."
}

# ============================================================== ANTI-AFK ==
$script:AfkOn = [bool]$script:State.afkOn   # on again if it was on when the app closed
$script:Waiting = $false
$script:SecondsLeft = 300
$IdleNeededMs = 10000   # a visible switch (Quick mode, or a click) waits until you are away this long
$HiddenIdleMs = 2000    # hidden mode only waits for a short pause in your typing

function Get-Targets {
    $fg = [RbxCore]::GetForegroundWindow()
    $userActive = [RbxCore]::IdleMs() -lt $IdleNeededMs
    $list = @()
    foreach ($w in @($script:Wins)) {
        if (-not $w.Afk -or -not [RbxCore]::IsWindow($w.Handle)) { continue }
        if ($script:State.afkSkipActive -and $userActive -and $w.Handle -eq $fg) { continue }
        $list += $w
    }
    return $list
}

# Each action is a small, harmless input that resets Roblox's idle timer.
$AfkActionNames = [ordered]@{ jump = "jump"; walk = "step"; zoom = "zoom"; click = "click" }

function Invoke-AfkAction($w, [string]$act, [bool]$hidden, $back = [IntPtr]::Zero) {
    # Real input to the focused window (the only kind Roblox takes). In hidden mode the window
    # gets the focus off-screen; returns where it was so Do-Jumps can put it back afterwards.
    # A click moves the real mouse pointer, so it can't happen off-screen: it shows the window.
    $h = $w.Handle
    $stash = $null
    if ($hidden -and $act -ne "click" -and $h -ne $back) { $stash = [RbxCore]::Stash($h) }
    switch ($act) {
        "walk" { [RbxCore]::FocusKey($h, 0x57, 180); [RbxCore]::FocusKey($h, 0x53, 180) }
        "zoom" { [RbxCore]::FocusKey($h, 0x49, 120); [RbxCore]::FocusKey($h, 0x4F, 120) }
        "click" { [RbxCore]::FocusClick($h, $w.ClickX, $w.ClickY) }
        default { [RbxCore]::FocusKey($h, 0x20, 100) }
    }
    return $stash
}

function Pick-AfkAction {
    $acts = @($script:State.afkActions)
    if ($acts.Count -eq 0) { $acts = @("jump") }
    return $acts[$script:Rng.Next(0, $acts.Count)]
}

function Do-Jumps([switch]$Manual) {
    $targets = @(Get-Targets)
    if ($targets.Count -eq 0) { Say "No screens to keep awake (turn AFK on for at least one screen)."; return $true }
    $hidden = $script:State.afkMode -eq "hidden"
    $picks = @(foreach ($w in $targets) { @{ W = $w; Act = (Pick-AfkAction) } })   # each screen gets its own random pick
    # Every mode briefly moves the keyboard focus, so it waits for a pause in your typing.
    # Hidden mode needs a short one (nothing shows); a visible switch, or a click, needs you away.
    $visible = (-not $hidden) -or @($picks | Where-Object { $_.Act -eq "click" }).Count
    $need = $(if ($visible) { $IdleNeededMs } else { $HiddenIdleMs })
    if (-not $Manual -and [RbxCore]::IdleMs() -lt $need) { return $false }
    $t = Get-Date -Format "HH:mm"
    $done = Invoke-AfkPass $picks $hidden
    foreach ($p in $picks) { $p.W.LastJump = "$t $($AfkActionNames[$p.Act])"; Update-TileInfo $p.W }
    if ($hidden) {
        # Measured on Roblox: a hidden visit gets through about 3 times in 4, and when it doesn't,
        # Roblox ignores the whole visit (more presses in it don't help). Visits fail on their
        # own, so a second one 1.5 s later makes it about as sure as Quick switch.
        $script:AfkAgain = @($picks | Where-Object { $_.Act -ne "click" })
        if ($script:AfkAgain.Count) { $AfkAgainTimer.Start() }
    }
    $what = ($done | Group-Object | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ", "
    Say "Anti-AFK: $what ($($script:State.afkMode) mode)."
    return $true
}

function Invoke-AfkPass($picks, [bool]$hidden) {
    # One visit to each screen. Returns what was done.
    $back = [RbxCore]::GetForegroundWindow()
    $done = @(); $stashed = @()
    try {
        foreach ($p in $picks) {
            if (-not [RbxCore]::IsWindow($p.W.Handle)) { continue }
            $r = Invoke-AfkAction $p.W $p.Act $hidden $back
            if ($null -ne $r) { $stashed += @{ H = $p.W.Handle; R = $r } }
            $done += $AfkActionNames[$p.Act]
        }
    } finally {
        # Focus goes back first, then the windows come back, so none of them ever shows up front.
        if ([RbxCore]::IsWindow($back)) { [RbxCore]::ForceFront($back) }
        foreach ($s in $stashed) { [RbxCore]::Unstash($s.H, $s.R) }
    }
    return $done
}
$script:AfkAgain = @()
$AfkAgainTimer = New-Object System.Windows.Threading.DispatcherTimer
$AfkAgainTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$AfkAgainTimer.Add_Tick({
    # The second hidden visit, only if you're still not typing (otherwise the first one has to do).
    $AfkAgainTimer.Stop()
    $again = @($script:AfkAgain); $script:AfkAgain = @()
    if ($again.Count -and $script:State.afkMode -eq "hidden" -and [RbxCore]::IdleMs() -ge 1000) { Invoke-AfkPass $again $true | Out-Null }
})

function Test-HiddenJump($w) {
    $ui.Tabs.SelectedItem = $ui.TabScreens
    $acts = @($script:State.afkActions); if ($acts.Count -eq 0) { $acts = @("jump") }
    $names = ($acts | ForEach-Object { $AfkActionNames[$_] }) -join ", "
    $r = [BkBox]::Show("Watch screen $(Label-Of $w) here on the Live screens tab.`n`nClick OK and don't touch the keyboard for a few seconds. It will do these the hidden way (off-screen, nothing pops up), one by one: $names.", "Test anti-AFK", "OKCancel", "Information")
    if ($r -ne "OK") { return }
    Start-Sleep -Milliseconds 300
    foreach ($a in $acts) {
        # Like a real round: a hidden visit, and a second one 1.5 s later (a click shows the window once).
        Invoke-AfkPass @(@{ W = $w; Act = $a }) $true | Out-Null
        if ($a -ne "click") { Start-Sleep -Milliseconds 1500; Invoke-AfkPass @(@{ W = $w; Act = $a }) $true | Out-Null }
        Start-Sleep -Milliseconds 900
    }
    Start-Sleep -Milliseconds 500
    $ans = [BkBox]::Show("Did screen $(Label-Of $w) react ($names)?", "Test anti-AFK", "YesNo", "Question")
    if ($ans -eq "Yes") { $ui.ModeHidden.IsChecked = $true; $script:State.afkMode = "hidden"; Say "Hidden mode works on your PC. Anti-AFK will stay out of sight."; Show-MascotMoment "Success" "Hidden anti-AFK works on this PC." }
    else { $ui.ModeQuick.IsChecked = $true; $script:State.afkMode = "quick"; Say "Hidden mode didn't work here, so I switched to Quick switch (it runs only while you're away)." }
    Save-Settings
}

# ----- click spot: where the "click" action clicks, picked on the live screen -----
$script:PickFor = $null
function Get-SpotFor([string]$nick) {
    $v = $(if ($nick) { $script:State.clickSpots[$nick.ToLower()] } else { $null })
    if ($v -and $v -match '^([\d.]+),([\d.]+)$') { return @([double]$Matches[1], [double]$Matches[2]) }
    return @(0.5, 0.5)
}
function Start-PickSpot($w) {
    $script:PickFor = $w
    $ui.Tabs.SelectedItem = $ui.TabScreens
    if ($w.Tile) { $w.Tile.BorderBrush = Brush "Star" }
    Say "Click the spot on screen $(Label-Of $w) where anti-AFK should click. Press Esc to cancel."
}
function Stop-PickSpot {
    if ($script:PickFor -and $script:PickFor.Tile) { $script:PickFor.Tile.BorderBrush = Brush "Line" }
    $script:PickFor = $null
}
function Set-SpotFromScreen($w, $pos) {
    # The live picture is fitted inside the screen box with bars on the sides or top,
    # the same way PlaceScreen draws it. Undo that to get a spot inside the window.
    $size = [RbxCore]::ClientSize($w.Handle)
    $bw = $w.Screen.ActualWidth; $bh = $w.Screen.ActualHeight
    if ($size[0] -le 0 -or $bw -le 0) { Stop-PickSpot; return }
    $k = [Math]::Min($bw / $size[0], $bh / $size[1])
    $dw = $size[0] * $k; $dh = $size[1] * $k
    $fx = ($pos.X - ($bw - $dw) / 2) / $dw
    $fy = ($pos.Y - ($bh - $dh) / 2) / $dh
    if ($fx -lt 0 -or $fx -gt 1 -or $fy -lt 0 -or $fy -gt 1) { Say "That's outside the game picture. Click inside it, or press Esc."; return }
    $w.ClickX = [Math]::Round($fx, 3); $w.ClickY = [Math]::Round($fy, 3)
    if ($w.Nick) { $script:State.clickSpots[$w.Nick.ToLower()] = "$($w.ClickX),$($w.ClickY)"; Save-Settings }
    $script:SessionDirty = $true
    Stop-PickSpot
    Update-TileInfo $w
    if (@($script:State.afkActions) -notcontains "click") {
        Say "Click spot saved for $(Label-Of $w). Tick 'Click a spot' in Anti-AFK to use it."
    } else { Say "Click spot saved for $(Label-Of $w)." }
}

function Reset-Countdown {
    $s = $script:State.afkMinutes * 60
    if ($script:State.afkJitter) { $s += $script:Rng.Next(-30, 31) }
    $script:SecondsLeft = [Math]::Max(30, $s)
    $script:Waiting = $false
    Update-AfkUi
}

function Update-AfkUi {
    $clock = "{0}:{1:00}" -f [Math]::Floor($script:SecondsLeft / 60), ($script:SecondsLeft % 60)
    if ($script:AfkOn) {
        $ui.AfkToggle.Content = "Anti-AFK is ON  (click to turn off)"
        $ui.AfkToggle.Background = Brush "SuccessStrong"
        $names = (@($script:State.afkActions) | ForEach-Object { $AfkActionNames[$_] }) -join ", "
        if ($script:Waiting) {
            $ui.AfkStatus.Text = "Ready to $names. " + $(if ($script:State.afkMode -eq "hidden" -and @($script:State.afkActions) -notcontains "click") { "Waiting for a short pause in your typing..." } else { "Waiting until you're away from the PC for 10 seconds..." })
        }
        else { $ui.AfkStatus.Text = "Next $names in $clock" }
        $ui.AfkPillDot.Fill = Brush "Success"
        $ui.AfkPillText.Text = $(if ($script:Waiting) { "Anti-AFK waiting for you to step away" } else { "Anti-AFK on  -  next in $clock" })
    } else {
        $ui.AfkToggle.Content = "Anti-AFK is OFF  (click to turn on)"
        $ui.AfkToggle.Background = Brush "Raised"
        $ui.AfkStatus.Text = "Roblox kicks idle players after about 20 minutes. Turn this on to stay in."
        $ui.AfkPillDot.Fill = Brush "Off"
        $ui.AfkPillText.Text = "Anti-AFK off"
    }
    if ($TrayAfkItem) { $TrayAfkItem.Text = $(if ($script:AfkOn) { "Turn anti-AFK OFF" } else { "Turn anti-AFK ON" }) }
}

function Set-Afk([bool]$on) {
    $script:AfkOn = $on
    $script:State.afkOn = $on; Save-Settings
    Reset-Countdown
    Say $(if ($on) { "Anti-AFK turned ON." } else { "Anti-AFK turned OFF." })
    Show-MascotMoment $(if ($on) { "Happy" } else { "Default" }) $(if ($on) { "Anti-AFK is on." } else { "Anti-AFK is off." }) 3
}

# ============================================================ NEW FEATURES ==
# ----- uptime -----
function Roll-StatsDay {
    $today = Get-Date -Format "yyyy-MM-dd"
    if ($script:State.statsDate -ne $today) {
        $script:State.statsDate = $today
        $script:State.statsSecs = @{}
        foreach ($w in $script:Wins) { $w.Since = [DateTime]::Now }
    }
}
function Add-Uptime([string]$nick, $since) {
    if (-not $nick -or -not $since) { return }
    Roll-StatsDay
    $k = $nick.ToLower()
    $add = ([DateTime]::Now - $since).TotalSeconds
    if ($add -lt 0) { $add = 0 }
    $script:State.statsSecs[$k] = [double]$script:State.statsSecs[$k] + $add
    Save-Settings
}
function Get-TodaySecs([string]$nick) {
    Roll-StatsDay
    $k = $nick.ToLower()
    $t = [double]$script:State.statsSecs[$k]
    $w = Get-WindowOf $nick
    if ($w -and $w.Since) { $t += ([DateTime]::Now - $w.Since).TotalSeconds }
    return $t
}
function Format-Dur([double]$secs) {
    if ($secs -lt 60) { return "" }
    $m = [int][Math]::Floor($secs / 60)
    if ($m -lt 60) { return "${m}m" }
    return ("{0}h {1:00}m" -f [Math]::Floor($m / 60), ($m % 60))
}
function Update-StatusTexts {
    # Refreshes each account's status line and dot, and each screen's info line.
    foreach ($k in @($script:SubTexts.Keys)) {
        $e = $script:SubTexts[$k]
        $i = Get-AccStatusInfo $e.Acc
        $e.Tb.Text = $i.Text; $e.Tb.Foreground = Brush $i.Color
        if ($e.Dot) { $e.Dot.Fill = Brush $i.Color; $e.Dot.ToolTip = $i.Text }
    }
    foreach ($w in $script:Wins) { Update-TileInfo $w }
    if ($ui.TabGroups.IsSelected) { Render-GroupsTab }
}
function Update-LiveTexts {
    Update-StatusTexts
    $lines = @()
    foreach ($a in $script:State.accounts) {
        $d = Format-Dur (Get-TodaySecs $a.nick)
        $lines += ("{0,-18} {1}" -f $a.nick, $(if ($d) { $d } else { "-" }))
    }
    $ui.StatsText.Text = $(if ($lines.Count) { $lines -join "`n" } else { "No accounts yet." })
}

# ----- Discord webhook -----
function Test-HookUrl([string]$u) { return ($u -match '^https://(ptb\.|canary\.)?(discord|discordapp)\.com/api/webhooks/\d+/[\w-]+') }
function Send-Webhook([string]$text) {
    $u = $script:State.webhook
    if (-not (Test-HookUrl $u)) { return $false }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = @{ username = "BloxKit"; content = $text } | ConvertTo-Json
        Invoke-RestMethod -Uri $u -Method Post -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 6 | Out-Null
        return $true
    } catch {
        Say "Couldn't send the Discord alert. Check the webhook link in Settings."
        return $false
    }
}

# ----- 'Disconnected' box check -----
function Check-Disconnects {
    if (-not $script:State.discCheck) { return }
    $fg = [RbxCore]::GetForegroundWindow()
    foreach ($w in @($script:Wins)) {
        if ($w.LogPath) { continue }   # Roblox's log already tells us (see Watch-Logs)
        if ($w.Handle -eq $fg -or $w.Handle -eq $script:Playing) { $w.DiscHits = 0; continue }
        $score = [RbxCore]::DialogScore($w.Handle)
        if ($score -lt 0) { continue }
        if ($score -ge 0.6) { $w.DiscHits++ } else {
            if ($w.DiscFlag) { $w.DiscFlag = $false; Update-TileInfo $w }
            $w.DiscHits = 0
        }
        if ($w.DiscHits -ge 2 -and -not $w.DiscFlag) {
            $w.DiscFlag = $true
            Update-TileInfo $w
            Raise-Alert $(if ($w.Nick) { $w.Nick } else { Label-Of $w }) "disc"
        }
    }
}

# ----- Roblox log watcher: the exact server, and real disconnect reasons -----
# Each Roblox window writes its own log in %LOCALAPPDATA%\Roblox\logs. The file name has no
# process id, but every line carries the id of the thread that wrote it, so a log belongs to
# the window whose process owns those threads.
$RobloxLogDir = Join-Path $env:LOCALAPPDATA "Roblox\logs"
$script:LastServer = @{}   # nick (lower case) -> @{ Place; Job }, kept after the window closes
$LogLineRx = '^\d{4}-\d\d-\d\dT[\d:.]+Z,[\d.]+,([0-9a-f]+),'

function Open-LogStream([string]$path) {
    New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
}

function Find-LogFor($w) {
    try { $proc = Get-Process -Id ([RbxCore]::PidOf($w.Handle)) -ErrorAction Stop; $started = $proc.StartTime } catch { return "" }
    $threads = @($proc.Threads | ForEach-Object { $_.Id })
    $claimed = @($script:Wins | Where-Object { $_.LogPath } | ForEach-Object { $_.LogPath })
    $best = ""; $bestN = 2   # need at least 3 matching threads
    foreach ($f in @(Get-ChildItem $RobloxLogDir -Filter "*_Player_*_last.log" -ErrorAction SilentlyContinue)) {
        if ($f.Name -match 'CrashHandler' -or $f.LastWriteTime -lt $started.AddSeconds(-10) -or $claimed -contains $f.FullName) { continue }
        $ids = New-Object System.Collections.Generic.HashSet[int]
        try {
            $fs = Open-LogStream $f.FullName
            $buf = New-Object byte[] ([int][Math]::Min(131072, $fs.Length))
            [void]$fs.Read($buf, 0, $buf.Length); $fs.Close()
            foreach ($m in [regex]::Matches([Text.Encoding]::UTF8.GetString($buf), "(?m)$LogLineRx")) { [void]$ids.Add([Convert]::ToInt32($m.Groups[1].Value, 16)) }
        } catch { continue }
        $n = @($threads | Where-Object { $ids.Contains($_) }).Count
        if ($n -gt $bestN) { $best = $f.FullName; $bestN = $n }
    }
    return $best
}

function Read-LogLines($w) {
    # New complete lines since the last read.
    try {
        $fs = Open-LogStream $w.LogPath
        if ($fs.Length -lt $w.LogPos) { $w.LogPos = 0 }
        $fs.Position = $w.LogPos
        $len = [int][Math]::Min(4MB, $fs.Length - $w.LogPos)
        $buf = New-Object byte[] $len
        $n = $fs.Read($buf, 0, $len); $fs.Close()
    } catch { return @() }
    if ($n -le 0) { return @() }
    $end = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
    if ($end -lt 0) { return @() }
    $w.LogPos += $end + 1
    return ([Text.Encoding]::UTF8.GetString($buf, 0, $end + 1) -split "`r?`n")
}

function Watch-Logs {
    # Reads each window's log for its status (always) and raises disconnect alerts
    # (only when "Watch for disconnects" is on).
    $haveLogs = Test-Path $RobloxLogDir
    $changed = $false
    $now = [DateTime]::Now
    foreach ($w in @($script:Wins)) {
        if (-not $w.LogPath) {
            if ($w.LogTries -ge 20) { continue }   # stop looking after about a minute
            $w.LogTries = $(if ($haveLogs) { $w.LogTries + 1 } else { 20 })
            if ($haveLogs) { $w.LogPath = Find-LogFor $w }
            if (-not $w.LogPath) { if ($w.LogTries -ge 20) { $changed = $true }; continue }   # gave up: status unknown
            if ($w.DiscFlag -and -not $w.DiscText) { $w.DiscFlag = $false }   # the log decides from now on
            $changed = $true
        }
        foreach ($line in (Read-LogLines $w)) {
            $e = Read-LogEvent $line
            if (-not $e) { continue }
            if ($e.Kind -eq "disc" -and $e.Code -eq "273") {
                # This account joined a server from another window (or device): this one is done.
                Close-ReplacedWindow $w "$(if ($w.Nick) { $w.Nick } else { 'that account' }) joined another server"
                $changed = $true; break
            }
            if (Update-Session $w.Sess $e $now) { $changed = $true }
            if ($e.Kind -eq "handoff" -and $w.ProcStart -and $e.At -ne [DateTime]::MinValue) {
                # Multi-window off: this window took over a launch we're waiting on. Roblox
                # signs it in as that launch's account, so it's that account's window now.
                $op = Select-LaunchForHandoff $w.ProcStart $e.At $script:Ops $script:State.launchTimeout
                if ($op) {
                    if ($w.Nick -and $w.Nick -ine $op.Acc.nick) {
                        Add-Uptime $w.Nick $w.Since
                        Say "Multi-window is off, so $($op.Acc.nick) took over $($w.Nick)'s Roblox window."
                    }
                    $op.Hwnd = $w.Handle.ToInt64()
                    Claim-Window $w.Handle $op
                    $changed = $true
                }
            }
            if ($e.Kind -eq "join") {
                if ($w.Nick) {
                    $script:LastServer[$w.Nick.ToLower()] = @{ Place = $e.Place; Job = $e.Job }
                    if ((Get-ServerCheck $script:Planned[$w.Nick.ToLower()] $e.Job) -eq "elsewhere") { Say "$($w.Nick) joined a different server than planned (that one was probably full)." }
                }
                if ($w.DiscFlag) { $w.DiscFlag = $false; $w.DiscText = "" }
            }
        }
        # Wait a few seconds before alerting: a teleport also disconnects, then joins again.
        if ($w.Sess.State -eq "disconnected" -and -not $w.DiscFlag -and ($now - $w.Sess.ChangedAt).TotalSeconds -ge 8) {
            $w.DiscFlag = $true; $w.DiscText = $w.Sess.Reason; $changed = $true
            if ($script:State.discCheck) { Raise-Alert $(if ($w.Nick) { $w.Nick } else { Label-Of $w }) "disc" $w.Sess.Reason }
        }
    }
    if ($changed) { Update-StatusTexts }
}

# ----- efficiency mode for alts -----
# Every Roblox window except the main and the one you're playing in runs in Windows'
# efficiency mode. Re-applied every 10 seconds in case Roblox changes its own priority.
function Apply-Efficiency([switch]$Force, [switch]$AllOff) {
    $main = Get-Main
    foreach ($w in @($script:Wins)) {
        $isMain = $main -and $w.Nick -and ($w.Nick -ieq $main.nick)
        $want = (-not $AllOff) -and $script:State.ecoAlts -and -not $isMain -and $w.Handle -ne $script:Playing
        if ($want -eq $w.Eco -and -not ($Force -and $want)) { continue }
        if ($want -and $w.EcoFailed) { continue }
        if ([RbxCore]::SetEfficiency([RbxCore]::PidOf($w.Handle), $want)) {
            if ($w.Eco -ne $want) { $w.Eco = $want; Update-TileInfo $w }
        } elseif ($want) {
            $w.EcoFailed = $true
            Say "Couldn't turn on efficiency mode for $(Label-Of $w). Windows didn't allow it."
        }
    }
}

# ----- low-power mode -----
function Apply-LowPower {
    $main = Get-Main
    foreach ($w in $script:Wins) {
        if ($w.Handle -eq $script:Playing) { continue }
        $isMain = $main -and $w.Nick -and ($w.Nick -ieq $main.nick)
        if ($script:State.lowPower -and -not $isMain) { [RbxCore]::SizeWindow($w.Handle, 640, 360) }
        else { [RbxCore]::SizeWindow($w.Handle, 1280, 720) }
    }
    $win.Dispatcher.BeginInvoke([Action]{ Place-Screens }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

# ----- scheduled start + open with Windows -----
function Test-TimeText([string]$t) { return ($t -match '^([01]?\d|2[0-3]):[0-5]\d$') }
function Update-SchedUi {
    $l = $script:State.schedLink
    if ($l) {
        $fav = @($script:State.favorites | Where-Object { $_.url -eq $l }) | Select-Object -First 1
        $ui.SchedLinkText.Text = "Game: " + $(if ($fav) { $fav.name } else { $l })
    } else { $ui.SchedLinkText.Text = "Game: not set yet. Paste a link in the Accounts tab, then click the button below." }
    if ($script:State.schedOn -and $l -and (Test-TimeText $script:State.schedTime)) {
        $ui.SchedStatus.Text = "On. Next start: $($script:State.schedTime)" + $(if ($script:State.schedLastRun -eq (Get-Date -Format "yyyy-MM-dd")) { " tomorrow." } else { "." })
        $ui.SchedStatus.Foreground = Brush "SuccessInk"
    } elseif ($script:State.schedOn) {
        $ui.SchedStatus.Text = "Needs a game link and a time like 08:00."; $ui.SchedStatus.Foreground = Brush "CautionInk"
    } else { $ui.SchedStatus.Text = "Off."; $ui.SchedStatus.Foreground = Brush "Muted" }
}
function Check-Schedule {
    if (-not $script:State.schedOn -or -not $script:State.schedLink) { return }
    $t = $script:State.schedTime
    if (-not (Test-TimeText $t)) { return }
    $today = Get-Date -Format "yyyy-MM-dd"
    if ($script:State.schedLastRun -eq $today) { return }
    $parts = $t.Split(":")
    $when = (Get-Date).Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    $now = Get-Date
    if ($now -ge $when -and $now -lt $when.AddMinutes(10)) {
        $script:State.schedLastRun = $today; Save-Settings
        if (Test-PlanActive) {
            # Never two schedules on the same accounts at once.
            Say "Scheduled start skipped today: the group schedule is running."
            Add-PlanHistory "Daily 'Scheduled start' was skipped because this schedule was running."
            return
        }
        Say "Scheduled start: starting everything now."
        Send-Webhook "BloxKit: scheduled start is running now."
        if ($script:QBusy) { return }
        Start-Everything -LinkOverride $script:State.schedLink -Silent
        Update-SchedUi
    }
}
# Windows' Startup folder ("Open BloxKit when Windows starts"). Some PCs don't have one (cleanup
# tools delete it), and then .NET gives an empty path, so ask for it anyway; it's made when needed.
$StartupDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup, [Environment+SpecialFolderOption]::DoNotVerify)
if (-not $StartupDir) { $StartupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup" }
$StartupLnk = Join-Path $StartupDir "BloxKit.lnk"
function Get-AppCommand {
    # How to start this app again: BloxKit.exe when it was opened from there, otherwise PowerShell (like the .bat).
    if ($env:RML_LAUNCHER -and (Test-Path -LiteralPath $env:RML_LAUNCHER)) { return @{ File = $env:RML_LAUNCHER; Args = "" } }
    return @{ File = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
              Args = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`"" }
}
function Set-RunAtStartup([bool]$on, [switch]$Quiet) {
    try {
        if ($on) {
            $cmd = Get-AppCommand
            if (-not (Test-Path -LiteralPath $StartupDir)) { New-Item -ItemType Directory -Path $StartupDir -Force | Out-Null }
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($StartupLnk)
            $lnk.TargetPath = $cmd.File
            $lnk.Arguments = ($cmd.Args + " -Minimized").Trim()
            $lnk.WorkingDirectory = $PSScriptRoot
            $lnk.Description = "BloxKit"
            if (Test-Path -LiteralPath $IconFile) { $lnk.IconLocation = $IconFile }
            $lnk.Save()
            if (-not $Quiet) { Say "BloxKit will open (in the tray) when Windows starts." }
        } elseif (Test-Path $StartupLnk) {
            Remove-Item $StartupLnk -Force
            Say "BloxKit won't open with Windows anymore."
        }
    } catch { Say "Couldn't change the Windows startup setting." }
}

# ----- backup -----
function Get-ProfileNames {
    # Chrome profile folder -> the name Chrome shows for it.
    $t = @{}
    foreach ($p in @(Get-ChromeProfiles)) { $t[$p.Dir] = "" + $p.Name }
    return $t
}
function Export-Backup {
    Save-Settings
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = "BloxKit-backup-" + (Get-Date -Format "yyyy-MM-dd") + ".json"
    $dlg.Filter = "Backup file (*.json)|*.json"
    if (-not $dlg.ShowDialog($win)) { return }
    try {
        $json = New-BackupObject $script:State (Get-ProfileNames) | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($dlg.FileName, $json, (New-Object Text.UTF8Encoding $true))
        Say "Backup saved: $($dlg.FileName)  (your Discord webhook link isn't in it)"
    } catch { Say "Couldn't save the backup: $($_.Exception.Message)" }
}
function Import-Backup {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "Backup file (*.json)|*.json"
    if (-not $dlg.ShowDialog($win)) { return }
    $r = Read-BackupFile $dlg.FileName $script:State $ChromeData (Get-ProfileNames)
    if (-not $r.Ok) { [BkBox]::Show($r.Error, "Load backup", "OK", "Warning") | Out-Null; return }
    $msg = "Load this backup with $(@($r.State.accounts).Count) account(s)?`n`nIt replaces your current accounts and settings. Your current ones are saved first as a copy in the settings folder. The app will restart."
    if (@($r.NeedSignIn).Count) {
        $msg += "`n`nThese accounts don't have their Chrome profile on this PC, so they'll need to sign in once: " + (@($r.NeedSignIn) -join ", ") + ".`nThe app will walk you through it after the restart."
    }
    if (@($r.Warnings).Count) { $msg += "`n`nPlease check:`n- " + (@($r.Warnings) -join "`n- ") }
    $ans = [BkBox]::Show($msg, "Load backup", "YesNo", "Question")
    if ($ans -ne "Yes") { return }
    if (Test-Path -LiteralPath $SettingsFile) {
        $keep = Join-Path $AppDir ("settings.before-import-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")
        try { Copy-Item -LiteralPath $SettingsFile $keep -ErrorAction Stop }
        catch { [BkBox]::Show("Couldn't keep a copy of your current settings, so nothing was changed.`n`n$($_.Exception.Message)", "Load backup", "OK", "Warning") | Out-Null; return }
    }
    $err = Write-SettingsFile $r.State $SettingsFile
    if ($err) { [BkBox]::Show("Couldn't load the backup, nothing was changed.`n`n$err", "Load backup", "OK", "Warning") | Out-Null; return }
    $script:SkipSave = $true
    Release-Instance   # let the restarted copy start
    $cmd = Get-AppCommand
    if ($cmd.Args) { Start-Process $cmd.File -ArgumentList $cmd.Args } else { Start-Process $cmd.File }
    $script:ReallyExit = $true
    $win.Close()
}

# =============================================================== STATUS ==
function Update-Status {
    # Roblox's "only one window" lock can only be taken while no Roblox is running.
    # Take it as soon as that happens, instead of only when the app starts.
    $running = Get-RobloxCount
    if (-not $NoRoblox -and $script:Locks.Count -eq 0 -and $running -eq 0 -and (Grab-Locks)) { Say "Multi-window is ON now (no Roblox was running)." }
    if ($script:Locks.Count -gt 0) {
        $ui.StatusPill.Background = Brush "SuccessBg"
        $ui.StatusText.Text = "Multi-window ON"; $ui.StatusText.Foreground = Brush "SuccessInk"; $ui.StatusDot.Fill = Brush "SuccessInk"
        $ui.StatusPill.ToolTip = "You can open as many Roblox windows as you want."
        $ui.FixBtn.Visibility = "Collapsed"
    } else {
        $ui.StatusPill.Background = Brush "CautionBg"
        $ui.StatusText.Text = "Multi-window OFF"; $ui.StatusText.Foreground = Brush "CautionInk"; $ui.StatusDot.Fill = Brush "CautionInk"
        $hidden = $running - $script:Wins.Count
        $ui.StatusPill.ToolTip = $(if ($running -gt 0) {
            "$running Roblox program(s) were already running, so new accounts take over the open window instead of getting their own. " +
            $(if ($hidden -gt 0) { "$hidden of them have no window (often left over from a crash). " } else { "" }) +
            "Close all Roblox (or click 'Close Roblox and turn on'); multi-window turns on by itself once none are left."
        } else { "Something is blocking it. Restart your PC, then open this app first." })
        $ui.FixBtn.Visibility = "Visible"
    }
}

# ================================================================= TRAY ==
$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = $(try { New-Object System.Drawing.Icon($IconFile, [System.Windows.Forms.SystemInformation]::SmallIconSize) } catch { ([type]"System.Drawing.SystemIcons")::Application })
$Tray.Text = "BloxKit"
$TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$TrayOpen = $TrayMenu.Items.Add("Open BloxKit")
$TrayAfkItem = $TrayMenu.Items.Add("Turn anti-AFK ON")
$TrayJump = $TrayMenu.Items.Add("Anti-AFK: do it now")
$TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$TrayExit = $TrayMenu.Items.Add("Exit")
$TrayMenu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object BkMenuColors))
foreach ($it in $TrayMenu.Items) { $it.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($BkTokens.Cloud) }
$Tray.ContextMenuStrip = $TrayMenu
$TrayOpen.Add_Click({ Show-App })
$TrayAfkItem.Add_Click({ Set-Afk (-not $script:AfkOn) })
$TrayJump.Add_Click({ Do-Jumps -Manual | Out-Null; Reset-Countdown })
$TrayExit.Add_Click({ $script:ReallyExit = $true; $win.Close() })
$Tray.Add_DoubleClick({ Show-App })
$Tray.Visible = $true

# =============================================================== WIRING ==
# Accounts tab
$ui.AddBtn.Add_Click({ Show-AccountDialog $null })
$ui.TickAltsBtn.Add_Click({ foreach ($a in $script:State.accounts) { $a.checked = -not $a.isMain }; Save-Settings; Render-Accounts })
$ui.UntickBtn.Add_Click({ foreach ($a in $script:State.accounts) { $a.checked = $false }; Save-Settings; Render-Accounts })
$ui.LinkBox.Add_TextChanged({ Update-LinkStatus })
$ui.PasteBtn.Add_Click({ try { $ui.LinkBox.Text = [System.Windows.Clipboard]::GetText().Trim() } catch {} })
$ui.ClearBtn.Add_Click({ $ui.LinkBox.Text = ""; $ui.LinkBox.Focus() | Out-Null })
$ui.MainServerBtn.Add_Click({
    $main = Get-Main
    if ($main) { $ui.LinkBox.Text = $main.profileUrl; Say "Make sure $($main.nick) is already in a game, then open the alts." }
})
$ui.AutoJoinBox.Add_Click({
    # All on <-> all off. A dash means some accounts have it on (set per account in Settings > Chrome setup).
    Set-AutoJoinAll $script:State ((Get-AutoJoinSummary $script:State) -ne "all"); Save-Settings
    Update-AutoJoinBox; Update-LinkStatus; Render-Accounts; Render-ChromeSetup
})
$ui.OpenTickedBtn.Add_Click({ Open-Accounts @($script:State.accounts | Where-Object { $_.checked -and -not (Get-WindowOf $_.nick) }) })
$ui.OpenAltsBtn.Add_Click({ Open-Accounts @($script:State.accounts | Where-Object { -not $_.isMain -and -not (Get-WindowOf $_.nick) }) })
$ui.StartAllBtn.Add_Click({ Start-Everything })
$ui.CancelBtn.Add_Click({ if ($script:QBusy) { Cancel-Queue } else { $ui.ProgressCard.Visibility = "Collapsed" } })
$ui.RetryBtn.Add_Click({
    $items = @($script:QFailed | ForEach-Object { [pscustomobject]@{ Acc = $_.Acc; Url = $_.Url; Kind = $_.Kind; Job = $_.Job; Place = $_.Place } })
    $script:QFailed.Clear(); $ui.RetryBtn.Visibility = "Collapsed"
    Queue-Items $items
})

# Favorites
$ui.FavBox.Add_SelectionChanged({
    if ($script:FillingFav) { return }
    $it = $ui.FavBox.SelectedItem
    $ui.DelFavBtn.IsEnabled = [bool]$it
    if ($it) { $ui.LinkBox.Text = $it.Tag.url; Say "Using saved link: $($it.Tag.name)" }
})
$ui.SaveFavBtn.Add_Click({
    $info = Get-LinkInfo $ui.LinkBox.Text
    $name = Ask-Text "Save link" "Give this link a name (like 'Blox Fruits' or 'Our private server'):" $info.Label
    if (-not $name) { return }
    $script:State.favorites = @($script:State.favorites | Where-Object { $_.name -ine $name }) + [pscustomobject]@{ name = $name; url = $info.Url }
    Save-Settings; Render-Favorites; Say "Saved '$name'."
})
$ui.DelFavBtn.Add_Click({
    $it = $ui.FavBox.SelectedItem; if (-not $it) { return }
    $script:State.favorites = @($script:State.favorites | Where-Object { -not (Same $_ $it.Tag) })
    Save-Settings; Render-Favorites; Say "Deleted saved link '$($it.Tag.name)'."
})

# Groups
$ui.GroupBox.Add_SelectionChanged({
    if ($script:FillingGroup) { return }
    $it = $ui.GroupBox.SelectedItem
    $ui.DelGroupBtn.IsEnabled = [bool]$it
    if (-not $it) { return }
    $nicks = @($it.Tag.nicks)
    foreach ($a in $script:State.accounts) { $a.checked = [bool]($nicks | Where-Object { $_ -ieq $a.nick }) }
    Save-Settings; Render-Accounts
    Say "Ticked group '$($it.Tag.name)'."
})
$ui.SaveGroupBtn.Add_Click({
    $nicks = @($script:State.accounts | Where-Object { $_.checked } | ForEach-Object { $_.nick })
    $name = Ask-Text "Save group" "Name this group of $($nicks.Count) account(s) (like 'Farm team'):" ""
    if (-not $name) { return }
    $same = @($script:State.groups | Where-Object { $_.name -ieq $name.Trim() }) | Select-Object -First 1
    if ($same) { Set-GroupMembers $script:State $same $nicks; $script:SelGroupId = $same.id }   # same name: update it, keep its id
    else { $script:SelGroupId = (New-Group $script:State $name $nicks).Group.id }
    Save-Settings; Render-Groups; Say "Saved group '$($name.Trim())'."
})
$ui.DelGroupBtn.Add_Click({
    $it = $ui.GroupBox.SelectedItem; if (-not $it) { return }
    Confirm-DeleteGroup $it.Tag
})

# Groups tab
function Ask-GroupName([string]$title, [string]$default, $except) {
    # Asks until the name is free (or Cancel). Returns "" on Cancel.
    $name = $default
    while ($true) {
        $name = Ask-Text $title "Group name (like 'Farm team'):" $name
        if (-not $name) { return "" }
        $err = Test-GroupName $script:State $name $except
        if (-not $err) { return $name.Trim() }
        [BkBox]::Show($err, $title, "OK", "Information") | Out-Null
    }
}
$ui.GNewBtn.Add_Click({
    $name = Ask-GroupName "New group" "" $null
    if (-not $name) { return }
    $g = (New-Group $script:State $name @()).Group
    $script:SelGroupId = $g.id
    Save-Settings; Render-Groups
    Show-MembersDialog $g
})
$ui.GRenameBtn.Add_Click({
    $g = Get-SelectedGroup; if (-not $g) { return }
    $name = Ask-GroupName "Rename group" $g.name $g
    if (-not $name -or $name -ceq $g.name) { return }
    $old = $g.name
    Rename-Group $script:State $g $name | Out-Null
    Save-Settings; Render-Groups; Say "Renamed '$old' to '$name'."
})
$ui.GCopyBtn.Add_Click({
    $g = Get-SelectedGroup; if (-not $g) { return }
    $c = Copy-Group $script:State $g
    $script:SelGroupId = $c.id
    Save-Settings; Render-Groups; Say "Made '$($c.name)'. Rename it or change its members."
})
$ui.GDeleteBtn.Add_Click({ $g = Get-SelectedGroup; if ($g) { Confirm-DeleteGroup $g } })
$ui.GEditBtn.Add_Click({ $g = Get-SelectedGroup; if ($g) { Show-MembersDialog $g } })
$ui.GUpBtn.Add_Click({ $g = Get-SelectedGroup; if ($g) { Move-Group $script:State $g -1; Save-Settings; Render-Groups } })
$ui.GDownBtn.Add_Click({ $g = Get-SelectedGroup; if ($g) { Move-Group $script:State $g 1; Save-Settings; Render-Groups } })
$ui.GOpenBtn.Add_Click({
    $g = Get-SelectedGroup; if (-not $g) { return }
    Open-Accounts @($script:State.accounts | Where-Object { @($g.nicks) -icontains $_.nick -and -not (Get-WindowOf $_.nick) })
    Render-GroupsTab
})
$ui.GTickBtn.Add_Click({
    $g = Get-SelectedGroup; if (-not $g) { return }
    foreach ($a in $script:State.accounts) { $a.checked = @($g.nicks) -icontains $a.nick }
    Save-Settings; Render-Accounts
    Say "Ticked the $(@($g.nicks).Count) account(s) in '$($g.name)' on the Accounts tab."
})
$ui.GroupsGrid.Add_SizeChanged({ Update-GroupsLayout })

# Schedule tab
function Fill-PlanCombo($box, $items, $current, [scriptblock]$onPick) {
    # items: @(value, label) pairs. Shows $current selected; calls $onPick with the new value.
    foreach ($o in $items) {
        $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $o[1]; $it.Tag = $o[0]
        $box.Items.Add($it) | Out-Null
        if ("" + $o[0] -eq "" + $current) { $box.SelectedItem = $it }
    }
    if (-not $box.SelectedItem) { $box.SelectedIndex = 0 }
    $box.Tag = $onPick
    $box.Add_SelectionChanged({ param($s,$e) if ($s.SelectedItem) { & $s.Tag $s.SelectedItem.Tag; Save-Settings } })
}
$Plan = $State.plan
Fill-PlanCombo $ui.SWhenBox @(@("close", "Close its Roblox windows"), @("keep", "Leave them open")) $Plan.whenTimeUp { param($v) $script:State.plan.whenTimeUp = $v }
Fill-PlanCombo $ui.SThenBox @(@("next", "Then start the next group"), @("wait", "Then wait for me to click Next"), @("stop", "Then stop the schedule")) $Plan.then { param($v) $script:State.plan.then = $v }
Fill-PlanCombo $ui.SBreakBox @(@(0, "None"), @(1, "1 min"), @(2, "2 min"), @(5, "5 min"), @(10, "10 min"), @(15, "15 min"), @(30, "30 min"), @(60, "60 min")) $Plan.cooldownMin { param($v) $script:State.plan.cooldownMin = [int]$v }
Fill-PlanCombo $ui.SMaxBox @(@(0, "No limit"), @(60, "1 hour"), @(120, "2 hours"), @(180, "3 hours"), @(240, "4 hours"), @(360, "6 hours"), @(480, "8 hours"), @(720, "12 hours"), @(1440, "24 hours")) $Plan.maxTotalMin { param($v) $script:State.plan.maxTotalMin = [int]$v }
Fill-PlanCombo $ui.SRetryBox @(@(0, "No"), @(1, "Once"), @(2, "2 times"), @(3, "3 times")) $Plan.retries { param($v) $script:State.plan.retries = [int]$v }
Fill-PlanCombo $ui.SFailBox @(@("skip", "Then go on without it"), @("stop", "Then stop the schedule")) $Plan.onFailure { param($v) $script:State.plan.onFailure = $v }
$ui.SLoopBox.IsChecked = $Plan.loop
$ui.SLoopBox.Add_Click({ $script:State.plan.loop = [bool]$ui.SLoopBox.IsChecked; Save-Settings; Update-ScheduleLive })
$ui.SFollowBox.IsChecked = $Plan.followMain
$ui.SFollowBox.Add_Click({ $script:State.plan.followMain = [bool]$ui.SFollowBox.IsChecked; Save-Settings })
$ui.SAddBtn.Add_Click({
    $it = $ui.SAddGroup.SelectedItem; if (-not $it) { return }
    $script:State.plan.steps = @($script:State.plan.steps) + [pscustomobject]@{ groupId = $it.Tag; minutes = 60 }
    Save-Settings; Render-ScheduleTab
})
$ui.SStartBtn.Add_Click({ Start-Plan })
$ui.SPauseBtn.Add_Click({ if (Test-PlanCan $script:Run "resume" $script:State.plan) { Invoke-Plan "resume" } else { Invoke-Plan "pause" } })
$ui.SNextBtn.Add_Click({ Invoke-Plan "next" })
$ui.SStopBtn.Add_Click({
    $r = [BkBox]::Show("Stop the schedule?`n`nYes = stop, and close the schedule's Roblox windows`nNo = stop, but leave them open`nCancel = keep going", "Stop schedule", "YesNoCancel", "Question")
    if ($r -eq "Cancel") { return }
    Invoke-Plan "stop" ($r -eq "Yes")
})
$ui.SchedGrid.Add_SizeChanged({ Update-ScheduleLayout })

# Settings > Performance
foreach ($k in $PerfPresets.Keys) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $PerfPresets[$k].Name; $it.Tag = $k; $ui.PerfPresetBox.Items.Add($it) | Out-Null }
$it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = "Custom"; $it.Tag = "custom"; $ui.PerfPresetBox.Items.Add($it) | Out-Null
$ui.PerfPresetBox.Add_SelectionChanged({ if (-not $script:FillingPerf -and $ui.PerfPresetBox.SelectedItem -and $ui.PerfPresetBox.SelectedItem.Tag -ne "custom") { Set-PerfPreset $ui.PerfPresetBox.SelectedItem.Tag } })
foreach ($cnt in @(0, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 20)) {
    $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $(if ($cnt -eq 0) { "No limit" } else { "$cnt" }); $it.Tag = $cnt; $ui.MaxClientsBox.Items.Add($it) | Out-Null
}
Select-ComboTag $ui.MaxClientsBox $State.maxClients
if (-not $ui.MaxClientsBox.SelectedItem) { $ui.MaxClientsBox.SelectedIndex = 0 }
$ui.MaxClientsBox.Add_SelectionChanged({ $script:State.maxClients = [int]$ui.MaxClientsBox.SelectedItem.Tag; Save-Settings; Say $(if ($script:State.maxClients) { "At most $($script:State.maxClients) Roblox windows will be open at once." } else { "No limit on Roblox windows." }) })
foreach ($lvl in 1..10) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $(switch ($lvl) { 1 { "1 (lowest)" } 10 { "10 (highest)" } default { "$lvl" } }); $it.Tag = $lvl; $ui.RbxQualityBox.Items.Add($it) | Out-Null }   # not $q: names ignore case, $Q is the launch queue
foreach ($o in @(@(30, "30 FPS"), @(60, "60 FPS"), @(144, "144 FPS"), @(240, "240 FPS"), @(-1, "Roblox default"))) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $o[1]; $it.Tag = $o[0]; $ui.RbxFpsBox.Items.Add($it) | Out-Null }
$g0 = Get-GraphicsPicks   # what was picked last time, or Roblox's own
Select-ComboTag $ui.RbxQualityBox $(if ($g0.Quality -ge 1) { $g0.Quality } else { 4 })
Select-ComboTag $ui.RbxFpsBox (Get-FpsChoice $g0.FpsCap)
$ui.RbxQualityBox.Add_SelectionChanged({ Save-GraphicsPicks })
$ui.RbxFpsBox.Add_SelectionChanged({ Save-GraphicsPicks })
$ui.RbxApplyBtn.Add_Click({ Save-RobloxGraphicsChoice })
$ui.RbxAutoBox.IsChecked = $State.rbxAuto
$ui.RbxAutoBox.Add_Click({ $script:State.rbxAuto = [bool]$ui.RbxAutoBox.IsChecked; $script:RbxSyncOff = $false; Save-Settings; Update-PerfUi; Sync-RobloxGraphics })
$ui.RbxUndoBtn.Add_Click({ Undo-RobloxGraphics })


# Server choice (game links)
foreach ($o in @(@(0, "Roblox picks (as before)"), @(1, "Spread out: 1 per server"), @(2, "Spread out: up to 2 per server"), @(3, "Spread out: up to 3 per server"), @(4, "Spread out: up to 4 per server"), @(5, "Spread out: up to 5 per server"))) {
    $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $o[1]; $it.Tag = $o[0]
    $ui.SpreadBox.Items.Add($it) | Out-Null
    if ($o[0] -eq $State.spread) { $ui.SpreadBox.SelectedItem = $it }
}
if (-not $ui.SpreadBox.SelectedItem) { $ui.SpreadBox.SelectedIndex = 0 }
$ui.SpreadBox.Add_SelectionChanged({ $script:State.spread = [int]$ui.SpreadBox.SelectedItem.Tag; Save-Settings; Update-LinkStatus })

# Settings > Chrome setup
$ui.CsAllOnBtn.Add_Click({ Set-AutoJoinAll $script:State $true; Save-Settings; Update-AutoJoinBox; Update-LinkStatus; Render-Accounts; Render-ChromeSetup; Say "Auto-click is on for every account." })
$ui.CsAllOffBtn.Add_Click({ Set-AutoJoinAll $script:State $false; Save-Settings; Update-AutoJoinBox; Update-LinkStatus; Render-Accounts; Render-ChromeSetup; Say "Auto-click is off for every account." })
$ui.CsRecheckBtn.Add_Click({ $script:SetupCache = @{}; Render-ChromeSetup; Render-Accounts; Say "Checked every Chrome profile again." })

# Alert bar
$ui.AlertCloseBtn.Add_Click({ $ui.AlertBar.Visibility = "Collapsed" })
$ui.AlertRejoinBtn.Add_Click({
    $ui.AlertBar.Visibility = "Collapsed"
    if ($script:AlertNick) { Rejoin-Account (Find-Account $script:AlertNick) }
})

# Status
$ui.FixBtn.Add_Click({
    if ($NoRoblox) { Say "(test mode) Roblox isn't closed."; return }
    $r = [BkBox]::Show("This closes every Roblox window that's open now. Continue?", "Close Roblox", "YesNo", "Question")
    if ($r -ne "Yes") { return }
    foreach ($w in $script:Wins) { [void]$script:ExpectedClose.Add($w.Handle.ToInt64()) }
    Get-Process -Name "RobloxPlayerBeta" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 1500
    if (Grab-Locks) { Say "Multi-window is ON now." } else { Say "Still blocked. Restart your PC, then open this app first." }
    Update-Status
})

# Live screens tab
foreach ($m in 1, 2, 3, 5, 10, 15) { $ui.MinutesBox.Items.Add($m) | Out-Null }
$ui.MinutesBox.SelectedItem = $(if (@(1,2,3,5,10,15) -contains $State.afkMinutes) { $State.afkMinutes } else { 5 })
$ui.ModeHidden.IsChecked = ($State.afkMode -eq "hidden")
$ui.ModeQuick.IsChecked = ($State.afkMode -ne "hidden")
$ui.SkipActiveBox.IsChecked = $State.afkSkipActive
$ui.JitterBox.IsChecked = $State.afkJitter
$ui.AfkToggle.Add_Click({ Set-Afk (-not $script:AfkOn) })
$ui.AfkPill.Add_Click({ Set-Afk (-not $script:AfkOn) })
# What anti-AFK does: one checkbox per action; at least one must stay ticked.
$ActBoxes = [ordered]@{ jump = $ui.ActJump; walk = $ui.ActWalk; zoom = $ui.ActZoom; click = $ui.ActClick }
foreach ($k in $ActBoxes.Keys) {
    $ActBoxes[$k].IsChecked = (@($State.afkActions) -contains $k)
    $ActBoxes[$k].Tag = $k
    $ActBoxes[$k].Add_Click({
        param($s,$e)
        $picked = @($ActBoxes.Keys | Where-Object { $ActBoxes[$_].IsChecked })
        if ($picked.Count -eq 0) { $s.IsChecked = $true; Say "Keep at least one anti-AFK action ticked."; return }
        $script:State.afkActions = $picked; Save-Settings
        if ($s.Tag -eq "click" -and $s.IsChecked) { Say "Tip: on each screen, use ... > Set click spot to choose where it clicks. Until then it clicks the middle." }
        foreach ($w in $script:Wins) { Update-TileInfo $w }
        Update-AfkUi
    })
}
$ui.JumpNowBtn.Add_Click({ Do-Jumps -Manual | Out-Null; Reset-Countdown })
$ui.MinutesBox.Add_SelectionChanged({ $script:State.afkMinutes = [int]$ui.MinutesBox.SelectedItem; Save-Settings; Reset-Countdown })
# Checked, not Click: saved however the choice changes (mouse, keyboard, or the anti-AFK test).
$ui.ModeHidden.Add_Checked({ if ($script:State.afkMode -ne "hidden") { $script:State.afkMode = "hidden"; Save-Settings } })
$ui.ModeQuick.Add_Checked({ if ($script:State.afkMode -ne "quick") { $script:State.afkMode = "quick"; Save-Settings } })
$ui.SkipActiveBox.Add_Click({ $script:State.afkSkipActive = [bool]$ui.SkipActiveBox.IsChecked; Save-Settings })
$ui.JitterBox.Add_Click({ $script:State.afkJitter = [bool]$ui.JitterBox.IsChecked; Save-Settings })
$ui.AfkAllBtn.Add_Click({ foreach ($w in $script:Wins) { Set-ScreenAfk $w $true }; Save-Settings; Build-Wall })
$ui.AfkNoneBtn.Add_Click({ foreach ($w in $script:Wins) { Set-ScreenAfk $w $false }; Save-Settings; Build-Wall })
$ui.MuteAltsBtn.Add_Click({
    foreach ($w in $script:Wins) {
        $acc = $(if ($w.Nick) { Find-Account $w.Nick } else { $null })
        if (-not ($acc -and $acc.isMain)) { Set-Mute $w $true -Quiet }
    }
    Say "Muted all alts. Only your main makes sound."
})
$ui.UnmuteAllBtn.Add_Click({ foreach ($w in $script:Wins) { Set-Mute $w $false -Quiet }; Say "Sound back on for all windows." })
$ui.CloseAllBtn.Add_Click({
    if ($script:Wins.Count -eq 0) { Say "No Roblox windows are open."; return }
    $r = [BkBox]::Show("Close ALL $($script:Wins.Count) Roblox windows?", "Close all", "YesNo", "Warning")
    if ($r -ne "Yes") { return }
    foreach ($w in @($script:Wins)) { Close-RobloxWindow $w -NoAsk }
})
$ui.Tabs.Add_SelectionChanged({
    param($s,$e)
    if ($e.OriginalSource -ne $ui.Tabs) { return }
    # A tab that fails to draw must never leave the window stuck between two tabs.
    try {
        Place-Screens
        if ($ui.TabGroups.IsSelected) { Render-GroupsTab }
        if ($ui.TabSchedule.IsSelected) { Render-ScheduleTab }
        if ($ui.TabSettings.IsSelected) { Render-ChromeSetup; Update-PerfUi }
        if ($ui.TabScreens.IsSelected) { Render-LoadMonitor }
    } catch { Say "Part of this tab couldn't be shown: $($_.Exception.Message)" }
})

# Settings tab
function Fill-Combo($box, $values, $current, [string]$suffix) {
    foreach ($v in $values) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = "$v$suffix"; $it.Tag = $v
        $box.Items.Add($it) | Out-Null
        if ($v -eq $current) { $box.SelectedItem = $it }
    }
    if (-not $box.SelectedItem) { $box.SelectedIndex = 0 }
}
Fill-Combo $ui.SettleBox @(3, 5, 8, 12, 20, 30) $State.launchSettle " sec"
Fill-Combo $ui.TimeoutBox @(30, 60, 90, 120, 180) $State.launchTimeout " sec"
Fill-Combo $ui.MainSettleBox @(10, 15, 20, 30, 45, 60) $State.mainSettle " sec"
foreach ($o in @(@("off", "Never"), @("window", "When Roblox opens"), @("connected", "When it's in a game"))) {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $o[1]; $it.Tag = $o[0]
    $ui.TabCloseBox.Items.Add($it) | Out-Null
    if ($o[0] -eq $State.tabCloseWhen) { $ui.TabCloseBox.SelectedItem = $it }
}
$ui.TabCloseBox.Add_SelectionChanged({
    $script:State.tabCloseWhen = "" + $ui.TabCloseBox.SelectedItem.Tag; Save-Settings
    Render-Accounts; Render-ChromeSetup   # the setup chips depend on it
    if ($script:State.tabCloseWhen -ne "off") { Say "Tab closing on. Accounts whose helper isn't 2.2 yet show a setup chip." }
    Update-TabCloseLine
})
function Update-TabCloseLine {
    # With tab closing off, say so plainly (the most common reason a launch tab stays open).
    if ($script:State.tabCloseWhen -eq "off") { $ui.TabCloseLast.Text = "Tab closing is off, so launch tabs stay open. Pick 'When it's in a game' to turn it on."; $ui.TabCloseLast.Foreground = Brush "Muted" }
    elseif ($ui.TabCloseLast.Text -match '^Tab closing is off') { $ui.TabCloseLast.Text = "Last launch tab: none yet." }
}
Update-TabCloseLine
$ui.SettleBox.Add_SelectionChanged({ $script:State.launchSettle = [int]$ui.SettleBox.SelectedItem.Tag; Save-Settings })
$ui.TimeoutBox.Add_SelectionChanged({ $script:State.launchTimeout = [int]$ui.TimeoutBox.SelectedItem.Tag; Save-Settings })
$ui.MainSettleBox.Add_SelectionChanged({ $script:State.mainSettle = [int]$ui.MainSettleBox.SelectedItem.Tag; Save-Settings })
$ui.SoundBox.IsChecked = $State.alertSound
$ui.AutoRejoinBox.IsChecked = $State.autoRejoin
$ui.AutoMuteBox.IsChecked = $State.autoMuteAlts
$ui.TrayBox.IsChecked = $State.trayOnMinimize
$ui.SoundBox.Add_Click({ $script:State.alertSound = [bool]$ui.SoundBox.IsChecked; Save-Settings })
$ui.AutoRejoinBox.Add_Click({ $script:State.autoRejoin = [bool]$ui.AutoRejoinBox.IsChecked; Save-Settings })
$ui.AutoMuteBox.Add_Click({ $script:State.autoMuteAlts = [bool]$ui.AutoMuteBox.IsChecked; Save-Settings })
$ui.AnimBox.IsChecked = $State.animations
$ui.AnimBox.Add_Click({
    $script:State.animations = [bool]$ui.AnimBox.IsChecked; Save-Settings
    Say $(if (-not $script:State.animations) { "Animations are off." } elseif (Test-Motion) { "Animations are on." } else { "Animations are on here, but Windows' own animations are off, so they stay off." })
})
$ui.TrayBox.Add_Click({ $script:State.trayOnMinimize = [bool]$ui.TrayBox.IsChecked; Save-Settings })
$ui.OpenFolderBtn.Add_Click({ Start-Process explorer.exe $AppDir })

# Disconnect check, low power
$ui.DiscBox.IsChecked = $State.discCheck
$ui.SameServerBox.IsChecked = $State.rejoinSameServer
$ui.SameServerBox.Add_Click({ $script:State.rejoinSameServer = [bool]$ui.SameServerBox.IsChecked; Save-Settings })
$ui.DiscBox.Add_Click({ $script:State.discCheck = [bool]$ui.DiscBox.IsChecked; Save-Settings })
$ui.EcoBox.IsChecked = $State.ecoAlts
$ui.EcoBox.Add_Click({
    $script:State.ecoAlts = [bool]$ui.EcoBox.IsChecked; Save-Settings
    foreach ($w in $script:Wins) { $w.EcoFailed = $false }
    Apply-Efficiency
    Say $(if ($script:State.ecoAlts) { "Efficiency mode ON for alts." } else { "Efficiency mode OFF. All windows run at normal speed." })
})
$ui.LowPowerBox.IsChecked = $State.lowPower
$ui.LowPowerBox.Add_Click({
    $script:State.lowPower = [bool]$ui.LowPowerBox.IsChecked; Save-Settings
    Apply-LowPower
    Say $(if ($script:State.lowPower) { "Low-power mode ON: alt windows are small now." } else { "Low-power mode OFF: windows are back to normal size." })
})

# Discord
$ui.HookBox.Text = $State.webhook
$ui.HookDoneBox.IsChecked = $State.webhookOnDone
function Update-HookStatus {
    $u = $ui.HookBox.Text.Trim()
    if ($u -eq "") { $ui.HookStatus.Text = "Not set."; $ui.HookStatus.Foreground = Brush "Muted" }
    elseif (Test-HookUrl $u) { $ui.HookStatus.Text = [string][char]0x2713 + "  Looks like a Discord webhook link."; $ui.HookStatus.Foreground = Brush "SuccessInk" }
    else { $ui.HookStatus.Text = [string][char]0x26A0 + "  That isn't a Discord webhook link."; $ui.HookStatus.Foreground = Brush "DangerInk" }
}
$ui.HookBox.Add_TextChanged({ Update-HookStatus })
$ui.HookSaveBtn.Add_Click({
    $u = $ui.HookBox.Text.Trim()
    if ($u -ne "" -and -not (Test-HookUrl $u)) { Say "That isn't a Discord webhook link."; return }
    $script:State.webhook = $u; Save-Settings
    Say $(if ($u) { "Discord alerts are on." } else { "Discord alerts are off." })
})
$ui.HookTestBtn.Add_Click({
    $script:State.webhook = $ui.HookBox.Text.Trim(); Save-Settings
    if (-not (Test-HookUrl $script:State.webhook)) { Say "Paste a Discord webhook link first."; return }
    if (Send-Webhook "Hi! This is a test from BloxKit. Alerts will show up here.") { Say "Test message sent. Check Discord!"; Show-MascotMoment "Success" "Test message sent to Discord." }
})
$ui.HookDoneBox.Add_Click({ $script:State.webhookOnDone = [bool]$ui.HookDoneBox.IsChecked; Save-Settings })

# Schedule + startup
$ui.SchedBox.IsChecked = $State.schedOn
$ui.SchedTimeBox.Text = $State.schedTime
$ui.SchedBox.Add_Click({ $script:State.schedOn = [bool]$ui.SchedBox.IsChecked; Save-Settings; Update-SchedUi })
$ui.SchedTimeBox.Add_LostFocus({
    $t = $ui.SchedTimeBox.Text.Trim()
    if (Test-TimeText $t) {
        $p = $t.Split(":"); $t = ("{0:00}:{1}" -f [int]$p[0], $p[1])
        $ui.SchedTimeBox.Text = $t
        if ($t -ne $script:State.schedTime) { $script:State.schedTime = $t; $script:State.schedLastRun = ""; Save-Settings }
    } else { Say "Type the time like 08:00 or 19:30." }
    Update-SchedUi
})
$ui.SchedUseLinkBtn.Add_Click({
    $info = Get-LinkInfo $ui.LinkBox.Text
    if (@("game","private","share") -notcontains $info.Kind) { Say "Paste a game or private server link in the Accounts tab first."; return }
    $script:State.schedLink = $info.Url; Save-Settings; Update-SchedUi
    Say "Scheduled start will use this game."
})
$OldStartupLnk = Join-Path $StartupDir "Roblox Manager.lnk"   # the app's name before BloxKit
if (-not $NoRoblox -and (Test-Path $OldStartupLnk)) { Remove-Item $OldStartupLnk -Force -ErrorAction SilentlyContinue; Set-RunAtStartup $true -Quiet }
$ui.StartupBox.IsChecked = (Test-Path $StartupLnk)
# Opened from BloxKit.exe: an older startup shortcut (PowerShell) is switched over to it.
if (-not $NoRoblox -and $env:RML_LAUNCHER -and (Test-Path $StartupLnk) -and
    (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLnk).TargetPath -ne $env:RML_LAUNCHER) { Set-RunAtStartup $true -Quiet }
$ui.StartupBox.Add_Click({ Set-RunAtStartup ([bool]$ui.StartupBox.IsChecked); $ui.StartupBox.IsChecked = (Test-Path $StartupLnk) })

# Backup
$ui.ExportBtn.Add_Click({ Export-Backup })

# Help and feedback (Settings). Put the Discord invite in $BkLinks.Discord; the button shows once it's set.
$ui.AboutText.Text = "BloxKit $BkVersion. Questions and ideas: the BloxKit Discord. Bugs: a short form on GitHub, or #bug-reports on Discord."
$ui.DiscordBtn.Visibility = $(if ($BkLinks.Discord) { "Visible" } else { "Collapsed" })
if (-not $BkLinks.Discord) { $ui.AboutText.Text = "BloxKit $BkVersion. Found a bug or have an idea? Send it on GitHub with the buttons below (a short form)." }
$ui.DiscordBtn.Add_Click({ Start-Process $BkLinks.Discord })
$ui.BugBtn.Add_Click({ Start-Process $BkLinks.Bug })
$ui.IdeaBtn.Add_Click({ Start-Process $BkLinks.Idea })
$ui.RepoBtn.Add_Click({ Start-Process $BkLinks.Repo })

# ---- updates: compares with the newest BloxKit on GitHub, and updates this folder in place ----
$script:UpdNewest = $null; $script:UpdTask = $null
function Start-UpdateCheck {
    # In the background: only the first 4 KB of BloxKit.ps1 on GitHub, enough for its $BkVersion.
    if ($NoRoblox -or $script:UpdTask) { return }
    try {
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $c = New-Object System.Net.Http.HttpClient; $c.Timeout = [TimeSpan]::FromSeconds(15)
        $rq = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $BkLinks.Raw)
        $rq.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue(0, 4095)
        $script:UpdTask = $c.SendAsync($rq)
    } catch { $script:UpdTask = $null }
}
function Read-UpdateCheck {
    # Called by the timer until the answer is in.
    $t = $script:UpdTask
    if (-not $t -or -not $t.IsCompleted) { return }
    $script:UpdTask = $null
    try {
        if ($t.IsFaulted -or -not $t.Result.IsSuccessStatusCode) { return }
        $m = [regex]::Match($t.Result.Content.ReadAsStringAsync().Result, '(?m)^\$BkVersion\s*=\s*"([\d.]+)"')
        if (-not $m.Success) { return }
        $script:UpdNewest = [version]$m.Groups[1].Value
        Update-UpdateUi
        if ($script:UpdNewest -gt [version]$BkVersion) {
            Say "BloxKit $($script:UpdNewest) is out (you have $BkVersion). Settings > Help and feedback > Update."
            Show-MascotMoment "Attention" "BloxKit $($script:UpdNewest) is out: Settings > Help and feedback." 8
        }
    } catch {}
}
function Update-UpdateUi {
    if ($script:UpdNewest -and $script:UpdNewest -gt [version]$BkVersion) { $ui.UpdateBtn.Content = "Update to $($script:UpdNewest)"; $ui.UpdateBtn.Background = Brush "Accent" }
    else { $ui.UpdateBtn.Content = "Check for updates"; $ui.UpdateBtn.ClearValue([System.Windows.Controls.Control]::BackgroundProperty) }
}
function Start-Update {
    $upd = Join-Path $PSScriptRoot "tools\update.ps1"
    if (-not (Test-Path -LiteralPath $upd)) { Start-Process $BkLinks.Repo; Say "The updater isn't in this folder. Download BloxKit again from GitHub (opened in your browser)."; return }
    $r = [BkBox]::Show("Update BloxKit $BkVersion to $($script:UpdNewest)?`n`nBloxKit closes, gets the new version from GitHub, and opens again in a few seconds. Your accounts and settings stay, and Roblox keeps running.", "Update BloxKit", "YesNo", "Question")
    if ($r -ne "Yes") { return }
    # The updater runs from a copy in Temp, so it can replace its own file in this folder too.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "bloxkit-updater.ps1"
    Copy-Item -LiteralPath $upd $tmp -Force
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tmp`" -AppDir `"$PSScriptRoot`" -WaitPid $PID -Restart -Quiet"
    Say "Updating BloxKit... it opens again in a few seconds."
    Release-Instance   # so the updated copy can start
    $script:ReallyExit = $true
    $win.Close()
}
$ui.UpdateBtn.Add_Click({
    if ($NoRoblox) { Say "(test mode) no updates in test mode."; return }
    if (-not $script:UpdNewest) {
        # Not checked yet (or no answer): ask now, for up to 15 seconds.
        Say "Checking GitHub for a newer BloxKit..."
        Start-UpdateCheck
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($script:UpdTask -and -not $script:UpdTask.IsCompleted -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 100 }
        Read-UpdateCheck
        if (-not $script:UpdNewest) { Say "Couldn't reach GitHub to check for updates. Try again later."; return }
    }
    if ($script:UpdNewest -le [version]$BkVersion) { Say "You have the newest BloxKit ($BkVersion)."; Show-MascotMoment "Success" "BloxKit $BkVersion is the newest."; return }
    Start-Update
})
$ui.ImportBtn.Add_Click({ Import-Backup })

# Window events
$win.Add_SourceInitialized({
    $script:PanelHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    if (-not $NoRoblox) { Refresh-Windows }
    Build-Wall
})
$win.Add_SizeChanged({ Place-Screens })
$win.Add_PreviewKeyDown({ param($s,$e) if ($e.Key -eq "Escape" -and $script:PickFor) { Stop-PickSpot; Say "Click spot not changed."; $e.Handled = $true } })
$script:SetupReadAt = [DateTime]::MinValue
$win.Add_Activated({
    Place-Screens
    # Back from Chrome? Re-read profile setup (helper installed, "Always allow" ticked).
    if (([DateTime]::Now - $script:SetupReadAt).TotalSeconds -ge 10) { $script:SetupReadAt = [DateTime]::Now; $script:SetupCache = @{}; Render-Accounts; if ($ui.TabSettings.IsSelected) { Render-ChromeSetup } }
})
$win.Add_StateChanged({
    if ($win.WindowState -eq "Minimized" -and $script:State.trayOnMinimize) {
        $win.Hide()
        if (-not $script:TrayTipShown) {
            $Tray.ShowBalloonTip(4000, "BloxKit", "Still running here. Double-click this icon to open it again.", [System.Windows.Forms.ToolTipIcon]::Info)
            $script:TrayTipShown = $true
        }
    }
    Place-Screens
})
$win.Add_Closing({
    param($s, $e)
    if ($script:QBusy -and -not $script:ReallyExit) {
        $r = [BkBox]::Show("Accounts are still opening. Close anyway?", "BloxKit", "YesNo", "Question")
        if ($r -ne "Yes") { $e.Cancel = $true; return }
    }
    $QueueTimer.Stop(); $Tick.Stop(); $Keys.Stop(); $TabTimer.Stop()
    if ($script:TabListener) { try { $script:TabListener.Stop() } catch {} }
    $HotKeyWin.Clear(); $HotKeyWin.DestroyHandle()
    foreach ($w in $script:Wins) { if ($w.Nick) { Add-Uptime $w.Nick $w.Since; $w.Since = [DateTime]::Now } }
    $rb = $win.RestoreBounds   # the normal size, even while maximized
    if (-not $rb.IsEmpty) { $script:State.winWidth = [int]$rb.Width; $script:State.winHeight = [int]$rb.Height }
    if ($win.WindowState -ne "Minimized") { $script:State.winMax = $win.WindowState -eq "Maximized" }
    if (Test-PlanActive) { Save-PlanRun; Add-PlanHistory "The app closed. The schedule will be paused when it opens again." }
    Save-Settings; Save-Session
    foreach ($w in $script:Wins) { [RbxCore]::RemoveScreen($w.Thumb) }
    Apply-Efficiency -AllOff   # leave Roblox windows the way we found them
    $Tray.Visible = $false; $Tray.Dispose()
    Release-Locks
    Release-Instance
})

# ================================================================ TIMERS ==
$script:TickCount = 0
$Tick = New-Object System.Windows.Threading.DispatcherTimer
$Tick.Interval = [TimeSpan]::FromSeconds(1)
$Tick.Add_Tick({
    $script:TickCount++
    Update-Mascot   # the mascot and its line follow what's really happening
    if ($script:UpdTask) { Read-UpdateCheck }
    if ($NoRoblox) {   # tests: no Roblox windows, only the schedule's clock
        if ($script:ShowSignal.WaitOne(0)) { Show-App }
        if (Test-PlanActive) { Invoke-Plan "tick"; if ($ui.TabSchedule.IsSelected) { Update-ScheduleLive } }
        if ($script:TickCount % 5 -eq 2 -and $win.IsVisible) { try { Update-LoadMonitor } catch {} }
        return
    }
    if ($script:ShowSignal.WaitOne(0)) { Show-App }   # someone started the app again
    if ($script:TickCount % 2 -eq 0) { Refresh-Windows; Place-Screens }
    if ($script:PendingRejoin.Count -gt 0) {
        $list = @($script:PendingRejoin); $script:PendingRejoin.Clear()
        foreach ($a in $list) { Rejoin-Account $a }
    }
    if ($script:TickCount % 3 -eq 0) { Update-Status }
    if ($script:TickCount % 30 -eq 0) { Check-Disconnects }
    if ($script:TickCount % 3 -eq 1) { Watch-Logs }
    if ($script:TickCount % 20 -eq 0) { Check-Schedule; Update-LiveTexts }
    if ($script:TickCount % 5 -eq 0) {
        # Both ways: Windows can hand a new Roblox client the mute of an old one (they're the same program).
        foreach ($w in $script:Wins) { [RbxCore]::SetProcessMute([RbxCore]::PidOf($w.Handle), [bool]$w.Muted) | Out-Null }
        if ($script:SessionDirty) { Save-Session }
    }
    if ($script:TickCount % 10 -eq 5) { Apply-Efficiency -Force }
    if ($script:TickCount % 10 -eq 7) { Sync-RobloxGraphics }   # keeps Roblox on the picked graphics while none is running
    if ($script:TickCount % 3 -eq 2 -and $ui.TabSettings.IsSelected -and $win.IsVisible) { Update-PerfUi }   # so Save to Roblox and the line under it follow what is running
    # Your PC right now (Live screens): one ~10 ms reading every 5 s while the window is open.
    if ($script:TickCount % 5 -eq 2 -and $win.IsVisible -and $win.WindowState -ne "Minimized") { try { Update-LoadMonitor } catch {} }
    if (Test-PlanActive) {
        Invoke-Plan "tick"
        if ($ui.TabSchedule.IsSelected) { Update-ScheduleLive }
    }
    if ($script:AfkOn) {
        if ($script:SecondsLeft -gt 0) { $script:SecondsLeft-- }
        if ($script:SecondsLeft -le 0) {
            if (Do-Jumps) { Reset-Countdown } else { $script:Waiting = $true; Update-AfkUi }
        } else { Update-AfkUi }
    }
})

# Hotkeys (Ctrl+Alt+key). Registered with Windows, so they fire instantly with no polling.
# A combination another app already owns falls back to being checked 10 times a second.
$HotKeys = @(@{ Vk = 0x47; Act = "back" }, @{ Vk = 0x4A; Act = "jump" }, @{ Vk = 0x41; Act = "afk" })
for ($i = 1; $i -le 9; $i++) { $HotKeys += @{ Vk = 0x30 + $i; Act = "play$i" } }
function Invoke-HotKey([string]$act) {
    switch -Regex ($act) {
        '^back$' { Back-To-App }
        '^jump$' { Do-Jumps -Manual | Out-Null; Reset-Countdown }
        '^afk$'  { Set-Afk (-not $script:AfkOn) }
        '^play(\d)$' {
            $n = [int]$Matches[1]
            $w = @($script:Wins | Where-Object { $_.Num -eq $n }) | Select-Object -First 1
            if ($w) { Play-Window $w } else { Say "There's no screen #$n." }
        }
    }
}
$HotKeyWin = New-Object RbxHotKeys
$HotKeyWin.add_Pressed({ param($id) Invoke-HotKey $HotKeys[$id].Act })
$script:PollKeys = @()
for ($i = 0; $i -lt $HotKeys.Count; $i++) {
    if ($NoRoblox) { continue }
    if (-not $HotKeyWin.Add($i, 0x0003, $HotKeys[$i].Vk)) { $script:PollKeys += $HotKeys[$i] }   # 0x3 = Ctrl+Alt
}
$script:KeyWasDown = @{}
$Keys = New-Object System.Windows.Threading.DispatcherTimer
$Keys.Interval = [TimeSpan]::FromMilliseconds(100)
$Keys.Add_Tick({
    $ctrl = ([RbxCore]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    $alt  = ([RbxCore]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
    foreach ($k in $script:PollKeys) {
        $down = $ctrl -and $alt -and (([RbxCore]::GetAsyncKeyState($k.Vk) -band 0x8000) -ne 0)
        if ($down -and -not $script:KeyWasDown[$k.Act]) { Invoke-HotKey $k.Act }
        $script:KeyWasDown[$k.Act] = $down
    }
})

# ================================================================= START ==
function Show-StartupNotes {
    if ($script:SettingsLocked) {
        $r = [BkBox]::Show(
            "Your settings file couldn't be read:`n$SettingsFile`n($($script:LoadError))`n`n" +
            "To keep your accounts safe, nothing is saved while it's like this.`n`n" +
            "Yes = start fresh. The unreadable file is kept next to it (settings.unreadable-...json) so it can still be recovered.`n" +
            "No = leave it. Fix or replace the file (Settings > Open settings folder), then restart the app.",
            "BloxKit", "YesNo", "Warning")
        if ($r -eq "Yes") {
            $keep = Join-Path $AppDir ("settings.unreadable-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".json")
            try {
                Move-Item -LiteralPath $SettingsFile $keep -ErrorAction Stop
                $script:SettingsLocked = $false; Save-Settings
                Say "Started fresh. Your old settings file was kept as $keep"
            } catch { Say "Couldn't move the unreadable settings file, so settings still aren't being saved: $($_.Exception.Message)" }
        } else { Say "Settings are NOT being saved until the settings file is fixed." }
        return
    }
    if ($script:LoadNote) {
        [BkBox]::Show("Some things in your settings were fixed while loading:`n`n- " + ($script:LoadNote -replace "`n", "`n- "), "BloxKit", "OK", "Information") | Out-Null
        Save-Settings
    }
    if ($script:Run.State -eq "paused" -and $script:State.planRun -and $script:State.planRun.State -ne "paused") {
        Say "The group schedule was paused because the app closed ('$($script:Run.GroupName)'). Resume it on the Schedule tab."
    }
    $need = @($script:State.accounts | Where-Object { $_.needsLogin })
    if ($need.Count) {
        $r = [BkBox]::Show(
            "$($need.Count) account(s) need to sign in to Roblox once on this PC: " + (($need | ForEach-Object { $_.nick }) -join ", ") + ".`n`n" +
            "Their Chrome profiles are new here (logins stay in Chrome on the old PC, not in the backup).`n`nSign them in now, one at a time?",
            "Sign in", "YesNo", "Question")
        if ($r -eq "Yes") { Start-SignIn $need }
    }
}

if (-not $NoRoblox) { Grab-Locks | Out-Null }
Update-AutoJoinBox
$script:LoadWarm = Start-LoadWarmUp   # in the background, so "Your PC right now" never freezes the window
Update-PerfUi
Sync-RobloxGraphics   # a new install, or graphics changed in a game: Roblox gets the picked ones before anything opens
$ui.LinkBox.Text = $State.lastLink
Render-Favorites
Render-Groups
Render-Accounts
Update-LinkStatus
Update-Status
Reset-Countdown
Update-HookStatus
Update-SchedUi
Update-LiveTexts
if (-not $ChromeExe) { Say "Warning: Google Chrome wasn't found. This app needs Chrome." }
elseif (@($State.accounts).Count -eq 0) { Say "Welcome! Start by clicking '+ Add account' for your main account." }
else { Say "Ready. Tip: 'Start everything' opens your main first, then sends every alt to its server." }
if ($script:AfkOn) { Say "Anti-AFK is on, as it was when the app closed." }
# Just updated? The updater leaves a note (and says whether the Chrome helper changed).
$UpdNote = Join-Path $AppDir "updated.txt"
if (Test-Path -LiteralPath $UpdNote) {
    $t = ("" + (Get-Content -LiteralPath $UpdNote -Raw)).Trim(); Remove-Item -LiteralPath $UpdNote -Force -ErrorAction SilentlyContinue
    if ($t -match '^from (\S+) to (\S+)') {
        Say ("Updated BloxKit $($Matches[1]) to $($Matches[2])." + $(if ($t -match 'helper') { " The auto-click helper changed too: in each Chrome profile, open chrome://extensions and click its reload arrow." } else { "" }))
        Show-MascotMoment "Celebrate" "Updated to BloxKit $($Matches[2])." 6
    } elseif ($t -match '^same') { Say "You already have the newest BloxKit ($BkVersion)." }
}
Start-UpdateCheck   # in the background; Settings > Help and feedback shows "Update to ..." when there's a newer one
$Tick.Start()
if ($script:PollKeys.Count -gt 0) {
    $Keys.Start()
    Say ("Note: another app already uses " + (($script:PollKeys | ForEach-Object { "Ctrl+Alt+" + [char]$_.Vk }) -join ", ") + ". Those still work, but less reliably.")
}
$win.Add_Closed({ $app.Shutdown() })
if ($State.winWidth -ge $win.MinWidth -and $State.winHeight -ge $win.MinHeight) {   # last time's size, if it still fits this screen
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Width = [Math]::Min($State.winWidth, $wa.Width); $win.Height = [Math]::Min($State.winHeight, $wa.Height)
}
if ($State.winMax) { $win.WindowState = "Maximized" }
Update-Mascot
$win.Add_ContentRendered({ if (-not $script:IntroDone) { $script:IntroDone = $true; Start-Intro } })   # once, when the window first appears
$win.Show()
if ($Minimized) { $win.WindowState = "Minimized" }
Show-StartupNotes
$app.Run() | Out-Null
