# Updates BloxKit in place from GitHub: downloads the newest version, replaces the program files
# in the BloxKit folder, and can open BloxKit again. Your accounts and settings live in
# %APPDATA%\RobloxMultiLauncher and aren't touched; neither are files that aren't part of BloxKit.
#   From the app: Settings > Help and feedback > Check for updates.
#   By hand:      powershell -ExecutionPolicy Bypass -File tools\update.ps1
param(
    [string]$AppDir,          # the BloxKit folder (found by itself when not given)
    [int]$WaitPid = 0,        # wait for this BloxKit to close first (the app passes its own)
    [switch]$Restart,         # open BloxKit again afterwards
    [switch]$Quiet,           # started by the app: problems show in a message box, not a console
    [switch]$Force,           # update even when the version is the same
    [string]$Source = ""      # a local .zip instead of GitHub (for testing)
)
$ErrorActionPreference = "Stop"
$Zip = "https://codeload.github.com/jirodc/BloxKit/zip/refs/heads/main"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$DataDir = Join-Path $env:APPDATA "RobloxMultiLauncher"
New-Item -ItemType Directory -Force $DataDir | Out-Null
$Log = Join-Path $DataDir "update.log"

function Say([string]$m) { Write-Host $m; try { Add-Content -Path $Log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) } catch {} }
function Start-App {
    $exe = Join-Path $AppDir "BloxKit.exe"
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -WorkingDirectory $AppDir }
    else { Start-Process powershell -ArgumentList "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $AppDir 'BloxKit.ps1')`"" -WorkingDirectory $AppDir }
}
function Fail([string]$m) {
    Say "Update failed: $m"
    if ($Quiet) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("BloxKit couldn't update:`n`n$m`n`nYour BloxKit wasn't changed. (Details: $Log)", "BloxKit update", "OK", "Warning") | Out-Null
    }
    if ($Restart) { Start-App }
    exit 1
}
function Get-Version([string]$file) {
    $m = [regex]::Match([IO.File]::ReadAllText($file), '(?m)^\$BkVersion\s*=\s*"([\d.]+)"')
    if ($m.Success) { [version]$m.Groups[1].Value } else { [version]"0.0" }
}

# ---- which folder ----
if (-not $AppDir) {
    $here = Split-Path -Parent $PSScriptRoot
    if ($here -and (Test-Path -LiteralPath (Join-Path $here "BloxKit.ps1"))) { $AppDir = $here }
    else {
        $p = Get-Process -Name BloxKit -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
        if ($p) { $AppDir = Split-Path -Parent $p.Path }
    }
    if (-not $AppDir) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Pick your BloxKit folder (the one with BloxKit.exe)"
        if ($dlg.ShowDialog() -ne "OK") { Say "No folder picked; nothing was changed."; exit 1 }
        $AppDir = $dlg.SelectedPath
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $AppDir "BloxKit.ps1"))) { Fail "BloxKit.ps1 isn't in '$AppDir'. Pick the folder that has BloxKit.exe." }
$AppDir = (Resolve-Path -LiteralPath $AppDir).Path
$have = Get-Version (Join-Path $AppDir "BloxKit.ps1")
Say "BloxKit folder: $AppDir (version $have)"

# ---- download and unpack ----
$work = Join-Path ([IO.Path]::GetTempPath()) ("bloxkit-update-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $zipFile = Join-Path $work "bloxkit.zip"
    if ($Source) { Copy-Item -LiteralPath $Source $zipFile }
    else {
        Say "Downloading the newest BloxKit from GitHub..."
        try { (New-Object Net.WebClient).DownloadFile($Zip, $zipFile) }
        catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; Fail "the download didn't work ($($e.Message)). Check your internet connection." }
    }
    Expand-Archive -LiteralPath $zipFile -DestinationPath (Join-Path $work "x") -Force
    $root = Get-ChildItem (Join-Path $work "x") -Directory | Select-Object -First 1
    if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root.FullName "BloxKit.ps1"))) { Fail "the download doesn't look like BloxKit." }
    $new = Get-Version (Join-Path $root.FullName "BloxKit.ps1")
    if ($new -le $have -and -not $Force) {
        Say "You already have the newest version ($have)."
        if ($Quiet) { Set-Content -Path (Join-Path $DataDir "updated.txt") -Value "same $have" }
        if ($Restart) { if ($WaitPid) { Wait-Process -Id $WaitPid -Timeout 30 -ErrorAction SilentlyContinue }; Start-App }
        exit 0
    }
    Say "Updating $have -> $new"

    # ---- wait for the app to close (its program file can't be replaced while it runs) ----
    if ($WaitPid) { Wait-Process -Id $WaitPid -Timeout 30 -ErrorAction SilentlyContinue }

    # ---- replace what changed ----
    Get-ChildItem -LiteralPath $AppDir -Filter "*.bloxkit-old" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue   # left from the last update
    $changed = @(); $helper = $false
    foreach ($f in Get-ChildItem -LiteralPath $root.FullName -Recurse -File -Force) {
        $rel = $f.FullName.Substring($root.FullName.Length + 1)
        $dest = Join-Path $AppDir $rel
        if ((Test-Path -LiteralPath $dest) -and (Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        try { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
        catch {
            # In use (a running BloxKit.exe): Windows still lets it be renamed, then the new one goes in its place.
            Move-Item -LiteralPath $dest -Destination "$dest.bloxkit-old" -Force
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
        $changed += $rel
        if ($rel -like "AutoJoinHelper*") { $helper = $true }
    }
    Say ("Replaced {0} file(s): {1}" -f $changed.Count, ($changed -join ", "))
    # The app reads this when it opens: it says it was updated (and whether the Chrome helper changed).
    Set-Content -Path (Join-Path $DataDir "updated.txt") -Value ("from $have to $new" + $(if ($helper) { " helper" } else { "" }))
    Say "Done: BloxKit $new."
    if ($Restart) { Start-App }
} catch {
    Fail $_.Exception.Message
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
