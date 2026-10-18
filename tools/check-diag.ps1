# Checks BloxKit's diagnostics log (the logger core in BloxKit.ps1): only allow-listed events
# and fields, secrets taken out before anything is queued, a bounded queue, size-limited files,
# and safe behaviour when the disk fails. Uses a pretend disk; one check uses a temp folder.
#     powershell -ExecutionPolicy Bypass -File tools\check-diag.ps1
. (Join-Path $PSScriptRoot "..\BloxKit.ps1") -TestOnly

$script:fails = 0
$ErrorActionPreference = "Stop"
function Check([string]$name, [bool]$ok, [string]$why = "") {
    if (-not $ok) { $script:fails++ }
    "{0}  {1}{2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok -or -not $why) { "" } else { "   ($why)" })
}

# ---- the pretend disk ----
# Files are strings by path. Every call except Now counts as disk work ($D.Calls), so
# "Write-BkLog never touches the disk" can be checked. Fail* make the next calls throw.
$Dir = "C:\fake\logs"; $LogPath = "C:\fake\logs\bloxkit.log"
function New-FakeDisk {
    $script:D = @{ Files = @{}; Calls = 0; Appends = 0; Dirs = @(); FailAppend = $null; FailMove = $null; FailDir = $null; FailWhen = $null; Now = [DateTime]"2026-10-18T12:00:00" }
    @{
        EnsureDir       = { param($d) $script:D.Calls++; Test-Fail "EnsureDir" $d; if ($script:D.FailDir) { throw $script:D.FailDir }; $script:D.Dirs += $d }
        Size            = { param($p) $script:D.Calls++; Test-Fail "Size" $p; if ($script:D.Files.ContainsKey($p)) { [long][Text.Encoding]::UTF8.GetByteCount($script:D.Files[$p]) } else { [long]0 } }
        EndsWithNewline = { param($p) $script:D.Calls++; Test-Fail "EndsWithNewline" $p; $t = "" + $script:D.Files[$p]; ($t -eq "") -or $t.EndsWith("`n") }
        Append          = { param($p, $t) $script:D.Calls++; Test-Fail "Append" $p; if ($script:D.FailAppend) { throw $script:D.FailAppend }; $script:D.Files[$p] = "" + $script:D.Files[$p] + $t; $script:D.Appends++ }
        Move            = { param($a, $b) $script:D.Calls++; Test-Fail "Move" $a $b; if ($script:D.FailMove) { throw $script:D.FailMove }; $script:D.Files[$b] = $script:D.Files[$a]; [void]$script:D.Files.Remove($a) }
        Delete          = { param($p) $script:D.Calls++; Test-Fail "Delete" $p; [void]$script:D.Files.Remove($p) }
        Exists          = { param($p) $script:D.Calls++; $script:D.Files.ContainsKey($p) }
        Now             = { $script:D.Now }
    }
}
# FailWhen: { param($op, $a, $b) ... } returns an exception to throw for that one call (or nothing).
function Test-Fail([string]$op, $a, $b) { if ($script:D.FailWhen) { $x = & $script:D.FailWhen $op $a $b; if ($x) { throw $x } } }
function Lines([string]$p = $LogPath) { @(("" + $D.Files[$p]) -split "`n" | Where-Object { $_ -ne "" }) }
function Parse([string]$line) { try { $line | ConvertFrom-Json } catch { $null } }

try {
    # ---- 1. JSON Lines and metadata ----
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Check "the log file is bloxkit.log in the logs folder" ($log.Path -eq $LogPath) $log.Path
    Write-BkLog $log "app.start" @{ version = "1.3.0"; host = "exe"; accounts = 3; testMode = $false; scriptWritten = [DateTime]"2026-10-18T06:11:37" }
    Write-BkLog $log "app.stop" @{ reason = "exit"; uptimeSec = 42 }
    Flush-BkLog $log
    $l = @(Lines)
    Check "two events, two lines" ($l.Count -eq 2) "$($l.Count) lines"
    $a = Parse $l[0]; $b = Parse $l[1]
    Check "every line is valid JSON" ($null -ne $a -and $null -ne $b)
    Check "metadata: time with offset, session, sequence, level, event" ($a.t -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d$' -and $a.s -match '^[0-9a-f]{8}$' -and $a.n -eq 1 -and $a.lvl -eq "info" -and $a.ev -eq "app.start") $l[0]
    Check "the session id stays the same and the sequence counts up" ($b.s -eq $a.s -and $b.n -eq 2)
    Check "fields keep their types (number, true/false, text, time)" ($a.accounts -is [int] -and $a.testMode -eq $false -and $a.version -eq "1.3.0" -and $a.host -eq "exe" -and $a.scriptWritten -match '^2026-10-18T06:11:37') $l[0]
    Check "the file is plain ASCII (other characters are escaped)" (-not ($D.Files[$LogPath] -match '[^\x09\x0A\x0D\x20-\x7E]'))
    $log2 = New-BkLog $Dir (New-FakeDisk)
    Check "a new run gets a new session id" ($log2.Session -ne $log.Session)

    # ---- 2. only allow-listed events, fields, types and choices ----
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Write-BkLog $log "app.hacked" @{ version = "1.3.0" }
    Flush-BkLog $log
    $l = @(@(Lines) | ForEach-Object { Parse $_ })
    Check "an unknown event is never written; it is counted and reported as rejected" (@($l | Where-Object { $_.ev -eq "app.hacked" }).Count -eq 0 -and @($l | Where-Object { $_.ev -eq "log.dropped" -and $_.rejected -eq 1 }).Count -eq 1 -and $log.Rejected -ge 1) "rejected=$($log.Rejected)"
    Write-BkLog $log "app.start" @{ version = "1.3.0"; password = "hunter2"; cookie = "abc"; Version2 = "x" }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    Check "unknown fields are never written" ($x.version -eq "1.3.0" -and -not ($D.Files[$LogPath] -match 'hunter2|password|cookie|Version2'))
    Write-BkLog $log "app.start" @{ accounts = "3"; testMode = "true"; host = "linux"; version = "1.3.0; del"; scriptWritten = "yesterday"; screensRestored = 2.5 }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    $bad = @("accounts", "testMode", "host", "version", "scriptWritten", "screensRestored") | Where-Object { $null -ne $x.$_ }
    Check "wrong types and choices are dropped: text for a number, text for true/false, an unlisted choice, a bad version, a bad time, a fraction" ($bad.Count -eq 0) ("kept: " + ($bad -join ","))
    Write-BkLog $log "app.start" @{ accounts = [long]5; screensRestored = [double]2 }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    Check "whole numbers of any integer type are kept" ($x.accounts -eq 5 -and $x.screensRestored -eq 2)
    Write-BkLog $log "app.start" @{ accounts = [double]::NaN; screensRestored = [double]::PositiveInfinity }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    Check "NaN and infinity are dropped" ($null -eq $x.accounts -and $null -eq $x.screensRestored)
    Write-BkLog $log "app.stop" @{}
    Write-BkLog $log "app.stop" $null
    Write-BkLog $log "app.stop" "not a table"
    Write-BkLog $log "app.stop" @{ reason = $null; uptimeSec = $null }
    Flush-BkLog $log; $l = @(Lines)
    Check "missing, empty and malformed field sets still give a valid line with just the metadata" (@($l[-4..-1] | Where-Object { $p = Parse $_; $p -and $p.ev -eq "app.stop" -and $null -eq $p.reason }).Count -eq 4)
    Write-BkLog $log "app.error" @{ area = "general"; type = ("X" * 500); function = ("f" * 65); message = ("word " * 30000) }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    Check "oversized values: a too-long name is dropped, a huge text is cut to 300 characters" ($null -eq $x.type -and $null -eq $x.function -and $null -ne $x.message -and $x.message.Length -le 300) "message length $($x.message.Length)"
    Write-BkLog $log "app.error" @{ area = "general"; message = "Say `"hi`" with`ttabs`r`nand lines caf" + [char]0x00E9 + [char]0x2028 }
    Flush-BkLog $log; $raw = @(Lines)[-1]; $x = Parse $raw
    Check "quotes, tabs, newlines and other characters stay one valid ASCII line" ($null -ne $x -and $x.message -match '^Say "hi" with tabs and lines caf' -and $raw -notmatch '[^\x20-\x7E]') $raw

    # ---- 3/4. secrets never reach the log ----
    # Each sentinel has a core that must never appear anywhere in what's written.
    $Hook = "https://discord.com/api/webhooks/123456789012345678/ZzHookCoreToken_abcdefXYZ"
    $Nick = "Zqxnick"; $ProfileDir = "RobloxLauncher_Zqxnick"; $WinUser = "zqxuser"
    $Sentinels = [ordered]@{
        "Discord webhook"          = @{ Text = "posting to $Hook failed"; Core = "ZzHookCoreToken" }
        "account nickname"         = @{ Text = "account $Nick didn't load"; Core = "Zqxnick" }
        "Chrome profile folder"    = @{ Text = "profile $ProfileDir is missing"; Core = "Zqxnick" }
        "profile link (user id)"   = @{ Text = "joining https://www.roblox.com/users/987654321/profile now"; Core = "987654321" }
        "private-server code"      = @{ Text = "link https://www.roblox.com/games/1/x?privateServerLinkCode=PrivCoreCode7777 broke"; Core = "PrivCoreCode7777" }
        "share-link code"          = @{ Text = "open roblox.com/share?code=ShareCoreCode55&type=Server please"; Core = "ShareCoreCode55" }
        "private code pair"        = @{ Text = "the privateServerLinkCode=PairCoreCode42 was refused"; Core = "PairCoreCode42" }
        "Roblox cookie"            = @{ Text = "got _|WARNING:-DO-NOT-SHARE-THIS.--Sharing-this-will-allow-someone-to-log-in-as-you-and-to-steal-your-ROBUX-and-items.|_CookieCoreValue123 back"; Core = "CookieCoreValue123" }
        ".ROBLOSECURITY cookie"    = @{ Text = "header .ROBLOSECURITY=RoSecCoreValue9; path=/"; Core = "RoSecCoreValue9" }
        "login ticket (URI)"       = @{ Text = "started roblox-player:1+launchmode:play+gameinfo:TicketCoreABC+launchtime:1"; Core = "TicketCoreABC" }
        "login ticket (gameinfo)"  = @{ Text = "args gameinfo:GameinfoCoreXYZ next"; Core = "GameinfoCoreXYZ" }
        "Authorization header"     = @{ Text = "sent Authorization: Bearer AuthCoreTokenQQ to the server"; Core = "AuthCoreTokenQQ" }
        "bearer token"             = @{ Text = "token was bearer BearerCoreRR"; Core = "BearerCoreRR" }
        "password"                 = @{ Text = "login failed password=PassCore!x for them"; Core = "PassCore" }
        "API key"                  = @{ Text = "use api_key: ApiCoreKey1 here"; Core = "ApiCoreKey1" }
        "session value"            = @{ Text = "the sessionid=SessCoreVal is old"; Core = "SessCoreVal" }
        "Windows user path"        = @{ Text = "Could not find file 'C:\Users\$WinUser\AppData\Roaming\RobloxMultiLauncher\settings.json'."; Core = "zqxuser" }
        "UNC path"                 = @{ Text = "cannot open \\fileserver\share\UncCore.txt"; Core = "UncCore" }
        "IP address"               = @{ Text = "server 203.0.113.77 refused"; Core = "203.0.113.77" }
        "email address"            = @{ Text = "contact zqxmail@example.com now"; Core = "zqxmail" }
        "raw command line"         = @{ Text = "RobloxPlayerBeta.exe --app -t CmdCoreTok --play"; Core = "CmdCoreTok" }
        "environment dump"         = @{ Text = "PATH=C:\Windows;C:\Tools LOCALAPPDATA=C:\Users\EnvCoreUser\AppData\Local"; Core = "EnvCoreUser" }
        "complete URL"             = @{ Text = "fetch https://example.org/some/UrlCorePath?x=1 failed"; Core = "UrlCorePath" }
        "long token"               = @{ Text = "token abcDEF0123456789abcDEF0123456789LongCore end"; Core = "LongCore" }
        "URL-encoded webhook"      = @{ Text = "body url=https%3A%2F%2Fdiscord.com%2Fapi%2Fwebhooks%2F1%2FEncCoreHook"; Core = "EncCoreHook" }
        "double-encoded link"      = @{ Text = "x https%253A%252F%252Fwww.roblox.com%252Fgames%252F1%253FprivateServerLinkCode%253DDblCore99"; Core = "DblCore99" }
        "JSON-escaped webhook"     = @{ Text = 'json "https:\/\/discord.com\/api\/webhooks\/1\/JsonEscCore"'; Core = "JsonEscCore" }
        "base64 cookie"            = @{ Text = "blob " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("_|WARNING:-DO-NOT-SHARE-THIS.|_B64CoreCookie")); Core = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("_|WARNING:-DO-NOT-SHARE-THIS.|_B64CoreCookie")).Substring(8, 20) }
        "spaced-out password"      = @{ Text = "password" + [char]0x00A0 + "=" + [char]0x2003 + "SpacedCore"; Core = "SpacedCore" }
        "zero-width in keyword"    = @{ Text = "pass" + [char]0x200B + "word=ZwCoreSecret"; Core = "ZwCoreSecret" }
        "newline before secret"    = @{ Text = "token`r`n=`tNlCoreToken"; Core = "NlCoreToken" }
        "nickname in other case"   = @{ Text = "ZQXNICK went away"; Core = "ZQXNICK" }
    }
    $Known = @($Hook, $Nick, $ProfileDir, $WinUser, "https://www.roblox.com/users/987654321/profile")
    function New-SecretLog { $l = New-BkLog $Dir (New-FakeDisk); Set-BkLogSecrets $l $Known; $l }
    function Test-Clean([string]$bytes) { @($Sentinels.Values | Where-Object { $bytes.IndexOf($_.Core, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { $_.Core }) }
    foreach ($k in $Sentinels.Keys) {
        $log = New-SecretLog
        Write-BkLog $log "app.error" @{ area = "general"; type = "System.Exception"; message = $Sentinels[$k].Text }
        $queued = ($log.Queue | ForEach-Object { $_.Line }) -join "`n"
        Flush-BkLog $log
        $leak = @(Test-Clean ($queued + $D.Files[$LogPath]))
        Check "redaction: $k never reaches the queue or the file" ($leak.Count -eq 0 -and $null -ne (Parse @(Lines)[-1])) ("leaked: " + ($leak -join ","))
    }
    $log = New-SecretLog
    Write-BkLog $log "app.error" @{ area = "general"; message = "Exception calling Refresh with 0 arguments: Object reference not set to an instance of an object." }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    Check "a plain error message with nothing private in it is kept" ($x.message -match '^Exception calling Refresh') "$($x.message)"
    $log = New-SecretLog
    Write-BkLog $log "app.error" @{ area = "general"; message = 'Exception calling "ReadAllText" with "1" argument(s): "Could not find a part of the path ''C:\Users\zqxuser\a.txt''."' }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    Check "PowerShell's usual error shape keeps its words; only the path inside it is replaced" ($x.message -match '^Exception calling "ReadAllText" with "1" argument\(s\): ' -and $x.message -match '\[path\]' -and $x.message -notmatch 'zqxuser') "$($x.message)"
    $log = New-SecretLog
    Write-BkLog $log "app.error" @{ area = "general"; message = "Could not find file 'C:\Program Files\x.txt'." }
    Flush-BkLog $log; $x = Parse @(Lines)[-1]
    Check "a file path is replaced by [path] (never written as it was)" ($x.message -notmatch 'Program Files' -and $x.message -match '\[path\]') "$($x.message)"
    $log = New-SecretLog
    Write-BkLog $log "app.error" @{ area = "general"; message = "Could not reach https://example.org/some/UrlCorePath?x=1 in time" }
    Write-BkLog $log "app.error" @{ area = "general"; message = "Cannot%20open%20the%20window" }
    Flush-BkLog $log; $l = @(Lines)
    Check "a message with a link is kept, with the link cut down to its host" ((Parse $l[0]).message -eq "Could not reach [url:example.org] in time") "$((Parse $l[0]).message)"
    Check "a URL-encoded but harmless message is kept, decoded" ((Parse $l[1]).message -eq "Cannot open the window") "$((Parse $l[1]).message)"
    foreach ($area in "settings", "backup", "json") {
        $log = New-SecretLog
        Write-BkLog $log "app.error" @{ area = $area; type = "System.ArgumentException"; message = "Invalid primitive near harmless words" }
        Flush-BkLog $log; $x = Parse @(Lines)[-1]
        Check "a $area error never has its message written (type kept)" ($null -eq $x.message -and $x.type -eq "System.ArgumentException" -and $x.area -eq $area)
    }
    $log = New-SecretLog
    Write-BkLog $log "app.error" @{ area = "general"; type = "System.Text.Json.JsonException"; message = "harmless words only" }
    Write-BkLog $log "app.error" @{ area = "general"; type = "System.ArgumentException"; message = "Conversion from JSON failed with error: unexpected character" }
    Flush-BkLog $log; $l = @(Lines)
    Check "a JSON error (by its type, or by its message) never has its message written" ($null -eq (Parse $l[0]).message -and $null -eq (Parse $l[1]).message)
    $log = New-SecretLog
    Write-BkLog $log "app.error" @{ area = "general"; type = $Nick; function = "Do-$Nick" }
    Write-BkLog $log "update.check" @{ result = "failed"; errorType = $WinUser }
    Flush-BkLog $log
    Check "a name field that holds one of your names is dropped" ((Test-Clean $D.Files[$LogPath]).Count -eq 0 -and $null -eq (Parse @(Lines)[0]).type)
    $log = New-SecretLog; $log2 = New-SecretLog
    $al = Get-BkLogAlias $log "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    Check "an account alias looks like acc-xxxxxx and stays the same within a run" ($al -cmatch '^acc-[0-9a-f]{6}$' -and (Get-BkLogAlias $log "1b4e28ba-2fa1-11d2-883f-0016d3cca427") -eq $al) $al
    Check "the same account gets a different alias in another run" ((Get-BkLogAlias $log2 "1b4e28ba-2fa1-11d2-883f-0016d3cca427") -ne $al)
    Write-BkLog $log "screen.add" @{ account = $al; screen = 1 }
    Write-BkLog $log "screen.add" @{ account = "acc-ZZZZZZ"; screen = 2 }
    Write-BkLog $log "screen.add" @{ account = $Nick; screen = 3 }
    Flush-BkLog $log; $l = @(@(Lines) | Where-Object { $_ -match "screen.add" })
    Check "an alias field only takes a real alias (not a name, not a malformed one)" ((Parse $l[0]).account -eq $al -and $null -eq (Parse $l[1]).account -and $null -eq (Parse $l[2]).account)

    # ---- 6. every field of every event, filled with secrets ----
    $log = New-SecretLog
    $all = @($Sentinels.Values | ForEach-Object { $_.Text })
    foreach ($ev in $BkLogSchema.Keys) {
        foreach ($s in $all) {
            $f = @{}; foreach ($name in $BkLogSchema[$ev].Fields.Keys) { $f[$name] = $s }
            Write-BkLog $log $ev $f
        }
        Flush-BkLog $log
    }
    $leak = @(Test-Clean $D.Files[$LogPath])
    $badLines = @(@(Lines) | Where-Object { $null -eq (Parse $_) }).Count
    Check "sweep: $($BkLogSchema.Count) events x every field x $($all.Count) secrets, nothing leaks, every line is valid JSON" ($leak.Count -eq 0 -and $badLines -eq 0 -and @(Lines).Count -gt 0) ("leaked: " + ($leak -join ",") + "; bad lines: $badLines")

    # ---- 7. random mixes ----
    $rng = New-Object System.Random 2468
    $noise = @("failed", "while", "opening", "the", "window", "Roblox", "at", "12:00", "error", "(", ")", ":", "-", "...", "'", '"', "`t", "`n", [string][char]0x00A0, [string][char]0x200B)
    $log = New-SecretLog; $bad = 0; $first = ""
    for ($i = 0; $i -lt 400; $i++) {
        $parts = @(); for ($j = 0; $j -lt $rng.Next(1, 8); $j++) { $parts += $(if ($rng.NextDouble() -lt 0.5) { $all[$rng.Next(0, $all.Count)] } else { $noise[$rng.Next(0, $noise.Count)] }) }
        $txt = $parts -join $(if ($rng.NextDouble() -lt 0.5) { " " } else { "" })
        if ($rng.NextDouble() -lt 0.2) { $txt = [Uri]::EscapeDataString($txt) }
        if ($rng.NextDouble() -lt 0.1) { $txt = $txt.ToUpperInvariant() }
        Write-BkLog $log "app.error" @{ area = "general"; message = $txt; type = $(if ($rng.NextDouble() -lt 0.3) { $Nick } else { "System.Exception" }) }
        Flush-BkLog $log
        $raw = @(Lines)[-1]
        $leak = @(Test-Clean $raw)
        if ($leak.Count -or $null -eq (Parse $raw)) { $bad++; if (-not $first) { $first = "round ${i}: leaked $($leak -join ',') in $raw" } }
    }
    Check "random mixes, 400 rounds (secrets with noise, joined, URL-encoded, upper-cased): nothing leaks, every line valid" ($bad -eq 0) $first

    # ---- 12. writing an event never touches the disk; only Flush-BkLog does ----
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    for ($i = 0; $i -lt 1000; $i++) { Write-BkLog $log "afk.round" @{ trigger = "timer"; sent = $i } }
    Check "1000 events written, no disk work at all (safe in the middle of anti-AFK)" ($D.Calls -eq 0 -and $D.Appends -eq 0) "$($D.Calls) disk calls"
    $out = @(Write-BkLog $log "afk.round" @{ sent = 1 })
    Check "writing an event outputs nothing" ($out.Count -eq 0)
    $out = @(Flush-BkLog $log)
    Check "flushing writes, and outputs nothing" ($D.Appends -ge 1 -and $out.Count -eq 0)

    # ---- 11. a full queue keeps warnings and errors ----
    function Fill($log, [string]$ev, [int]$n, [string]$tag) { for ($i = 0; $i -lt $n; $i++) { $f = @{ count = $i }; if ($ev -eq "app.error") { $f = @{ line = $i } }; if ($ev -eq "afk.round") { $f = @{ sent = $i } }; if ($ev -eq "afk.stuck") { $f = @{ why = "refused" } }; Write-BkLog $log $ev $f } }
    function Queued($log, [string]$ev) { @($log.Queue | Where-Object { $_.Line -match ('"ev":"' + [regex]::Escape($ev) + '"') }).Count }
    $log = New-BkLog $Dir (New-FakeDisk)
    Fill $log "afk.round" 500 ""
    Fill $log "afk.stuck" 10 ""; Fill $log "app.error" 5 ""
    Check "queue full of routine events: 15 warnings/errors still get in, the oldest routine ones make room" ($log.Queue.Count -eq 500 -and (Queued $log "afk.stuck") -eq 10 -and (Queued $log "app.error") -eq 5 -and $log.Dropped -eq 15) "count $($log.Queue.Count), dropped $($log.Dropped)"
    Check "the routine events that made room were the oldest" ($log.Queue[0].Line -match '"sent":15[,}]')
    $log = New-BkLog $Dir (New-FakeDisk)
    Fill $log "afk.round" 501 ""
    Check "queue full of routine events: a new one replaces the oldest" ($log.Queue.Count -eq 500 -and $log.Queue[499].Line -match '"sent":500[,}]' -and $log.Queue[0].Line -match '"sent":1[,}]' -and $log.Dropped -eq 1)
    $log = New-BkLog $Dir (New-FakeDisk)
    Fill $log "afk.stuck" 500 ""
    Write-BkLog $log "afk.round" @{ sent = 7 }
    Check "queue full of warnings: a routine event is the one dropped" ($log.Queue.Count -eq 500 -and (Queued $log "afk.round") -eq 0 -and $log.Dropped -eq 1)
    Write-BkLog $log "app.error" @{ line = 99 }
    Check "queue full of warnings: an error gets in, the oldest warning makes room" ($log.Queue.Count -eq 500 -and (Queued $log "app.error") -eq 1 -and $log.Dropped -eq 2)
    $log = New-BkLog $Dir (New-FakeDisk)
    Fill $log "app.error" 501 ""
    Check "queue full of errors: the newest error is kept, the oldest goes" ($log.Queue.Count -eq 500 -and $log.Queue[499].Line -match '"line":500[,}]' -and $log.Queue[0].Line -match '"line":1[,}]')

    # ---- 9. dropped and rejected events are counted, and reported in the log ----
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Fill $log "afk.round" 503 ""
    Write-BkLog $log "nope" @{}
    Write-BkLog $log "afk.round" @{ bogus = 1 }
    Flush-BkLog $log
    $dl = @(@(Lines) | ForEach-Object { Parse $_ } | Where-Object { $_.ev -eq "log.dropped" })
    Check "the next flush writes a log.dropped line with how many were dropped and rejected" ($dl.Count -eq 1 -and $dl[0].count -eq 4 -and $dl[0].rejected -eq 2 -and $dl[0].lvl -eq "warn") ("found: " + ($dl | ConvertTo-Json -Compress))
    Write-BkLog $log "afk.round" @{ sent = 1 }
    Flush-BkLog $log
    Check "the counts are reported once, not again on the next flush" (@(@(Lines) | ForEach-Object { Parse $_ } | Where-Object { $_.ev -eq "log.dropped" }).Count -eq 1)

    # ---- 10. the files: folder, a cut-off last line, rotation ----
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Flush-BkLog $log
    Check "nothing queued: a flush does no disk work" ($D.Calls -eq 0)
    Write-BkLog $log "afk.round" @{ sent = 1 }; Flush-BkLog $log
    Check "the logs folder is made when needed, before writing" ($D.Dirs -contains $Dir -and $D.Appends -eq 1) ($D.Dirs -join ",")
    $port = New-FakeDisk; $D.Files[$LogPath] = '{"t":"2026-10-17T23:59:59.000+08:00","s":"aaaaaaaa","n":1,"lvl":"info","ev":"afk.ro'
    $log = New-BkLog $Dir $port
    Write-BkLog $log "afk.round" @{ sent = 1 }; Write-BkLog $log "afk.round" @{ sent = 2 }; Flush-BkLog $log
    $l = @(Lines)
    Check "a last line cut off by a crash stays as it was, and the new lines start on a line of their own" ($l.Count -eq 3 -and $null -eq (Parse $l[0]) -and $null -ne (Parse $l[1]) -and $null -ne (Parse $l[2]))
    $port = New-FakeDisk; $log = New-BkLog $Dir $port 2000
    for ($i = 1; $i -le 120; $i++) { Write-BkLog $log "afk.round" @{ trigger = "timer"; sent = $i }; if ($i % 10 -eq 0) { Flush-BkLog $log } }
    $names = @($D.Files.Keys | Sort-Object)
    $sizes = @($D.Files.Keys | ForEach-Object { [Text.Encoding]::UTF8.GetByteCount($D.Files[$_]) })
    $total = ($sizes | Measure-Object -Sum).Sum
    Check "rotation keeps 4 files at most: bloxkit.log and .1 to .3" (($names -join ",") -eq "$LogPath,$LogPath.1,$LogPath.2,$LogPath.3") ($names -join ",")
    Check "no file is bigger than the limit, and all of them together stay under 4 x the limit" (@($sizes | Where-Object { $_ -gt 2000 }).Count -eq 0 -and $total -le 8000) "sizes $($sizes -join ',')"
    $seq = { param($p) @(Lines $p | ForEach-Object { (Parse $_).sent }) }
    $s3 = & $seq "$LogPath.3"; $s2 = & $seq "$LogPath.2"; $s1 = & $seq "$LogPath.1"; $s0 = & $seq $LogPath
    Check "the newest events are in bloxkit.log, older ones in .1, .2, .3 (in order, none twice)" ($s3[-1] -lt $s2[0] -and $s2[-1] -lt $s1[0] -and $s1[-1] -lt $s0[0] -and $s0[-1] -eq 120 -and (@($s3 + $s2 + $s1 + $s0) | Select-Object -Unique).Count -eq ($s3.Count + $s2.Count + $s1.Count + $s0.Count))
    Check "every line in every file is valid JSON" (@($D.Files.Keys | ForEach-Object { Lines $_ } | Where-Object { $null -eq (Parse $_) }).Count -eq 0)

    $port = New-FakeDisk; $log = New-BkLog $Dir $port 200
    Write-BkLog $log "app.error" @{ area = "general"; message = ("long words " * 40) }
    Flush-BkLog $log; Flush-BkLog $log
    Write-BkLog $log "afk.round" @{ sent = 5 }; Flush-BkLog $log
    $l = @($D.Files.Keys | ForEach-Object { Lines $_ } | ForEach-Object { Parse $_ })
    Check "a single event bigger than the file limit is dropped once (not again every flush) and reported" ($log.Queue.Count -eq 0 -and $log.Dropped -eq 1 -and @($l | Where-Object { $_.ev -eq "log.dropped" -and $_.count -eq 1 }).Count -eq 1 -and @($l | Where-Object { $_.ev -eq "afk.round" }).Count -eq 1) "queued $($log.Queue.Count), dropped $($log.Dropped)"

    # ---- 8/13. when the disk fails ----
    $Locked = New-Object System.IO.IOException ("The process cannot access the file 'C:\Users\$WinUser\x' because it is being used by another process. ZzHookCoreToken", -2147024864)
    $Full   = New-Object System.IO.IOException ("There is not enough space on the disk. ZzHookCoreToken", -2147024784)
    $Denied = New-Object System.UnauthorizedAccessException ("Access to the path 'C:\Users\$WinUser\logs' is denied. ZzHookCoreToken")
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; Set-BkLogSecrets $log $Known
    Write-BkLog $log "afk.round" @{ sent = 1 }; Write-BkLog $log "afk.round" @{ sent = 2 }
    $D.FailAppend = $Locked
    $out = @(Flush-BkLog $log)
    Check "file in use: the flush fails quietly (nothing thrown, nothing output), the events stay queued" ($out.Count -eq 0 -and $log.Queue.Count -eq 2 -and $log.Failures -eq 1 -and -not $log.Off)
    $calls = $D.Calls; $D.Now = $D.Now.AddSeconds(30); Flush-BkLog $log
    Check "after a failure it waits: no disk work for a minute" ($D.Calls -eq $calls)
    $D.FailAppend = $null; $D.Now = $D.Now.AddSeconds(31); Flush-BkLog $log
    Check "after the minute it tries again, writes everything once, and the failure count resets" (@(Lines).Count -eq 2 -and $log.Queue.Count -eq 0 -and $log.Failures -eq 0)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; Set-BkLogSecrets $log $Known
    $D.FailAppend = $Full
    for ($k = 0; $k -lt 3; $k++) { Write-BkLog $log "afk.round" @{ sent = $k }; Flush-BkLog $log; $D.Now = $D.Now.AddSeconds(61) }
    Check "disk full three times in a row: the log turns off for this run, and says why in words" ($log.Off -and $log.Notice -match 'disk is full' -and $log.Queue.Count -eq 0) $log.Notice
    Check "the notice never holds the raw error (no path, no secret)" ($log.Notice -notmatch 'zqxuser|ZzHookCoreToken|\\|:\\')
    $calls = $D.Calls; $q = $log.Dropped
    Write-BkLog $log "app.error" @{ line = 1 }; Flush-BkLog $log
    Check "once off: events are only counted, nothing touches the disk" ($D.Calls -eq $calls -and $log.Dropped -eq $q + 1 -and $log.Queue.Count -eq 0)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $D.FailDir = $Denied
    Write-BkLog $log "afk.round" @{ sent = 1 }; Flush-BkLog $log
    Check "no permission for the logs folder: fails quietly, events kept" ($log.Failures -eq 1 -and $log.Queue.Count -eq 1)
    for ($k = 0; $k -lt 2; $k++) { $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log }
    Check "no permission three times: off, with a reason in words" ($log.Off -and $log.Notice -match 'permission' -and $log.Notice -notmatch 'zqxuser|ZzHook') $log.Notice
    $port = New-FakeDisk; $log = New-BkLog $Dir $port 600
    for ($i = 1; $i -le 6; $i++) { Write-BkLog $log "afk.round" @{ trigger = "timer"; sent = $i } }
    Flush-BkLog $log
    for ($i = 7; $i -le 12; $i++) { Write-BkLog $log "afk.round" @{ trigger = "timer"; sent = $i } }
    $D.FailMove = $Locked; $before = [Text.Encoding]::UTF8.GetByteCount($D.Files[$LogPath]); Flush-BkLog $log
    $after = [Text.Encoding]::UTF8.GetByteCount($D.Files[$LogPath])
    Check "rotation fails (file in use): never writes past the size limit, keeps what it couldn't write" ($after -le 600 -and $log.Failures -eq 1 -and $log.Queue.Count -ge 1) "before $before after $after queued $($log.Queue.Count)"
    $D.FailMove = $null; $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log
    $everything = @($D.Files.Keys | ForEach-Object { Lines $_ } | ForEach-Object { (Parse $_).sent } | Where-Object { $_ })
    Check "after the rotation works again, every event is in the files exactly once" ((@($everything | Sort-Object) -join ",") -eq "1,2,3,4,5,6,7,8,9,10,11,12" -and $log.Queue.Count -eq 0) ($everything -join ",")
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    $script:partial = $true
    $port.Append = { param($p, $t) $script:D.Calls++; if ($script:partial) { $script:partial = $false; $script:D.Files[$p] = "" + $script:D.Files[$p] + $t.Substring(0, 30); throw $Full }; $script:D.Files[$p] = "" + $script:D.Files[$p] + $t }
    Write-BkLog $log "afk.round" @{ sent = 1 }; Flush-BkLog $log
    $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log
    $l = @(Lines)
    Check "a write cut off half-way (disk full): the retry starts on a new line, so it stays readable" ($l.Count -eq 2 -and $null -eq (Parse $l[0]) -and (Parse $l[1]).sent -eq 1)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    foreach ($k in @($port.Keys)) { $port[$k] = { throw $Locked } }
    $err = $null
    try { Write-BkLog $log "afk.round" @{ sent = 1 }; Write-BkLog $log "app.error" @{ line = 2 }; Flush-BkLog $log; Flush-BkLog $log; Flush-BkLog $log } catch { $err = $_ }
    Check "every disk call throwing (even the clock): nothing is ever thrown to the app" ($null -eq $err) "$err"
    Check "a failing logger never logs about itself (no recursion)" (@($log.Queue | Where-Object { $_.Line -match 'log\.' }).Count -eq 0)

    # ==== pre-integration audit ====
    # -- every single disk operation failing on its own, during a flush that has to rotate --
    # Setup: 600-byte files, all four already there and bloxkit.log nearly full; then 8 new events
    # (about 800 bytes, so the flush has to rotate). One operation fails once; after the minute,
    # a second flush must finish the job: every new event exactly once, the caps always held.
    function New-FullDisk {
        $port = New-FakeDisk; $l = New-BkLog $Dir $port 600
        for ($i = 1; $i -le 30; $i++) { Write-BkLog $l "afk.round" @{ trigger = "timer"; sent = $i }; Flush-BkLog $l }
        return $l
    }
    function Get-Caps { $f = @($D.Files.Keys); $sz = @($f | ForEach-Object { [Text.Encoding]::UTF8.GetByteCount($D.Files[$_]) }); @{ Files = $f.Count; Max = ($sz | Measure-Object -Maximum).Maximum; Total = ($sz | Measure-Object -Sum).Sum; Names = (@($f | Where-Object { $_ -notmatch '^C:\\fake\\logs\\bloxkit\.log(\.[1-3])?$' }).Count -eq 0) } }
    $Boom = New-Object System.IO.IOException ("simulated failure", -2147024864)
    $ops = [ordered]@{
        "deleting the oldest file (.3)"   = { param($op, $a, $b) if ($op -eq "Delete" -and "$a" -like "*.log.3") { $Boom } }
        "renaming .2 to .3"               = { param($op, $a, $b) if ($op -eq "Move" -and "$a" -like "*.log.2") { $Boom } }
        "renaming .1 to .2"               = { param($op, $a, $b) if ($op -eq "Move" -and "$a" -like "*.log.1") { $Boom } }
        "renaming bloxkit.log to .1"      = { param($op, $a, $b) if ($op -eq "Move" -and "$a" -like "*.log") { $Boom } }
        "appending after the rotation"    = { param($op, $a, $b) if ($op -eq "Append") { $Boom } }
        "reading the file size"           = { param($op, $a, $b) if ($op -eq "Size") { $Boom } }
        "making the logs folder"          = { param($op, $a, $b) if ($op -eq "EnsureDir") { $Boom } }
    }
    foreach ($name in $ops.Keys) {
        $log = New-FullDisk
        for ($i = 101; $i -le 108; $i++) { Write-BkLog $log "afk.round" @{ trigger = "timer"; sent = $i } }
        $script:once = $ops[$name]
        $D.FailWhen = { param($op, $a, $b) $x = & $script:once $op $a $b; if ($x) { $script:once = { param($o, $a2, $b2) } }; $x }
        $err = $null; try { Flush-BkLog $log } catch { $err = $_ }
        $c1 = Get-Caps
        $D.FailWhen = $null; $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log
        $c2 = Get-Caps
        $sent = @($D.Files.Keys | ForEach-Object { Lines $_ } | ForEach-Object { (Parse $_).sent } | Where-Object { $_ -ge 101 })
        $ok = ($null -eq $err) -and $log.Failures -eq 0 -and $log.Queue.Count -eq 0 -and ((@($sent | Sort-Object) -join ",") -eq "101,102,103,104,105,106,107,108") -and
              $c1.Names -and $c2.Names -and $c1.Files -le 4 -and $c2.Files -le 4 -and $c1.Max -le 600 -and $c2.Max -le 600 -and $c1.Total -le 2400 -and $c2.Total -le 2400
        Check "fails once while $name`: nothing thrown, caps held during and after, every new event written exactly once after the retry" $ok "err=$err sent=$($sent -join ',') files=$($c1.Files)/$($c2.Files) max=$($c1.Max)/$($c2.Max)"
    }
    # the check for a cut-off last line can fail too (only done on the first write of a run)
    $port = New-FakeDisk; $D.Files[$LogPath] = '{"cut off'
    $log = New-BkLog $Dir $port
    Write-BkLog $log "afk.round" @{ sent = 1 }
    $D.FailWhen = { param($op, $a, $b) if ($op -eq "EndsWithNewline") { $Boom } }
    $err = $null; try { Flush-BkLog $log } catch { $err = $_ }
    $D.FailWhen = $null; $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log
    $l = @(Lines)
    Check "checking the cut-off last line fails once: nothing thrown, and the retry still starts on its own line" ($null -eq $err -and $l.Count -eq 2 -and (Parse $l[1]).sent -eq 1)

    # -- a write that stops part-way (disk full) after whole lines already went in --
    # Narrowed guarantee: no event is lost, but lines that were already complete can be written a
    # second time by the retry. Every copy is byte-for-byte the same (same session and sequence
    # number), so a reader can drop repeats.
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    for ($i = 1; $i -le 4; $i++) { Write-BkLog $log "afk.round" @{ sent = $i } }
    $script:cut = $true
    $port.Append = { param($p, $t) $script:D.Calls++; if ($script:cut) { $script:cut = $false; $nl = $t.IndexOf("`n", $t.IndexOf("`n") + 1); $script:D.Files[$p] = "" + $script:D.Files[$p] + $t.Substring(0, $nl + 20); throw $Full }; $script:D.Files[$p] = "" + $script:D.Files[$p] + $t }
    Flush-BkLog $log; $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log
    $parsed = @(@(Lines) | ForEach-Object { Parse $_ } | Where-Object { $_ })
    $byN = $parsed | Group-Object { "$($_.s)/$($_.n)" }
    $copiesAlike = @(@(Lines) | Where-Object { Parse $_ } | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq @($byN | Where-Object { $_.Count -gt 1 }).Count
    Check "a write cut off part-way: no event lost; repeated lines are exact copies (same session and number)" ((@($parsed | ForEach-Object { $_.sent } | Sort-Object -Unique) -join ",") -eq "1,2,3,4" -and $copiesAlike)

    # -- the failure path doesn't count, drop or log anything by itself --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Write-BkLog $log "afk.round" @{ sent = 1 }; Write-BkLog $log "afk.round" @{ sent = 2 }
    $D.FailAppend = $Locked; Flush-BkLog $log; $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log
    Check "two failed flushes: nothing dropped, rejected or added to the queue because of them" ($log.Failures -eq 2 -and $log.Queue.Count -eq 2 -and $log.Dropped -eq 0 -and $log.Rejected -eq 0 -and $log.DropsToReport -eq 0 -and $log.RejectsToReport -eq 0)
    $D.FailAppend = $null; $D.Now = $D.Now.AddSeconds(61); Flush-BkLog $log
    Check "after recovery: exactly the two events, and no log.dropped line (nothing was dropped)" (@(Lines).Count -eq 2 -and @(@(Lines) | Where-Object { $_ -match 'log\.dropped' }).Count -eq 0)

    # -- the clock moved back after a failure (time change): no wait of hours --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Write-BkLog $log "afk.round" @{ sent = 1 }
    $D.FailAppend = $Locked; Flush-BkLog $log
    $D.FailAppend = $null; $D.Now = $D.Now.AddHours(-2); Flush-BkLog $log
    Check "the clock moved 2 hours back after a failure: the retry doesn't wait 2 hours" (@(Lines).Count -eq 1 -and $log.Queue.Count -eq 0)

    # -- redaction gaps --
    $cases = @(
        @{ N = "a nickname split by a zero-width character"; Text = "Zqx" + [char]0x200B + "nick went away"; Want = "[private] went away" },
        @{ N = "a nickname in full-width letters"; Text = (-join ("Zqxnick".ToCharArray() | ForEach-Object { [char]([int]$_ + 0xFEE0) })) + " went away"; Want = "[private] went away" },
        @{ N = "a webhook written with HTML entities"; Text = "post https:&#x2F;&#x2F;discord.com&#x2F;api&#x2F;webhooks&#x2F;1&#x2F;HtmlCore went wrong"; Core = "HtmlCore" },
        @{ N = "a JSON reader error echoing file content (marked general by mistake)"; Text = "Invalid array passed in, ',' expected. (7): [OurFavName 1 2]"; Core = "OurFavName" },
        @{ N = "a nickname cut in half where long text is shortened"; Text = ("B" * 4090) + " Zqxnick tail"; Core = "Zqxn" }
    )
    foreach ($c in $cases) {
        $log = New-SecretLog
        Write-BkLog $log "app.error" @{ area = "general"; message = $c.Text }
        Flush-BkLog $log; $raw = @(Lines)[-1]; $x = Parse $raw
        if ($c.Want) { Check "redaction: $($c.N) is still caught" ($x.message -eq $c.Want) "$($x.message)" }
        else { Check "redaction: $($c.N) never gets through" ($raw.IndexOf($c.Core, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $null -ne $x) $raw }
    }

    # -- field types are exact --
    $log = New-SecretLog
    Write-BkLog $log "app.error" @{ area = "general"; function = "Builderman_99"; type = "Builderman_99" }
    Write-BkLog $log "update.check" @{ result = "failed"; errorType = "RobloxUser123" }
    Write-BkLog $log "app.error" @{ area = "general"; function = "Do-Jumps"; type = "System.IO.IOException" }
    Flush-BkLog $log; $l = @(@(Lines) | ForEach-Object { Parse $_ } | Where-Object { $_.ev -ne "log.dropped" })
    Check "a name field never takes something shaped like a Roblox username (letters, digits, _ only)" ($null -eq $l[0].function -and $null -eq $l[0].type -and $null -eq $l[1].errorType)
    Check "a name field still takes real code names (Do-Jumps, System.IO.IOException)" ($l[2].function -eq "Do-Jumps" -and $l[2].type -eq "System.IO.IOException")
    $log = New-SecretLog
    Write-BkLog $log "update.check" @{ current = "1.3.0`n"; newest = ([string][char]0x0661 + "." + [char]0x0662) }
    Write-BkLog $log "app.error" @{ type = "System.Exception`n" }
    Write-BkLog $log "screen.add" @{ account = "acc-1a2b3c`n" }
    Flush-BkLog $log; $l = @(@(Lines) | ForEach-Object { Parse $_ } | Where-Object { $_.ev -ne "log.dropped" })
    Check "a trailing line break, or non-Latin digits, make a version, name or alias invalid" ($null -eq $l[0].current -and $null -eq $l[0].newest -and $null -eq $l[1].type -and $null -eq $l[2].account)
    $log = New-SecretLog
    Write-BkLog $log "APP.START" @{ version = "1.3.0" }
    Flush-BkLog $log
    Check "an event name in the wrong case is rejected, not written as given" (@(@(Lines) | Where-Object { $_ -match 'APP\.START|"app\.start"' }).Count -eq 0 -and $log.Rejected -ge 1)
    $log = New-SecretLog
    Write-BkLog $log "app.start" @{ accounts = "x"; host = "linux"; testMode = 1 }
    Check "rejected counts each refused field (3 here) once" ($log.Rejected -eq 3 -and $log.RejectsToReport -eq 3)

    # ==== Phase 2b: the error sweep, secrets from the settings, start and stop ====
    # Real error records, made by real failures inside functions named like BloxKit's own (in a
    # child scope, so the real functions are left alone). Each returns the newest $Error entry.
    function New-Rec([scriptblock]$make) { & $make; return $global:Error[0] }
    $recExpected = New-Rec { & { function Get-RobloxCount { Get-Process -Name "NoSuchProc_zz" -ErrorAction SilentlyContinue | Out-Null }; Get-RobloxCount } }
    $recSettings = New-Rec { & { function Load-Settings { try { [IO.File]::ReadAllText("C:/NoSuchDir_zz/s.json") } catch {} }; Load-Settings } }
    $recJson     = New-Rec { & { function Read-SettingsFile { try { "{bad" | ConvertFrom-Json } catch {} }; Read-SettingsFile } }
    $recGeneral  = New-Rec { & { function Update-Status { try { [IO.File]::ReadAllText("C:/NoSuchDir_zz/$WinUser/a.txt") } catch {} }; Update-Status } }
    $recCmdlet   = New-Rec { & { function Refresh-Windows { Get-Item -LiteralPath "C:/NoSuchDir_zz/x" -ErrorAction SilentlyContinue | Out-Null }; Refresh-Windows } }
    $recOwn      = New-Rec { & { function Protect-BkText { try { [IO.File]::ReadAllText("C:/NoSuchDir_zz/o.txt") } catch {} }; Protect-BkText } }
    function New-PlainRec([string]$id) { New-Object System.Management.Automation.ErrorRecord ((New-Object System.InvalidOperationException "plain"), $id, "NotSpecified", $null) }
    function New-ErrList { $l = New-Object System.Collections.ArrayList; foreach ($r in $args) { [void]$l.Add($r) }; ,$l }   # newest first, like $Error
    function Events([string]$ev) { @(@($D.Files.Keys | ForEach-Object { Lines $_ }) | ForEach-Object { Parse $_ } | Where-Object { $_.ev -eq $ev }) }
    $e1 = New-PlainRec "One"; $e2 = New-PlainRec "Two"; $e3 = New-PlainRec "Three"

    # -- telling new from old: by the object, never by the count --
    $sw = New-BkErrorSweep 256
    $sw.Seen = $e1
    $r = Get-BkNewErrors $sw (New-ErrList $e3 $e2 $e1)
    Check "sweep: only the entries newer than the last one seen, oldest first" (@($r.New).Count -eq 2 -and [object]::ReferenceEquals($r.New[0], $e2) -and [object]::ReferenceEquals($r.New[1], $e3) -and -not $r.Lost)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $sw = New-BkErrorSweep 256; $sw.Seen = $e3
    Invoke-BkErrorSweep $sw $log (New-ErrList $e3 $e2 $e1)
    Check "sweep: nothing new since last time, nothing logged" ($log.Queue.Count -eq 0)
    $l2 = New-ErrList $e2 $e1; $sw = New-BkErrorSweep 256; $sw.Seen = $e3
    $r = Get-BkNewErrors $sw $l2
    Check "sweep: the list was cleared (last one seen gone, list not full): everything there is new, nothing counted lost" (@($r.New).Count -eq 2 -and -not $r.Lost)
    $sw = New-BkErrorSweep 3; $sw.Seen = (New-PlainRec "Gone")
    $r = Get-BkNewErrors $sw (New-ErrList $e3 $e2 $e1)
    Check "sweep: the list is full and the last one seen fell off: everything there is new, and errors were lost" (@($r.New).Count -eq 3 -and $r.Lost)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $sw = New-BkErrorSweep 3; $sw.Seen = (New-PlainRec "Gone")
    for ($k = 0; $k -lt 5; $k++) { Invoke-BkErrorSweep $sw $log (New-ErrList (New-PlainRec "Storm$k") (New-PlainRec "StormB$k") (New-PlainRec "StormC$k")); Flush-BkLog $log }
    Check "sweep: losing errors over and over doesn't write a line every second (counted for the summary)" ($sw.Overflows -eq 5 -and @(Events "log.dropped").Count -eq 0)
    $sw = New-BkErrorSweep 256; $sw.Seen = $null
    $r = Get-BkNewErrors $sw (New-ErrList $e2 $e1)
    Check "sweep: nothing seen before (empty at the start): everything is new" (@($r.New).Count -eq 2 -and -not $r.Lost)

    # -- what gets logged, once per kind --
    $port = New-FakeDisk; $log = New-SecretLog; $log.Port = $port; $sw = New-BkErrorSweep 256
    Invoke-BkErrorSweep $sw $log (New-ErrList $recOwn $recCmdlet $recGeneral $recJson $recSettings $recExpected)
    Flush-BkLog $log; $errs = @(Events "app.error")
    Check "sweep: an expected error (no Roblox running) is counted, not logged" ($sw.Expected -eq 1 -and @($errs | Where-Object { $_.function -eq "Get-Process" }).Count -eq 0)
    Check "sweep: the log's own errors are skipped (never logged about itself)" ($sw.Own -eq 1 -and $errs.Count -eq 4) "logged $($errs.Count), own $($sw.Own)"
    $set = @($errs | Where-Object { $_.area -eq "settings" }); $json = @($errs | Where-Object { $_.area -eq "json" }); $gen = @($errs | Where-Object { $_.area -eq "general" })
    Check "sweep: an error in Load-Settings is area settings, with no message" ($set.Count -eq 1 -and $null -eq $set[0].message -and $set[0].type -eq "System.IO.DirectoryNotFoundException")
    Check "sweep: a ConvertFrom-Json error is area json, with no message" ($json.Count -eq 1 -and $null -eq $json[0].message)
    Check "sweep: elsewhere it's general, and the message goes through the log's cleaning (no path, no user name)" (@($gen | Where-Object { $_.message }).Count -eq 2 -and @($gen | Where-Object { $_.message -match 'NoSuchDir|zqxuser' }).Count -eq 0) ($gen | ConvertTo-Json -Compress)
    Check "sweep: a .NET error shows its real type (not the PowerShell wrapper), a cmdlet error its command" (@($gen | Where-Object { $_.type -eq "System.IO.DirectoryNotFoundException" }).Count -eq 1 -and @($gen | Where-Object { $_.function -eq "Get-Item" }).Count -eq 1)
    Check "sweep: line numbers are recorded" (@($errs | Where-Object { $_.line -gt 0 }).Count -eq 4)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $sw = New-BkErrorSweep 256
    function Make-Gen { & { function Update-Status { try { [IO.File]::ReadAllText("C:/NoSuchDir_zz/same.txt") } catch {} }; Update-Status }; return $global:Error[0] }   # a new record each time, same line/type/id
    $g1 = Make-Gen; $g2 = Make-Gen; $g3 = Make-Gen
    Invoke-BkErrorSweep $sw $log (New-ErrList $g1)
    Invoke-BkErrorSweep $sw $log (New-ErrList $g3 $g2 $g1)
    Flush-BkLog $log
    Check "sweep: the same kind of error again (same line, type and id) is counted, logged once" (@(Events "app.error").Count -eq 1)
    Write-BkErrorSummary $sw $log; Flush-BkLog $log
    $sum = @(Events "app.error" | Where-Object { $_.repeats })
    Check "sweep summary at closing: how often each kind came back (repeats), without a message" ($sum.Count -eq 1 -and $sum[0].repeats -eq 2 -and $null -eq $sum[0].message)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $sw = New-BkErrorSweep 256 5
    $list = New-Object System.Collections.ArrayList; for ($k = 0; $k -lt 8; $k++) { $list.Insert(0, (New-PlainRec "Kind$k")) }
    Invoke-BkErrorSweep $sw $log $list; Flush-BkLog $log
    Check "sweep: at most MaxKeys kinds are logged; the rest are counted, not written" (@(Events "app.error").Count -eq 5 -and $sw.KeyOverflow -eq 3)
    Write-BkErrorSummary $sw $log; Flush-BkLog $log
    Check "sweep summary: the kinds that didn't fit are reported once as dropped" (@(Events "log.dropped" | Where-Object { $_.count -ge 3 }).Count -eq 1)

    # -- errors made while sweeping (by the sweep or the log) are never swept --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $sw = New-BkErrorSweep 256
    $script:live = New-ErrList $e1; $script:madeDuring = New-PlainRec "MadeDuringSweep"
    $port.Now = { if ($script:live.Count -lt 3) { $script:live.Insert(0, $script:madeDuring) }; $script:D.Now }   # each event logged adds an error
    Invoke-BkErrorSweep $sw $log $script:live
    Check "sweep: an error added while the sweep runs is marked seen" ([object]::ReferenceEquals($sw.Seen, $script:live[0]) -and [object]::ReferenceEquals($script:live[0], $script:madeDuring))
    $before = $log.Queue.Count
    Invoke-BkErrorSweep $sw $log $script:live
    Check "sweep: ...so the next sweep doesn't log it" ($log.Queue.Count -eq $before -and @($log.Queue | Where-Object { $_.Line -match 'MadeDuringSweep' }).Count -eq 0)

    # -- odd entries, and no disk work --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $sw = New-BkErrorSweep 256
    $err = $null; try { Invoke-BkErrorSweep $sw $log (New-ErrList "just text" (New-Object System.Exception "bare exception") $e1) } catch { $err = $_ }
    Check "sweep: odd entries (plain text, a bare exception) never make it throw" ($null -eq $err)
    Check "sweep: sweeping does no disk work (it only queues)" ($D.Calls -eq 0)

    # -- the real $Error of Windows PowerShell --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $sw = New-BkErrorSweep $MaximumErrorCount
    $sw.Seen = $(if ($global:Error.Count) { $global:Error[0] } else { $null })
    & { function Check-Disconnects { try { [IO.File]::ReadAllText("C:/NoSuchDir_zz/r1.txt") } catch {} }; Check-Disconnects }
    & { function Get-RobloxCount { Get-Process -Name "NoSuchProc_zz" -ErrorAction SilentlyContinue | Out-Null }; Get-RobloxCount }
    Invoke-BkErrorSweep $sw $log $global:Error
    Check "real `$Error: two new errors, one logged and one expected; the last one seen is the newest" ($log.Queue.Count -eq 1 -and $sw.Expected -eq 1 -and [object]::ReferenceEquals($sw.Seen, $global:Error[0]))
    for ($k = 0; $k -lt ($MaximumErrorCount + 20); $k++) { try { throw "flood" } catch {} }   # (for throw "text", the text is the error id: one kind)
    Invoke-BkErrorSweep $sw $log $global:Error
    Check "real `$Error: more new errors than it holds ($MaximumErrorCount): counted as lost once, one kind logged" ($sw.Overflows -eq 1 -and @($log.Queue | Where-Object { $_.Line -match '"type":"System.Management.Automation.RuntimeException"' }).Count -eq 1)

    # -- an error that ends the app --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    $f = ConvertTo-BkErrorFields $recGeneral $true
    Write-BkLog $log "app.error" $f; Flush-BkLog $log
    $x = @(Events "app.error")[0]
    Check "fatal error: written as an error with fatal true, its line and type" ($x.lvl -eq "error" -and $x.fatal -eq $true -and $x.line -gt 0 -and $x.type -eq "System.IO.DirectoryNotFoundException")

    # -- secrets from the settings --
    $state = [pscustomobject]@{
        accounts  = @([pscustomobject]@{ nick = "Zqxmain"; profileDir = "RobloxLauncher_Zqxmain"; profileUrl = "https://www.roblox.com/users/11223344/profile"; lastUrl = "https://www.roblox.com/games/5/x?privateServerLinkCode=LastCore77" })
        favorites = @([pscustomobject]@{ name = "Zqx secret hideout"; url = "https://www.roblox.com/share?code=FavCore&type=Server" })
        groups    = @([pscustomobject]@{ name = "Zqx farm squad" })
        lastLink  = "https://www.roblox.com/games/9/LinkBoxCore"; schedLink = "https://www.roblox.com/games/8/SchedCore"
        webhook   = "https://discord.com/api/webhooks/1/HookCore2"
    }
    $vals = @(Get-BkLogSecretValues $state @("Zqx Chrome Person"))
    $want = @("Zqxmain", "RobloxLauncher_Zqxmain", "https://www.roblox.com/users/11223344/profile", "https://www.roblox.com/games/5/x?privateServerLinkCode=LastCore77", "Zqx secret hideout", "https://www.roblox.com/share?code=FavCore&type=Server", "Zqx farm squad", "https://www.roblox.com/games/9/LinkBoxCore", "https://www.roblox.com/games/8/SchedCore", "https://discord.com/api/webhooks/1/HookCore2", "Zqx Chrome Person")
    Check "secrets from the settings: nicknames, profile folders, profile and last links, saved links and names, group names, link box, scheduled link, webhook, Chrome profile names" (@($want | Where-Object { $vals -notcontains $_ }).Count -eq 0) ("missing: " + (@($want | Where-Object { $vals -notcontains $_ }) -join " | "))
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; Set-BkLogSecrets $log $vals
    Write-BkLog $log "app.error" @{ area = "general"; message = "group Zqx farm squad and Zqx Chrome Person and Zqx secret hideout broke" }; Flush-BkLog $log
    Check "secrets from the settings are kept out of messages" (@(Lines)[-1] -notmatch 'Zqx (farm|Chrome|secret)' -and (Parse @(Lines)[-1]).message -match '\[private\]')

    # -- Windows' real version: inside BloxKit.exe, .NET's OSVersion says 6.2 (Windows' compatibility
    #    shim), which the live check showed; the registry tells the truth --
    $errBefore = $global:Error.Count
    $os = Get-BkOsBuild
    Check "Windows version from the registry: 10.x on this PC, accepted as a version, no error noted ($os)" ($os -cmatch '^10\.[0-9]+\.[0-9]+(\.[0-9]+)?\z' -and $global:Error.Count -eq $errBefore) $os

    # -- start and stop events with this PC's real values --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    $start = @{ version = "1.3.0"; scriptWritten = (Get-Item -LiteralPath (Join-Path $PSScriptRoot "..\BloxKit.ps1")).LastWriteTime; host = "exe"; psVersion = "" + $PSVersionTable.PSVersion; osBuild = "" + [Environment]::OSVersion.Version; testMode = $false; settingsSource = "main"; accounts = 6; screensRestored = 2 }
    Write-BkLog $log "app.start" $start
    Write-BkLog $log "app.stop" @{ reason = "exit"; uptimeSec = 3600; dropped = 0 }
    Flush-BkLog $log
    $s0 = @(Events "app.start")[0]
    Check "app.start with this PC's real values: every field accepted (PowerShell $($PSVersionTable.PSVersion), Windows $([Environment]::OSVersion.Version))" ($log.Rejected -eq 0 -and $s0.psVersion -eq ("" + $PSVersionTable.PSVersion) -and $s0.osBuild -and $s0.scriptWritten -and @(Events "app.stop").Count -eq 1) "rejected $($log.Rejected)"

    # -- the last write at closing (or a crash) doesn't wait out a backoff --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Write-BkLog $log "afk.round" @{ sent = 1 }
    $D.FailAppend = $Locked; Flush-BkLog $log; $D.FailAppend = $null
    Flush-BkLog $log
    Check "after a failure, a normal flush still waits" ($log.Queue.Count -eq 1)
    Flush-BkLog $log -Force
    Check "the closing (or crash) flush writes right away, without waiting" ($log.Queue.Count -eq 0 -and @(Lines).Count -eq 1)

    # ==== Phase 2c: anti-AFK and focus diagnostics ====
    if (-not ("BkInputPort" -as [type])) { Add-Type -TypeDefinition $BkInputSource }
    # A pretend Windows with just what Get-AfkWindowKind asks: windows, their class, process, visibility.
    $W = @{ Alive = @(100, 201, 202, 400, 500, 600); Hidden = @(500); Class = @{ 100 = "Notepad"; 201 = "WINDOWSCLIENT"; 202 = "WINDOWSCLIENT"; 400 = "Shell_TrayWnd"; 500 = "WindowsForms10"; 600 = "HwndWrapper" }; Pid = @{ 100 = 11; 201 = 7; 202 = 8; 400 = 13; 500 = 20; 600 = 20 } }
    $kp = New-Object BkInputPort
    $kp.IsWindow = [Func[IntPtr, bool]]{ param($h) $W.Alive -contains $h.ToInt64() }
    $kp.IsVisible = [Func[IntPtr, bool]]{ param($h) ($W.Alive -contains $h.ToInt64()) -and ($W.Hidden -notcontains $h.ToInt64()) }
    $kp.ClassOf = [Func[IntPtr, string]]{ param($h) "" + $W.Class[[int]$h.ToInt64()] }
    $kp.PidOf = [Func[IntPtr, int]]{ param($h) [int]$W.Pid[[int]$h.ToInt64()] }
    $kctx = New-AfkFocusContext 20 ([IntPtr]600) @(201, 202)
    $kinds = @{ "your app" = @(100, "user"); "a Roblox screen" = @(201, "roblox"); "the taskbar" = @(400, "taskbar"); "BloxKit's main window" = @(600, "bloxkit"); "BloxKit's hidden tray window" = @(500, "bloxkit-other"); "a closed window" = @(999, "none"); "no window" = @(0, "none") }
    foreach ($k in $kinds.Keys) { Check "window kind: $k is '$($kinds[$k][1])'" ((Get-AfkWindowKind $kp ([IntPtr]$kinds[$k][0]) $kctx) -eq $kinds[$k][1]) "got $(Get-AfkWindowKind $kp ([IntPtr]$kinds[$k][0]) $kctx)" }

    function New-Pass([string[]]$sent, [bool]$restored = $true, [string]$why = "") { @{ Results = @($sent | ForEach-Object { @{ W = $null; Act = "jump"; Sent = $_ } }); Back = [IntPtr]100; Restored = $restored; Why = $why } }
    function EvNames($evs) { (@($evs | ForEach-Object { $_.Ev }) -join ",") }
    # -- which rounds are logged: only the ones where something went wrong --
    $dg = New-AfkDiag
    $evs = @(Get-AfkRoundEvents $dg (New-Pass @("Sent", "Sent")) "timer" "hidden" 900 "user" $false $false)
    Check "a clean round (everything pressed, keyboard back) is not logged" ($evs.Count -eq 0) (EvNames $evs)
    $evs = @(Get-AfkRoundEvents $dg (New-Pass @("Sent", "NoWindow")) "timer" "hidden" 900 "user" $false $false)
    Check "a round where a window just closed isn't news either" ($evs.Count -eq 0) (EvNames $evs)
    $evs = @(Get-AfkRoundEvents $dg (New-Pass @("Sent", "NoFocus", "FocusLost", "Covered", "Failed", "NoWindow")) "tray" "hidden" 1234 "user" $false $false)
    $f = $evs[0].Fields
    Check "a round with skipped screens: one afk.round with the source, mode, counts, where the keyboard went, and the time" ((EvNames $evs) -eq "afk.round" -and $f.trigger -eq "tray" -and $f.mode -eq "hidden" -and $f.screens -eq 6 -and $f.sent -eq 1 -and $f.skipNoFocus -eq 1 -and $f.skipFocusLost -eq 1 -and $f.skipCovered -eq 1 -and $f.skipFailed -eq 1 -and $f.skipNoWindow -eq 1 -and $f.back -eq "user" -and $f.restored -eq $true -and $f.why -eq "none" -and $f.durationMs -eq 1234) (EvNames $evs)
    $evs = @(Get-AfkRoundEvents $dg (New-Pass @("Sent") $false "refused") "button" "quick" 800 "roblox" $false $true)
    Check "the keyboard couldn't be given back: afk.round (not restored, why) and afk.stuck" ((EvNames $evs) -eq "afk.round,afk.stuck" -and $evs[0].Fields.restored -eq $false -and $evs[0].Fields.why -eq "refused" -and $evs[1].Fields.why -eq "refused") (EvNames $evs)
    $evs = @(Get-AfkRoundEvents $dg (New-Pass @("Sent") $false "closed") "repeat" "hidden" 800 "none" $true $true)
    Check "already stuck before this round: no second afk.stuck (only the round)" ((EvNames $evs) -eq "afk.round") (EvNames $evs)
    foreach ($why in "notarget", "closed", "refused") {
        $evs = @(Get-AfkRoundEvents (New-AfkDiag) (New-Pass @() $false $why) "test" "hidden" 10 "none" $false $true)
        Check "stuck because '$why': afk.stuck says so" ($evs[-1].Ev -eq "afk.stuck" -and $evs[-1].Fields.why -eq $why)
    }
    # -- rounds that didn't start: only when the reason changes --
    $dg = New-AfkDiag
    $a1 = Get-AfkNotStartedEvent $dg "stuck" "roblox"; $a2 = Get-AfkNotStartedEvent $dg "stuck" "roblox"
    Check "a round refused twice for the same reason: logged once" ($a1.Ev -eq "afk.notstarted" -and $a1.Fields.why -eq "stuck" -and $a1.Fields.fg -eq "roblox" -and $null -eq $a2)
    $a3 = Get-AfkNotStartedEvent $dg "notarget" "taskbar"
    Check "...a different reason is logged" ($a3.Fields.why -eq "notarget")
    [void](Get-AfkRoundEvents $dg (New-Pass @("Sent")) "timer" "hidden" 1 "user" $false $false)
    $a4 = Get-AfkNotStartedEvent $dg "notarget" "taskbar"
    Check "...and after a round did start, the same reason is logged again" ($null -ne $a4)
    # -- the events fit the schema, and nothing else gets through --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    $all = @(Get-AfkRoundEvents (New-AfkDiag) (New-Pass @("NoFocus") $false "refused") "hotkey" "hidden" 5 "bloxkit-other" $false $true) + @(Get-AfkNotStartedEvent (New-AfkDiag) "stuck" "roblox") + @(New-AfkUnstuckEvent "user")
    Write-AfkDiagEvents $log $all
    Check "afk.round, afk.stuck, afk.notstarted and afk.unstuck all pass the schema (nothing rejected), and writing them does no disk work" ($log.Rejected -eq 0 -and $log.Queue.Count -eq 4 -and $D.Calls -eq 0) "rejected $($log.Rejected), queued $($log.Queue.Count), disk calls $($D.Calls)"
    Flush-BkLog $log
    Check "...only the flush writes them" (@(Lines).Count -eq 4 -and @(Events "afk.unstuck").Count -eq 1)
    $port = New-FakeDisk; $log = New-SecretLog; $log.Port = $port
    $bad = @(Get-AfkRoundEvents (New-AfkDiag) (New-Pass @("NoFocus")) "evil<script>" "Zqxnick" 5 "C:\Users\zqxuser" $false $false)
    Write-AfkDiagEvents $log $bad; Flush-BkLog $log
    $x = @(Events "afk.round")[0]
    Check "an unknown source, mode or window kind is never written (only allow-listed values)" ($null -ne $x -and $null -eq $x.trigger -and $null -eq $x.mode -and $null -eq $x.back -and (@(Lines) -join "") -notmatch 'evil|Zqxnick|zqxuser') (@(Lines) -join " ")
    # -- the logger off, failing, or missing never reaches anti-AFK --
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $log.Off = $true
    $err = $null; try { Write-AfkDiagEvents $log $all; Write-AfkDiagEvents $null $all; Write-AfkDiagEvents $log $null; Write-AfkDiagEvents $log @("junk", $null, @{ Ev = "afk.round" }) } catch { $err = $_ }
    Check "logger off, no logger, or junk events: nothing thrown" ($null -eq $err)
    $port = New-FakeDisk; $log = New-BkLog $Dir $port; $D.FailAppend = $Locked
    Write-AfkDiagEvents $log $all; $err = $null; try { Flush-BkLog $log } catch { $err = $_ }
    Check "the disk failing: the events stay queued, nothing thrown" ($null -eq $err -and $log.Queue.Count -eq 4)
    $err = $null; try { [void](Get-AfkRoundEvents (New-AfkDiag) $null "timer" "hidden" 0 "user" $false $false); [void](Get-AfkRoundEvents $null @{ Results = "junk" } $null $null $null $null $null $null); [void](Get-AfkNotStartedEvent $null "stuck" "user"); [void](Get-AfkWindowKind $null ([IntPtr]100) $null) } catch { $err = $_ }
    Check "odd input (no round, no state, no port) never makes the diagnostics throw" ($null -eq $err) "$err"
    # -- the diagnostics only read: the round and anti-AFK's own state are left exactly as they were --
    $pass = New-Pass @("NoFocus", "Sent") $false "refused"; $focus = New-AfkFocus; $focus.Stuck = $true; $focus.Last = [IntPtr]100; $focus.Note = "n"
    $snap = ($pass.Results | ForEach-Object { "$($_.Act)/$($_.Sent)" }) -join "," ; $snap += "|$($pass.Back)|$($pass.Restored)|$($pass.Why)|$($focus.Stuck)|$($focus.Last)|$($focus.Note)"
    [void](Get-AfkRoundEvents (New-AfkDiag) $pass "timer" "hidden" 5 (Get-AfkWindowKind $kp $pass.Back $kctx) $false $focus.Stuck)
    $after = ($pass.Results | ForEach-Object { "$($_.Act)/$($_.Sent)" }) -join "," ; $after += "|$($pass.Back)|$($pass.Restored)|$($pass.Why)|$($focus.Stuck)|$($focus.Last)|$($focus.Note)"
    Check "the diagnostics change nothing in the round or in anti-AFK's focus state" ($snap -eq $after) "$snap -> $after"

    # -- the app's hook itself: Invoke-AfkPassLogged, taken from BloxKit.ps1 by name, around a stand-in round --
    $tokens = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "..\BloxKit.ps1"), [ref]$tokens, [ref]$perr)
    $hook = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Invoke-AfkPassLogged" }, $true)
    Check "the hook Invoke-AfkPassLogged is in BloxKit.ps1" ($null -ne $hook)
    Invoke-Expression $hook.Extent.Text
    function Get-AfkFocusContext { $kctx }
    $script:InputPort = $kp
    $script:roundLog = @()
    function Invoke-AfkPass($picks, [bool]$hidden, [IntPtr]$back) {
        # stand-in round: notes how much was queued and written while it ran; may make the keyboard stuck
        $script:roundLog += @{ Queued = $(if ($script:BkLog) { $script:BkLog.Queue.Count } else { -1 }); Disk = $script:D.Calls }
        if ($script:makeStuck) { $script:AfkFocus.Stuck = $true }
        return $script:stubPass
    }
    $port = New-FakeDisk; $script:BkLog = New-BkLog $Dir $port; $script:AfkDiag = New-AfkDiag; $script:AfkFocus = New-AfkFocus
    $script:makeStuck = $false; $script:stubPass = New-Pass @("Sent", "Sent")
    Write-BkLog $script:BkLog "multiwindow" @{ state = "on" }   # something already waiting from earlier in the tick
    $got = Invoke-AfkPassLogged @() $true ([IntPtr]100) "timer"
    Check "hook, clean round: the very same round comes back, nothing added, and what was waiting is still waiting (no disk work)" ([object]::ReferenceEquals($got, $script:stubPass) -and $script:BkLog.Queue.Count -eq 1 -and $D.Calls -eq 0)
    $script:BkLog.Queue.Clear(); $script:roundLog = @()
    $script:makeStuck = $true; $script:stubPass = New-Pass @("NoFocus") $false "refused"; $script:stubPass.Back = [IntPtr]201   # you were playing in a Roblox window
    $got = Invoke-AfkPassLogged @() $true ([IntPtr]201) "tray"
    $q = @($script:BkLog.Queue | ForEach-Object { $_.Line })
    Check "hook, failed round: the same round comes back; afk.round (tray, back=roblox) and afk.stuck are queued" ([object]::ReferenceEquals($got, $script:stubPass) -and $q.Count -eq 2 -and $q[0] -match '"ev":"afk.round".*"trigger":"tray".*"back":"roblox"' -and $q[1] -match '"ev":"afk.stuck","why":"refused"') ($q -join " | ")
    Check "hook: nothing was queued or written while the round itself ran (only afterwards)" (@($script:roundLog | Where-Object { $_.Queued -ne 0 -or $_.Disk -ne 0 }).Count -eq 0) (($script:roundLog | ForEach-Object { "$($_.Queued)/$($_.Disk)" }) -join ",")
    Check "hook: no disk work at all (the tick's flush writes it later)" ($D.Calls -eq 0)
    Check "hook: anti-AFK's own focus state is what the round left (stuck), not changed by the diagnostics" ($script:AfkFocus.Stuck -eq $true -and $script:AfkFocus.Note -eq "")
    $script:BkLog = $null; $script:makeStuck = $false; $script:stubPass = New-Pass @("NoFocus")
    $err = $null; try { $got = Invoke-AfkPassLogged @() $true ([IntPtr]100) "button" } catch { $err = $_ }
    Check "hook with no log: the round runs and comes back the same, nothing thrown" ($null -eq $err -and [object]::ReferenceEquals($got, $script:stubPass))
    $port = New-FakeDisk; $script:BkLog = New-BkLog $Dir $port; $script:BkLog.Port.Now = { throw "clock broken" }
    $err = $null; try { $got = Invoke-AfkPassLogged @() $true ([IntPtr]100) "hotkey" } catch { $err = $_ }
    Check "hook with a broken log: the round runs and comes back the same, nothing thrown" ($null -eq $err -and [object]::ReferenceEquals($got, $script:stubPass))
    $script:BkLog = $null

    # ==== afk.state: anti-AFK's effective settings, at start and when they change ====
    $st = [pscustomobject]@{ afkOn = $false; afkMode = "hidden"; afkMinutes = 10; afkActions = @("zoom", "walk"); afkSkipActive = $false; afkJitter = $true }
    $sf = Get-AfkStateFields $true $st
    Check "afk.state fields: on comes from the running switch (not the saved copy), plus mode, minutes, actions, skip-active, jitter" ($sf.on -eq $true -and $sf.mode -eq "hidden" -and $sf.minutes -eq 10 -and $sf.zoom -eq $true -and $sf.step -eq $true -and $sf.jump -eq $false -and $sf.click -eq $false -and $sf.skipActive -eq $false -and $sf.jitter -eq $true) ($sf | ConvertTo-Json -Compress)
    $st2 = [pscustomobject]@{ afkOn = $true; afkMode = "something else"; afkMinutes = 5; afkActions = @(); afkSkipActive = $true; afkJitter = $false }
    $sf2 = Get-AfkStateFields $false $st2
    Check "afk.state fields are what anti-AFK really does: no actions picked means jump, any mode but hidden means quick" ($sf2.on -eq $false -and $sf2.mode -eq "quick" -and $sf2.jump -eq $true -and $sf2.step -eq $false) ($sf2 | ConvertTo-Json -Compress)
    $dg = New-AfkDiag
    $s1 = Get-AfkStateEvent $dg $sf; $s2 = Get-AfkStateEvent $dg (Get-AfkStateFields $true $st)
    Check "afk.state: the first state is logged, the same state again is not" ($s1.Ev -eq "afk.state" -and $null -eq $s2)
    $changes = @{ on = { param($s) Get-AfkStateFields $false $s }; mode = { param($s) $s.afkMode = "quick"; Get-AfkStateFields $true $s }; minutes = { param($s) $s.afkMinutes = 3; Get-AfkStateFields $true $s }
                  jump = { param($s) $s.afkActions = @("zoom", "walk", "jump"); Get-AfkStateFields $true $s }; step = { param($s) $s.afkActions = @("zoom"); Get-AfkStateFields $true $s }
                  zoom = { param($s) $s.afkActions = @("walk"); Get-AfkStateFields $true $s }; click = { param($s) $s.afkActions = @("zoom", "walk", "click"); Get-AfkStateFields $true $s }; skipActive = { param($s) $s.afkSkipActive = $true; Get-AfkStateFields $true $s }; jitter = { param($s) $s.afkJitter = $false; Get-AfkStateFields $true $s } }
    foreach ($k in $changes.Keys) {
        $dg = New-AfkDiag; $base = [pscustomobject]@{ afkOn = $false; afkMode = "hidden"; afkMinutes = 10; afkActions = @("zoom", "walk"); afkSkipActive = $false; afkJitter = $true }
        [void](Get-AfkStateEvent $dg (Get-AfkStateFields $true $base))
        $ev = Get-AfkStateEvent $dg (& $changes[$k] $base)
        Check "afk.state: a change in $k is logged" ($null -ne $ev -and $ev.Ev -eq "afk.state")
    }
    $dg = New-AfkDiag; [void](Get-AfkStateEvent $dg $sf); [void](Get-AfkStateEvent $dg $sf2)
    Check "afk.state: changing back is a change too" ($null -ne (Get-AfkStateEvent $dg $sf))
    $port = New-FakeDisk; $log = New-BkLog $Dir $port
    Write-AfkDiagEvents $log @(Get-AfkStateEvent (New-AfkDiag) $sf)
    Check "afk.state passes the schema (nothing rejected) and only queues (no disk work)" ($log.Rejected -eq 0 -and $log.Queue.Count -eq 1 -and $D.Calls -eq 0)
    $port = New-FakeDisk; $log = New-SecretLog; $log.Port = $port
    $badState = [pscustomobject]@{ afkOn = $true; afkMode = "Zqxnick"; afkMinutes = "ten"; afkActions = @("evil"); afkSkipActive = "yes"; afkJitter = $null }
    Write-AfkDiagEvents $log @(Get-AfkStateEvent (New-AfkDiag) (Get-AfkStateFields "maybe" $badState)); Flush-BkLog $log
    Check "afk.state from odd settings: only valid values are written, nothing raw" (@(Lines).Count -ge 1 -and (@(Lines) -join "") -notmatch 'Zqxnick|ten|evil|maybe') (@(Lines) -join " ")
    $err = $null; try { [void](Get-AfkStateFields $null $null); [void](Get-AfkStateEvent $null $null); Write-AfkDiagEvents $null @(Get-AfkStateEvent (New-AfkDiag) $sf) } catch { $err = $_ }
    Check "afk.state helpers with no settings, no state or no log: nothing thrown" ($null -eq $err) "$err"

    # ==== guards: logging never interrupts start-up, saving settings, the tick, or closing ====
    # The real functions, taken from BloxKit.ps1 by name, run in a child scope against stand-ins that fail.
    $fnText = @{}
    foreach ($fn in "Start-BkLog", "Update-BkLogSecrets", "Step-BkLog", "Save-Settings") {
        $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
        $fnText[$fn] = $(if ($node) { $node.Extent.Text } else { "" })
        Check "guard check: $fn is in BloxKit.ps1" ([bool]$node)
    }
    $guardEnv = {
        # what the app has by the time these run
        $script:AppDir = Join-Path ([IO.Path]::GetTempPath()) "bk-guard-not-created"; $script:NoRoblox = $false; $script:BkVersion = "1.3.0"
        $script:SettingsSource = "main"; $script:SessionRestore = @{}; $script:SettingsFile = "C:\fake\settings.json"
        $script:State = [pscustomobject]@{ accounts = @(); favorites = @(); groups = @(); lastLink = ""; schedLink = ""; webhook = ""; afkOn = $false; afkMode = "hidden"; afkMinutes = 5; afkActions = @("jump"); afkSkipActive = $true; afkJitter = $true }
        $script:AfkOn = $false; $script:AfkDiag = New-AfkDiag; $script:SkipSave = $false; $script:SettingsLocked = $false; $script:SaveError = ""
        $script:Said = @(); $script:Saved = 0
        function Say([string]$m) { $script:Said += $m }
        function Get-ChromeProfiles { @() }
        function Write-SettingsFile($s, $p) { $script:Saved++; return "" }
        foreach ($t in $fnText.Values) { Invoke-Expression $t }
    }
    $r = & { . $guardEnv; Start-BkLog; @{ Log = $script:BkLog } }
    Check "start-up, everything fine: the log is set up and app.start is queued (nothing written yet)" ($null -ne $r.Log -and @($r.Log.Queue | Where-Object { $_.Line -match '"ev":"app.start"' }).Count -eq 1)
    $r = & { . $guardEnv; function New-BkLog { throw "can't make the log" }; $err = $null; try { Start-BkLog } catch { $err = $_ }; @{ Err = $err; Log = $script:BkLog } }
    Check "start-up, the log can't be made: start-up goes on (nothing thrown), logging is off" ($null -eq $r.Err -and $null -eq $r.Log)
    $r = & { . $guardEnv; function Get-ChromeProfiles { throw "Chrome's file is broken" }; $err = $null; try { Start-BkLog } catch { $err = $_ }; @{ Err = $err; Log = $script:BkLog } }
    Check "start-up, the privacy list can't be built: start-up goes on, and logging is off (never logs without the list)" ($null -eq $r.Err -and $null -eq $r.Log)
    $r = & { . $guardEnv; $script:BkLog = $null; $err = $null; try { Step-BkLog; Step-BkLog -Final } catch { $err = $_ }; @{ Err = $err; Last = $script:AfkDiag.LastState } }
    Check "tick and closing with logging off: nothing thrown, and no logging work done at all" ($null -eq $r.Err -and $null -eq $r.Last) "last state: $($r.Last)"
    $r = & { . $guardEnv; $script:BkLog = New-BkLog $Dir (New-FakeDisk); $script:BkErrors = New-BkErrorSweep; function Invoke-BkErrorSweep { throw "sweep broke" }; $err = $null; try { Step-BkLog } catch { $err = $_ }; @{ Err = $err } }
    Check "tick, the error sweep breaks: nothing thrown into the tick" ($null -eq $r.Err)
    $r = & { . $guardEnv; $script:BkLog = New-BkLog $Dir (New-FakeDisk); $script:BkErrors = New-BkErrorSweep; $script:BkLogClock = [Diagnostics.Stopwatch]::StartNew(); function Write-BkErrorSummary { throw "summary broke" }; $err = $null; try { Step-BkLog -Final } catch { $err = $_ }; @{ Err = $err } }
    Check "closing, the summary breaks: nothing thrown, so closing's own clean-up still runs" ($null -eq $r.Err)
    $r = & { . $guardEnv; $script:BkLog = New-BkLog $Dir (New-FakeDisk); function Update-BkLogSecrets { throw "list broke" }; $err = $null; try { Save-Settings } catch { $err = $_ }; @{ Err = $err; Saved = $script:Saved; Off = $script:BkLog.Off; Notice = $script:BkLog.Notice } }
    Check "saving settings, the privacy list can't be updated: the settings are still saved, nothing thrown" ($null -eq $r.Err -and $r.Saved -eq 1)
    Check "...and logging turns off for the run (never logs with an outdated list), with a notice in words" ($r.Off -eq $true -and $r.Notice -match 'privacy list')
    # -- afk.state through the real Step-BkLog: start, changes from anywhere, nothing per tick --
    $r = & {
        . $guardEnv
        $port = New-FakeDisk; $script:BkLog = New-BkLog $Dir $port; $script:BkErrors = New-BkErrorSweep; $script:BkLogClock = [Diagnostics.Stopwatch]::StartNew()
        Step-BkLog; Step-BkLog; Step-BkLog                         # start: one state, then quiet ticks
        $script:AfkOn = $true; Step-BkLog; Step-BkLog              # turned on (button, tray or hotkey all flip this switch)
        $script:State.afkMode = "quick"; Step-BkLog                # Test anti-AFK or the settings change the mode
        $script:State.afkMinutes = 15; Step-BkLog; Step-BkLog      # settings: interval
        $script:State.afkJitter = $false; Step-BkLog -Final        # changed right before closing
        @{ States = @($script:D.Files.Keys | ForEach-Object { Lines $_ } | ForEach-Object { Parse $_ } | Where-Object { $_.ev -eq "afk.state" }) }
    }
    $sx = @($r.States)
    Check "through Step-BkLog: the start state once, then exactly one line per change (on, mode, minutes, jitter), none for quiet ticks" ($sx.Count -eq 5 -and $sx[0].on -eq $false -and $sx[1].on -eq $true -and $sx[2].mode -eq "quick" -and $sx[3].minutes -eq 15 -and $sx[4].jitter -eq $false) (($sx | ForEach-Object { "$($_.on)/$($_.mode)/$($_.minutes)/$($_.jitter)" }) -join " ")

    # ---- the real disk, in a temp folder ----
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("bk-diag-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    try {
        $real = New-BkLog (Join-Path $tmp "logs") (New-BkLogFilePort) 1500
        for ($i = 1; $i -le 60; $i++) { Write-BkLog $real "afk.round" @{ trigger = "timer"; sent = $i }; if ($i % 5 -eq 0) { Flush-BkLog $real } }
        $files = @(Get-ChildItem (Join-Path $tmp "logs") -File)
        $bad = @($files | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -and $null -eq (Parse $_) }).Count
        Check "real disk: the folder is made, 4 files at most, each under the limit, every line valid JSON" ($files.Count -eq 4 -and @($files | Where-Object { $_.Length -gt 1500 }).Count -eq 0 -and $bad -eq 0) "$($files.Count) files"
        $bytes = [IO.File]::ReadAllBytes($real.Path)
        Check "real disk: plain UTF-8 without a byte-order mark" (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB))
        $lock = New-Object IO.FileStream ($real.Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Write-BkLog $real "afk.round" @{ sent = 99 }; $err = $null
            try { Flush-BkLog $real } catch { $err = $_ }
            Check "real disk: a file locked by another program fails quietly, the event stays queued" ($null -eq $err -and $real.Failures -eq 1 -and $real.Queue.Count -eq 1)
        } finally { $lock.Dispose() }
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
catch {
    $script:fails++
    "FAIL  the checks crashed: $_ (check-diag.ps1 line $($_.InvocationInfo.ScriptLineNumber))"
}
"`n" + $(if ($script:fails) { "$($script:fails) failed." } else { "All diagnostics log checks passed." })
exit $script:fails
