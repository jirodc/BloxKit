# Checks how BloxKit saves, loads, renames and backs up accounts (no app window).
#     powershell -ExecutionPolicy Bypass -File tools\check-settings.ps1
# Works in a temporary folder; never touches your real settings.
. (Join-Path $PSScriptRoot "..\BloxKit.ps1") -TestOnly

$Dir = Join-Path ([IO.Path]::GetTempPath()) ("rml-check-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $Dir | Out-Null
$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $true)) }

# A settings file as written by the app before this change (no account ids).
$OldFormat = @'
{
  "accounts": [
    { "nick": "TestMain", "profileDir": "Profile 4", "profileUrl": "https://www.roblox.com/users/1/profile", "isMain": true, "checked": false, "lastUrl": "" },
    { "nick": "TestAlt", "profileDir": "RobloxLauncher_TestAlt", "profileUrl": "", "isMain": false, "checked": true, "lastUrl": "" }
  ],
  "groups": [ { "name": "Farm", "nicks": [ "TestAlt" ] } ],
  "favorites": [ { "name": "Game", "url": "https://www.roblox.com/games/1" } ],
  "clickSpots": { "testalt": "0.2,0.3" },
  "statsSecs": { "testalt": 120 },
  "launchSettle": 12,
  "webhook": "https://discord.com/api/webhooks/1/secret-token"
}
'@

try {
    # ---- loading ----
    $f = Join-Path $Dir "load-ok.json"; Write-Text $f $OldFormat
    $r = Read-SettingsFile $f
    Check "loads an old settings file" ($r.Ok -and @($r.State.accounts).Count -eq 2 -and $r.State.launchSettle -eq 12)
    Check "gives every account a stable id" (@($r.State.accounts | Where-Object { $_.id -match '^[0-9a-f-]{36}$' }).Count -eq 2)

    $f = Join-Path $Dir "missing.json"
    $r = Read-SettingsFile $f
    Check "a missing file means a fresh start" ($r.Ok -and @($r.State.accounts).Count -eq 0 -and $r.Source -eq "new")

    $f = Join-Path $Dir "corrupt.json"; Write-Text $f '{ "accounts": [ { "nick": "Test'
    $r = Read-SettingsFile $f
    Check "a corrupt file with no backup is NOT treated as empty" ((-not $r.Ok) -and $r.Error)
    Check "the corrupt file is left as it was" ((Get-Content $f -Raw) -eq '{ "accounts": [ { "nick": "Test')

    $f = Join-Path $Dir "corrupt2.json"; Write-Text $f '{ broken'; Write-Text "$f.bak" $OldFormat
    $r = Read-SettingsFile $f
    Check "a corrupt file falls back to the .bak copy" ($r.Ok -and $r.Source -eq "backup" -and @($r.State.accounts).Count -eq 2 -and @($r.Warnings).Count -gt 0)

    $f = Join-Path $Dir "dupes.json"
    Write-Text $f '{ "accounts": [ { "nick": "A", "profileDir": "P1" }, { "nick": "a", "profileDir": "P2" } ], "groups": [ { "name": "G", "nicks": [ "A", "Ghost" ] } ] }'
    $r = Read-SettingsFile $f
    Check "duplicate nicknames are reported, the first one kept" ($r.Ok -and @($r.State.accounts).Count -eq 1 -and $r.State.accounts[0].profileDir -eq "P1" -and (@($r.Warnings) -join " ") -match "called 'a'")
    Check "group members that aren't accounts are dropped and reported" ((@($r.State.groups[0].nicks) -join ",") -eq "A" -and (@($r.Warnings) -join " ") -match "Ghost")

    $f = Join-Path $Dir "tabclose.json"
    Write-Text $f '{ "accounts": [], "tabCloseWhen": "connected" }'
    Check "the tab-closing setting is loaded" ((Read-SettingsFile $f).State.tabCloseWhen -eq "connected")
    Write-Text $f '{ "accounts": [], "tabCloseWhen": "always-and-everything" }'
    Check "an unknown tab-closing value falls back to off" ((Read-SettingsFile $f).State.tabCloseWhen -eq "off")
    Write-Text $f '{ "accounts": [] }'
    Check "older settings files: tab closing is off" ((Read-SettingsFile $f).State.tabCloseWhen -eq "off")

    Write-Text $f '{ "accounts": [], "spread": 2 }'
    Check "the server spread setting is loaded" ((Read-SettingsFile $f).State.spread -eq 2)
    Write-Text $f '{ "accounts": [], "spread": -3 }'
    Check "a bad spread value falls back to 'Roblox picks'" ((Read-SettingsFile $f).State.spread -eq 0)

    Write-Text $f '{ "accounts": [ { "nick": "A", "profileDir": "Profile 4" }, { "nick": "B", "profileDir": "profile 4" }, { "nick": "C", "profileDir": "P3" } ] }'
    $r = Read-SettingsFile $f
    Check "two accounts on the same Chrome profile: both kept, and reported" (@($r.State.accounts).Count -eq 3 -and (@($r.Warnings) -join " ") -match "A and B use the same Chrome profile")

    # ---- auto-click per account ----
    Write-Text $f '{ "autoJoin": true, "accounts": [ { "nick": "A", "profileDir": "P1" }, { "nick": "B", "profileDir": "P2", "autoJoin": false } ] }'
    $st = (Read-SettingsFile $f).State
    Check "accounts from before keep the old all-accounts auto-click setting" ($st.accounts[0].autoJoin -eq $true)
    Check "an account's own auto-click setting is kept" ($st.accounts[1].autoJoin -eq $false)
    Check "some on, some off: 'some'" ((Get-AutoJoinSummary $st) -eq "some")
    Set-AutoJoinAll $st $true
    Check "turn on for all" ((Get-AutoJoinSummary $st) -eq "all" -and $st.autoJoin)
    Set-AutoJoinAll $st $false
    Check "turn off for all (new accounts then start with it off)" ((Get-AutoJoinSummary $st) -eq "none" -and -not $st.autoJoin)
    Write-SettingsFile $st $f | Out-Null
    Check "it's saved per account" (-not (Read-SettingsFile $f).State.accounts[0].autoJoin)
    $st.accounts = @()
    Check "no accounts: 'none'" ((Get-AutoJoinSummary $st) -eq "none")

    # ---- saving ----
    $src = Join-Path $Dir "src.json"; Write-Text $src $OldFormat
    $before = (Read-SettingsFile $src).State
    $f = Join-Path $Dir "saved.json"
    $err = Write-SettingsFile $before $f
    $after = (Read-SettingsFile $f).State
    Check "save then load gives back the same accounts and ids" (-not $err -and (($after.accounts | ForEach-Object { "$($_.id)/$($_.nick)/$($_.profileDir)" }) -join ";") -eq (($before.accounts | ForEach-Object { "$($_.id)/$($_.nick)/$($_.profileDir)" }) -join ";")) $err
    Check "save then load keeps groups, settings, click spots and stats" ((@($after.groups[0].nicks) -join ",") -eq "TestAlt" -and $after.launchSettle -eq 12 -and $after.clickSpots["testalt"] -eq "0.2,0.3" -and $after.statsSecs["testalt"] -eq 120)
    Check "a one-member group stays a list" ((Get-Content $f -Raw) -match '"nicks":\s*\[')

    # ---- everything picked in the app is remembered ----
    $st = New-Defaults
    $st.afkOn = $true; $st.afkMode = "quick"; $st.afkOff = @("testalt"); $st.rbxQuality = 1; $st.rbxFps = 30
    $st.launchSettle = 12; $st.lowPower = $true; $st.winWidth = 1500; $st.winHeight = 900; $st.winMax = $true
    $g = Join-Path $Dir "prefs.json"; Write-SettingsFile $st $g | Out-Null
    $l = (Read-SettingsFile $g).State
    Check "anti-AFK on/off, its mode and each account's AFK tick are kept" ($l.afkOn -and $l.afkMode -eq "quick" -and (@($l.afkOff) -join ",") -eq "testalt")
    Check "performance picks are kept (Roblox quality, frame rate, launch wait, small alts)" ($l.rbxQuality -eq 1 -and $l.rbxFps -eq 30 -and $l.launchSettle -eq 12 -and $l.lowPower)
    Check "the window's size is kept" ($l.winWidth -eq 1500 -and $l.winHeight -eq 900 -and $l.winMax)
    Write-Text $g '{ "accounts": [], "rbxQuality": 42, "rbxFps": 75, "afkOff": [ "", "Alt1", "alt1" ] }'
    $l = (Read-SettingsFile $g).State
    Check "bad graphics picks mean 'not picked'; AFK ticks are cleaned up" ($l.rbxQuality -eq 0 -and $l.rbxFps -eq 0 -and (@($l.afkOff) -join ",") -eq "alt1")
    Write-Text $g '{ "accounts": [] }'
    $l = (Read-SettingsFile $g).State
    Check "older settings files: anti-AFK off, nothing picked, normal window" (-not $l.afkOn -and $l.rbxQuality -eq 0 -and @($l.afkOff).Count -eq 0 -and $l.winWidth -eq 0)

    # ---- sound follows the account; screens follow the account list ----
    $st = New-Defaults
    $mn = New-Account "Main" "P1"; $mn.isMain = $true
    $a1 = New-Account "Alt1" "P2"; $a2 = New-Account "Alt2" "P3"; $a3 = New-Account "Alt3" "P4"
    $st.accounts = @($a1, $mn, $a2, $a3)   # the main isn't first in the list
    $st.soundOff["main"] = $true; $st.soundOff["alt2"] = $true; $st.soundOff["alt3"] = $false
    $st.autoMuteAlts = $true
    Check "the main always opens with sound, even if it was muted before" (-not (Get-AccountMuted $st $mn))
    Check "an alt keeps its own Mute (muted / not muted)" ((Get-AccountMuted $st $a2) -and -not (Get-AccountMuted $st $a3))
    Check "an alt with no choice yet follows 'Mute alts automatically'" ((Get-AccountMuted $st $a1) -and -not (Get-AccountMuted (New-Defaults) $a1))
    Write-SettingsFile $st $g | Out-Null
    $l = (Read-SettingsFile $g).State
    Check "each account's Mute is saved" ($l.soundOff["alt2"] -eq $true -and $l.soundOff["alt3"] -eq $false)
    Set-AccountNick $st $a2 "Farmer"; Remove-AccountRecord $st $a3
    Check "it follows a rename, and goes with a removed account" ($st.soundOff["farmer"] -eq $true -and -not $st.soundOff.ContainsKey("alt2") -and -not $st.soundOff.ContainsKey("alt3"))
    $w = { param($nick, $num, $min) [pscustomobject]@{ Nick = $nick; Num = $num; ProcStart = (Get-Date "2026-10-17 10:00").AddMinutes($min) } }
    $wins = @((& $w "Alt3" 1 0), (& $w "" 2 1), (& $w "Main" 3 5), (& $w "Alt1" 4 2), (& $w "Main" 5 1))
    $st.accounts = @($a1, $mn, $a3)
    $o = @(Get-ScreenOrder $wins $st.accounts)
    Check "screens: main first, then the account list's order, unlinked windows last" ((($o | ForEach-Object { "$($_.Nick)/$($_.Num)" }) -join " ") -eq "Main/5 Main/3 Alt1/4 Alt3/1 /2") (($o | ForEach-Object { "$($_.Nick)/$($_.Num)" }) -join " ")

    # ---- the nickname the "Add account" box suggests ----
    $st = New-Defaults
    Check "the first account is suggested as Main" ((Get-DefaultNick $st) -eq "Main")
    $st.accounts = @((New-Account "Main" "P1"), (New-Account "alt1" "P2"))
    Check "then the first free AltN" ((Get-DefaultNick $st) -eq "Alt2")

    $after.lastLink = "second save"
    $err = Write-SettingsFile $after $f
    Check "saving again keeps the previous version as .bak" (-not $err -and (Test-Path "$f.bak") -and (Read-SettingsFile "$f.bak").State.lastLink -ne "second save" -and (Read-SettingsFile $f).State.lastLink -eq "second save") $err
    Check "no temporary file is left behind" (-not (Test-Path "$f.tmp"))

    $good = Get-Content $f -Raw
    Set-ItemProperty $f -Name IsReadOnly -Value $true
    $after.lastLink = "third save"
    $err = Write-SettingsFile $after $f
    Set-ItemProperty $f -Name IsReadOnly -Value $false
    Check "a save that fails says why" ([bool]$err)
    Check "a save that fails leaves the old file as it was" ((Get-Content $f -Raw) -eq $good)

    # ---- renaming and removing ----
    $f = Join-Path $Dir "rename.json"; Write-Text $f $OldFormat
    $st = (Read-SettingsFile $f).State
    $alt = $st.accounts[1]; $id = $alt.id
    $st.afkOff = @("testalt")
    Set-AccountNick $st $alt "TestFarmer"
    Check "rename keeps its AFK tick" ((@($st.afkOff) -join ",") -eq "testfarmer")
    Check "rename changes the nickname but not the id" ($alt.nick -eq "TestFarmer" -and $alt.id -eq $id)
    Check "rename keeps the account in its groups" ((@($st.groups[0].nicks) -join ",") -eq "TestFarmer")
    Check "rename keeps its click spot and time online" ($st.clickSpots["testfarmer"] -eq "0.2,0.3" -and -not $st.clickSpots.ContainsKey("testalt") -and $st.statsSecs["testfarmer"] -eq 120)
    Write-SettingsFile $st $f | Out-Null
    Check "rename survives saving and loading" ((@((Read-SettingsFile $f).State.groups[0].nicks) -join ",") -eq "TestFarmer")
    Set-AccountNick $st $alt "testfarmer"
    Check "changing only upper/lower case keeps everything" ((@($st.groups[0].nicks) -join ",") -eq "testfarmer" -and $st.clickSpots["testfarmer"] -eq "0.2,0.3")

    Remove-AccountRecord $st $alt
    Check "remove takes the account out of the list and its groups" (@($st.accounts).Count -eq 1 -and @($st.groups[0].nicks).Count -eq 0 -and -not $st.clickSpots.ContainsKey("testfarmer") -and @($st.afkOff).Count -eq 0)
    Check "remove keeps the other accounts and the group itself" ($st.accounts[0].nick -eq "TestMain" -and $st.groups[0].name -eq "Farm")

    # ---- backup and restore ----
    # This PC's Chrome: "Profile 4" exists (called "Test"), RobloxLauncher_TestAlt doesn't.
    $chrome = Join-Path $Dir "Chrome"; New-Item -ItemType Directory -Path (Join-Path $chrome "Profile 4") -Force | Out-Null
    $f = Join-Path $Dir "export-src.json"; Write-Text $f $OldFormat
    $st = (Read-SettingsFile $f).State
    $bk = New-BackupObject $st @{ "Profile 4" = "Test"; "RobloxLauncher_TestAlt" = "TestAlt" }
    $bf = Join-Path $Dir "backup.json"
    [IO.File]::WriteAllText($bf, ($bk | ConvertTo-Json -Depth 6))
    $text = Get-Content $bf -Raw
    Check "a backup leaves out the Discord webhook" ($text -notmatch "secret-token" -and $st.webhook -match "secret-token")
    Check "a backup says what it is and remembers each Chrome profile's name" ($bk.backupFormat -eq "RobloxManager-config" -and $bk.accounts[0].profileName -eq "Test")

    $current = New-Defaults; $current.webhook = "https://discord.com/api/webhooks/2/mine"
    $r = Read-BackupFile $bf $current $chrome @{ "Profile 4" = "Test" }
    Check "restoring a backup brings back accounts, ids and groups" ($r.Ok -and @($r.State.accounts).Count -eq 2 -and $r.State.accounts[0].id -eq $st.accounts[0].id -and (@($r.State.groups[0].nicks) -join ",") -eq "TestAlt")
    Check "restoring keeps this PC's Discord webhook" ($r.State.webhook -eq "https://discord.com/api/webhooks/2/mine")
    Check "an account whose Chrome profile isn't on this PC needs sign-in" ((@($r.NeedSignIn) -join ",") -eq "TestAlt" -and $r.State.accounts[1].needsLogin -and -not $r.State.accounts[0].needsLogin)

    $r = Read-BackupFile $bf $current $chrome @{ "Profile 4" = "Someone else" }
    Check "a profile folder with a different Chrome name is flagged" ((@($r.Warnings) -join " ") -match "Profile 4" -and (@($r.Warnings) -join " ") -match "Someone else")

    $f = Join-Path $Dir "old-backup.json"; Write-Text $f $OldFormat   # backups from the old app are a plain copy of settings.json
    $r = Read-BackupFile $f (New-Defaults) $chrome @{}
    Check "an old-style backup still loads (and its webhook is used if this PC has none)" ($r.Ok -and @($r.State.accounts).Count -eq 2 -and $r.State.webhook -match "secret-token")

    $f = Join-Path $Dir "noprofile.json"; Write-Text $f '{ "accounts": [ { "nick": "New Guy", "profileDir": "" } ] }'
    $r = Read-BackupFile $f (New-Defaults) $chrome @{}
    Check "an account with no profile folder gets a new one and needs sign-in" ($r.Ok -and $r.State.accounts[0].profileDir -eq "RobloxLauncher_NewGuy" -and $r.State.accounts[0].needsLogin)

    $f = Join-Path $Dir "notbackup.json"; Write-Text $f '{ "something": 1 }'
    $r = Read-BackupFile $f $current $chrome @{}
    Check "a JSON file that isn't a backup is refused" ((-not $r.Ok) -and $r.Error)
    $f = Join-Path $Dir "broken.json"; Write-Text $f '{ "accounts": ['
    $r = Read-BackupFile $f $current $chrome @{}
    Check "a broken backup file is refused" ((-not $r.Ok) -and $r.Error)
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_"
}
finally {
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All settings checks passed." })
exit $script:fails
