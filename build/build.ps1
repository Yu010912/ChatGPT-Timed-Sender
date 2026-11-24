$ErrorActionPreference = 'Stop'
$buildDir = $PSScriptRoot
$root = Split-Path -Parent $buildDir
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }
$sma = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\System.Management.Automation.dll'
if (-not (Test-Path $sma)) {
    $gacRoot = Join-Path $env:WINDIR 'Microsoft.Net\assembly\GAC_MSIL\System.Management.Automation'
    if (Test-Path $gacRoot) {
        $found = Get-ChildItem $gacRoot -Recurse -Filter 'System.Management.Automation.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $sma = $found.FullName }
    }
}
if (-not (Test-Path $sma)) { throw "System.Management.Automation.dll not found" }

& $csc /nologo /target:library /optimize+ /out:"$root\app\Interop.dll" "$buildDir\Interop.cs"
if ($LASTEXITCODE -ne 0) { throw 'Interop build failed' }

$icon = Join-Path $root 'app\app.ico'
if (-not (Test-Path $icon)) { throw 'app.ico not found. Run build\make_icon.ps1 first.' }

& $csc /nologo /target:winexe /platform:anycpu /optimize+ /out:"$root\ChatGPTAutoSender.exe" /win32icon:"$icon" /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:"$sma" "$buildDir\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw 'EXE build failed' }

Write-Host 'Build OK'
