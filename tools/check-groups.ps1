# Checks Roblox Manager's groups: creating, renaming, members, summaries, and the account filter.
#     powershell -ExecutionPolicy Bypass -File tools\check-groups.ps1
# No app window, no files.
. (Join-Path $PSScriptRoot "..\RobloxManager.ps1") -TestOnly

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}
function New-TestState {
    $s = New-Defaults
    $main = New-Account "Main" "Profile 4"; $main.isMain = $true
    $s.accounts = @($main, (New-Account "Alt1" "P1"), (New-Account "Alt2" "P2"), (New-Account "Alt3" "P3"))
    return $s
}

try {
    # ---- creating ----
    $s = New-TestState
    $r = New-Group $s "Group A" @("alt1", "Main", "Ghost", "Alt1")
    Check "a new group gets an id and its members (real accounts only, once each, in list order)" (-not $r.Error -and $r.Group.id -match '^[0-9a-f-]{36}$' -and ($r.Group.nicks -join ",") -eq "Main,Alt1")
    Check "it's added to the list" (@($s.groups).Count -eq 1)
    Check "an empty name is refused" ((New-Group $s "   " @()).Error -and @($s.groups).Count -eq 1)
    Check "a name that's taken is refused (any upper/lower case)" ((New-Group $s "group a" @()).Error -and @($s.groups).Count -eq 1)
    $b = (New-Group $s "Group B" @()).Group
    Check "a group can start empty" ($b -and @($b.nicks).Count -eq 0)

    # ---- renaming, duplicating, members ----
    $a = $s.groups[0]
    Check "rename to a taken name is refused" ((Rename-Group $s $a "group b") -and $a.name -eq "Group A")
    Check "rename works and keeps the id" (-not (Rename-Group $s $a "Farm") -and $a.name -eq "Farm" -and $a.id -eq $r.Group.id)
    Check "renaming to the same name in other case is fine" (-not (Rename-Group $s $a "FARM") -and $a.name -eq "FARM")
    $c = Copy-Group $s $a
    Check "duplicate makes a new group with a new id and the same members" ($c.name -eq "FARM (copy)" -and $c.id -ne $a.id -and ($c.nicks -join ",") -eq "Main,Alt1" -and @($s.groups).Count -eq 3)
    $c2 = Copy-Group $s $a
    Check "duplicating again picks a free name" ($c2.name -eq "FARM (copy 2)")
    Set-GroupMembers $s $c @("Alt3", "alt2", "nobody")
    Check "setting members keeps real accounts, in list order" (($c.nicks -join ",") -eq "Alt2,Alt3")
    Check "and doesn't change the group it was copied from" (($a.nicks -join ",") -eq "Main,Alt1")
    Remove-GroupMember $c "ALT2"
    Check "removing a member only takes it out of that group" (($c.nicks -join ",") -eq "Alt3" -and @($s.accounts).Count -eq 4)

    # ---- order and delete ----
    $order = { ($s.groups | ForEach-Object { $_.name }) -join "," }
    Move-Group $s $c -1
    Check "move up" ((& $order) -eq "FARM,FARM (copy),Group B,FARM (copy 2)")
    Move-Group $s $s.groups[0] -1
    Check "moving the first one up does nothing" ((& $order) -eq "FARM,FARM (copy),Group B,FARM (copy 2)")
    Remove-Group $s $b
    Check "delete removes only that group; accounts stay" ((& $order) -eq "FARM,FARM (copy),FARM (copy 2)" -and @($s.accounts).Count -eq 4)

    # ---- summary ----
    # what the app knows about each account right now
    $info = @{
        "main" = @{ Running = $true;  Ready = $true;  Groups = @("FARM") }
        "alt1" = @{ Running = $false; Ready = $false; Groups = @("FARM") }
        "alt2" = @{ Running = $false; Ready = $true;  Groups = @() }
        "alt3" = @{ Running = $false; Ready = $true;  Groups = @("FARM (copy)") }
    }
    $g = Get-GroupSummary $a $s.accounts $info $false
    Check "summary counts members, main, open and not ready" ($g.Members -eq 2 -and $g.HasMain -and $g.Running -eq 1 -and $g.NotReady -eq 1)
    Check "a group with a member that isn't ready says so" ($g.Status -eq "Needs setup")
    $g = Get-GroupSummary $c $s.accounts $info $false
    Check "all ready, none open: Ready" ($g.Status -eq "Ready" -and -not $g.HasMain)
    $info["alt3"].Running = $true
    Check "all open: Running" ((Get-GroupSummary $c $s.accounts $info $false).Status -eq "Running")
    Check "being opened right now: Opening" ((Get-GroupSummary $c $s.accounts $info $true).Status -eq "Opening")
    $e = (New-Group $s "Empty" @()).Group
    Check "no members: Draft" ((Get-GroupSummary $e $s.accounts $info $false).Status -eq "Draft")

    # ---- account filter (membership editor) ----
    $names = { param($list) (@($list) | ForEach-Object { $_.nick }) -join "," }
    Check "no search, all: everyone" ((& $names (Select-Accounts $s.accounts "" "all" $info)) -eq "Main,Alt1,Alt2,Alt3")
    Check "search by name, any case" ((& $names (Select-Accounts $s.accounts "ALT" "all" $info)) -eq "Alt1,Alt2,Alt3")
    Check "main only" ((& $names (Select-Accounts $s.accounts "" "main" $info)) -eq "Main")
    Check "alts only" ((& $names (Select-Accounts $s.accounts "" "alt" $info)) -eq "Alt1,Alt2,Alt3")
    Check "open now" ((& $names (Select-Accounts $s.accounts "" "running" $info)) -eq "Main,Alt3")
    Check "not open" ((& $names (Select-Accounts $s.accounts "" "offline" $info)) -eq "Alt1,Alt2")
    Check "in a group" ((& $names (Select-Accounts $s.accounts "" "assigned" $info)) -eq "Main,Alt1,Alt3")
    Check "in no group" ((& $names (Select-Accounts $s.accounts "" "unassigned" $info)) -eq "Alt2")
    Check "search and filter together" ((& $names (Select-Accounts $s.accounts "2" "unassigned" $info)) -eq "Alt2")

    # ---- loading groups ----
    $f = Join-Path ([IO.Path]::GetTempPath()) ("rml-groups-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".json")
    [IO.File]::WriteAllText($f, '{ "accounts": [ { "nick": "A", "profileDir": "P" } ], "groups": [ { "name": "G", "nicks": ["A"] }, { "name": "g", "nicks": [] }, { "id": "0f8fad5b-d9cb-469f-a165-70867728950e", "name": "H", "nicks": [] } ] }')
    $r = Read-SettingsFile $f
    Remove-Item $f -Force
    $gs = @($r.State.groups)
    Check "old groups get an id when loaded; saved ids are kept" ($gs[0].id -match '^[0-9a-f-]{36}$' -and $gs[2].id -eq "0f8fad5b-d9cb-469f-a165-70867728950e")
    Check "a second group with the same name is renamed and reported" ($gs[1].name -eq "g (2)" -and (@($r.Warnings) -join " ") -match "g \(2\)")
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_"
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All group checks passed." })
exit $script:fails
