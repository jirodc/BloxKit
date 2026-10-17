# Checks how Roblox Manager reads pasted links (no app window, no network).
#     powershell -ExecutionPolicy Bypass -File tools\check-links.ps1
. (Join-Path $PSScriptRoot "..\RobloxManager.ps1") -TestOnly

$cases = @(
    # link                                                                         kind       user id
    @("https://www.roblox.com/users/123456789/profile",                            "profile", "123456789"),
    @("roblox.com/users/123456789/profile",                                        "profile", "123456789"),
    @("https://www.roblox.com/users/123456789",                                    "profile", "123456789"),
    @("https://www.roblox.com/de/users/123456789/profile",                         "profile", "123456789"),
    @("https://www.roblox.com/en-us/users/123456789/profile",                      "profile", "123456789"),
    @("https://www.roblox.com/share?code=4f7a1b2c3d&type=Profile",                 "profile", ""),
    @("https://ro.blox.com/Ebh5?af_dp=roblox%3A%2F%2Fnavigation%2Fprofile%3FuserId%3D123456789&af_web_dp=https%3A%2F%2Fwww.roblox.com%2Fusers%2F123456789%2Fprofile", "profile", "123456789"),
    @("https://www.roblox.com/games/920587237/Adopt-Me",                           "game",    ""),
    @("https://www.roblox.com/de/games/920587237/Adopt-Me",                        "game",    ""),
    @("920587237",                                                                 "game",    ""),
    @("https://www.roblox.com/share?code=4f7a1b2c3d&type=ExperienceDetails",       "game",    ""),
    @("https://www.roblox.com/share?code=4f7a1b2c3d&type=Server",                  "private", ""),
    @("https://www.roblox.com/games/920587237?privateServerLinkCode=123",          "private", ""),
    @("https://www.roblox.com/games/start?placeId=1",                              "bad",     ""),
    @("https://www.google.com/",                                                   "bad",     "")
)
$fails = 0
foreach ($c in $cases) {
    $i = Get-LinkInfo $c[0]
    $ok = ($i.Kind -eq $c[1]) -and ("" + $i.UserId -eq $c[2])
    if (-not $ok) { $fails++ }
    "{0}  {1,-8} {2,-10} {3}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $i.Kind, $i.UserId, $c[0].Substring(0, [Math]::Min(75, $c[0].Length)) +
        $(if ($ok) { "" } else { "   (expected $($c[1]) $($c[2]))" })
}
"`n" + $(if ($fails) { "$fails failed." } else { "All link checks passed." })
exit $fails
