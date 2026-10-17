# Builds BloxKit.exe (the app you double-click) from launcher\BloxKit.cs.
#     powershell -ExecutionPolicy Bypass -File tools\build-app.ps1
# Uses the C# compiler and PowerShell that come with Windows; nothing to install.
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { throw "The .NET Framework 4 C# compiler wasn't found ($csc)." }
$sma = [psobject].Assembly.Location   # System.Management.Automation.dll (Windows PowerShell 5.1)
$out = Join-Path $root "BloxKit.exe"
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$out" "/win32icon:$(Join-Path $root 'assets\BloxKit.ico')" `
    "/reference:$sma" /reference:System.Windows.Forms.dll (Join-Path $root "launcher\BloxKit.cs")
if ($LASTEXITCODE -ne 0) { throw "The build failed." }
"Built $out"
