# 生成 README 截图（开发用）
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'ChatGPTAutoSender.exe'
$docs = Join-Path $root 'docs'
New-Item -ItemType Directory -Path $docs -Force | Out-Null

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $root 'app\Interop.dll'))
[void][ChatGPTTool.Win32]::SetProcessDPIAware()

function Get-Top($procId) {
    $rootEl = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    return $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
}
function Get-Win($procId, $title) {
    $top = Get-Top $procId
    $els = $top.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $els) {
        if ($el.Current.ControlType.ProgrammaticName -eq 'ControlType.Window' -and $el.Current.Name -eq $title) { return $el }
    }
    return $null
}
function Wait-Win($procId, $title, $sec) {
    $deadline = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $deadline) {
        $w = Get-Win $procId $title
        if ($w) { return $w }
        Start-Sleep -Milliseconds 300
    }
    return $null
}
function Find-Name($win, $name) {
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $list = @()
    foreach ($el in $all) { if ($el.Current.Name -eq $name -and -not $el.Current.IsOffscreen) { $list += $el } }
    return $list
}
function Click-El($el) {
    try {
        $p = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return }
    } catch { }
    $r = $el.Current.BoundingRectangle
    [void][ChatGPTTool.Win32]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 150
    [ChatGPTTool.Win32]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [ChatGPTTool.Win32]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}
function Set-Value($el, $text) {
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $p.SetValue($text); return }
    $r = $el.Current.BoundingRectangle
    [void][ChatGPTTool.Win32]::SetCursorPos([int]($r.X + 30), [int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 150
    [ChatGPTTool.Win32]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [ChatGPTTool.Win32]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    Set-Clipboard -Value $text
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    [ChatGPTTool.Win32]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 150
}
function Add-Task($mainWin, $procId, $time, $proj, $chat, $msg) {
    $btn = (Find-Name $mainWin '添加任务')[0]
    Click-El $btn
    $dlg = Wait-Win $procId '添加任务' 5
    if (-not $dlg) { throw 'dialog not found' }
    $inputs = @()
    $inputs += $dlg.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)))
    $inputs += $dlg.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)))
    $arr = @()
    foreach ($i in $inputs) { $arr += $i }
    $arr = @($arr | Sort-Object { $_.Current.BoundingRectangle.Y })
    Set-Value $arr[0] $time
    Set-Value $arr[1] $proj
    Set-Value $arr[2] $chat
    Set-Value $arr[3] $msg
    Click-El ((Find-Name $dlg '保存')[0])
    Start-Sleep -Milliseconds 800
}

$p = Start-Process $exe -PassThru
Start-Sleep -Seconds 4
$main = Get-Top $p.Id
Add-Task $main $p.Id '2026-12-31 09:30:00' 'my_project' 'My Chat' '继续'
Add-Task $main $p.Id '2026-12-31 18:00:00' 'demo_project' 'Demo Chat' '请继续生成下一段内容'
Start-Sleep -Milliseconds 600

$cs = @(
'using System;',
'using System.Runtime.InteropServices;',
'public struct RECTS { public int L; public int T; public int R; public int B; }',
'public class WS { [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECTS r); }'
) -join "`n"
Add-Type -TypeDefinition $cs -ErrorAction SilentlyContinue
$r = New-Object RECTS
[void][WS]::GetWindowRect($p.MainWindowHandle, [ref]$r)
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$full = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($full)
$g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $vs.Size)
$w = $r.R - $r.L
$h = $r.B - $r.T
$crop = New-Object System.Drawing.Bitmap $w, $h
$g2 = [System.Drawing.Graphics]::FromImage($crop)
$g2.DrawImage($full, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)), (New-Object System.Drawing.Rectangle(($r.L - $vs.X), ($r.T - $vs.Y), $w, $h)), [System.Drawing.GraphicsUnit]::Pixel)
$crop.Save((Join-Path $docs 'screenshot.png'), [System.Drawing.Imaging.ImageFormat]::Png)
Copy-Item (Join-Path $root 'app\icon.png') (Join-Path $docs 'icon.png') -Force
$g.Dispose(); $g2.Dispose(); $full.Dispose(); $crop.Dispose()
Stop-Process -Id $p.Id -Force
Write-Host 'Docs images created'
