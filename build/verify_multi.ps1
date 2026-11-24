# 多任务勾选与重置额度提醒验证（开发用）
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'ChatGPTAutoSender.exe'
$shots = Join-Path $PSScriptRoot 'verify_multi'
New-Item -ItemType Directory -Path $shots -Force | Out-Null

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $root 'app\Interop.dll'))
[void][ChatGPTTool.Win32]::SetProcessDPIAware()

function Log([string]$m) { Write-Host $m }
function Shot([string]$name) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $b.Size)
    $file = Join-Path $shots ($name + '.png')
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Log "SHOT $file"
}
function Click($x, $y) {
    [void][ChatGPTTool.Win32]::SetCursorPos([int]$x, [int]$y)
    Start-Sleep -Milliseconds 150
    [ChatGPTTool.Win32]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [ChatGPTTool.Win32]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 250
}
function Click-El($el) {
    try {
        $p = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return }
    } catch { }
    $r = $el.Current.BoundingRectangle
    Click ($r.X + $r.Width / 2) ($r.Y + $r.Height / 2)
}
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
function Find-TextMatch($win, $pattern) {
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) { if ($el.Current.Name -match $pattern) { return $el } }
    return $null
}
function Set-Value($el, $text) {
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $p.SetValue($text); return }
    $r = $el.Current.BoundingRectangle
    Click ($r.X + 30) ($r.Y + $r.Height / 2)
    Set-Clipboard -Value $text
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    [ChatGPTTool.Win32]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 150
}
function Get-DialogInputs($dlg) {
    $ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $dc = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
    $list = @()
    $list += $dlg.FindAll([System.Windows.Automation.TreeScope]::Descendants, $ec)
    $list += $dlg.FindAll([System.Windows.Automation.TreeScope]::Descendants, $dc)
    return @($list | Sort-Object { $_.Current.BoundingRectangle.Y })
}
function Add-Task($mainWin, $procId, $time, $proj, $chat, $msg, [bool]$reset) {
    $addMatches = @(Find-Name $mainWin '添加任务')
    foreach ($m in $addMatches) { Log ("诊断: 添加任务元素 type=" + $m.Current.ControlType.ProgrammaticName + " rect=" + $m.Current.BoundingRectangle) }
    $addBtn = $addMatches | Where-Object { $_.Current.BoundingRectangle.Width -gt 0 } | Select-Object -First 1
    if (-not $addBtn) { throw 'add button not found' }
    Click-El $addBtn
    Start-Sleep -Milliseconds 600
    $dlg = Wait-Win $procId '添加任务' 6
    if (-not $dlg) { throw 'add dialog not found' }
    $inputs = Get-DialogInputs $dlg
    if ($inputs.Count -lt 4) { throw ('dialog inputs=' + $inputs.Count) }
    Set-Value $inputs[0] $time
    Set-Value $inputs[1] $proj
    Set-Value $inputs[2] $chat
    Set-Value $inputs[3] $msg
    if ($reset) {
        $chk = $null
        foreach ($el in $dlg.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            if ($el.Current.Name -like '本任务额度不足时自动点击*') { $chk = $el; break }
        }
        if ($chk) { Click-El $chk }
    }
    Click-El ((Find-Name $dlg '保存')[0])
    Start-Sleep -Milliseconds 900
}

# ---------- 阶段 1：勾选控制 ----------
$p = Start-Process $exe -PassThru
Start-Sleep -Seconds 4
$main = Get-Top $p.Id
Add-Task $main $p.Id '2026-12-31 09:30:00' 'first_project' 'First Chat' '第一个任务内容' $false
Add-Task $main $p.Id '2026-12-31 18:00:00' 'second_project' 'Second Chat' '第二个任务内容' $false
Shot '01_two_tasks'

$table = $null
foreach ($el in $main.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($el.Current.ControlType.ProgrammaticName -match 'Table|DataGrid') { $table = $el; break }
}
if ($table) {
    $tr = $table.Current.BoundingRectangle
    Click ($tr.X + 28) ($tr.Y + 34 + 17)
    Start-Sleep -Milliseconds 500
    Log '已点击第一行复选框（取消勾选）'
    Shot '02_unchecked_first'
} else {
    Log 'FAIL: 未找到表格控件'
}

$countText = Find-TextMatch $main '勾选 1 个'
if ($countText) { Log 'PASS: 勾选计数已变为 1' } else { Log 'FAIL: 勾选计数未变化' }

Click-El ((Find-Name $main '开始执行')[0])
$startMsg = Wait-Win $p.Id '开始执行' 4
if ($startMsg) {
    Log 'PASS: 出现开始确认框'
    Shot '03_start_confirm'
    $yes = $null
    foreach ($b in $startMsg.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($b.Current.Name -match '是|Yes') { $yes = $b; break }
    }
    if ($yes) { Click-El $yes }
    Start-Sleep -Seconds 3
    $newRun = Get-ChildItem (Join-Path $root 'output') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newRun) {
        $cfgPath = Join-Path $newRun.FullName 'config.json'
        if (Test-Path $cfgPath) {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $tasks = @($cfg.Tasks)
            Log ('本次配置任务数=' + $tasks.Count + '，项目=' + (($tasks | ForEach-Object { $_.Project }) -join ','))
            if ($tasks.Count -eq 1 -and $tasks[0].Project -eq 'second_project') {
                Log 'PASS: 只执行勾选的任务（第二个）'
            } else {
                Log 'FAIL: 勾选控制不符合预期'
            }
        } else {
            Log 'FAIL: 未找到 config.json'
        }
    } else {
        Log 'FAIL: 未创建运行目录'
    }
    Click-El ((Find-Name $main '取消任务')[0])
    Start-Sleep -Milliseconds 800
} else {
    Log 'FAIL: 开始确认框未出现'
}

Stop-Process -Id $p.Id -Force
Start-Sleep -Milliseconds 500

# ---------- 阶段 2：多次重置额度提醒 ----------
$p2 = Start-Process $exe -PassThru
Start-Sleep -Seconds 4
$main2 = Get-Top $p2.Id
Add-Task $main2 $p2.Id '2026-12-31 09:30:00' 'reset_a' 'Reset A' '重置任务一' $true
Add-Task $main2 $p2.Id '2026-12-31 18:00:00' 'reset_b' 'Reset B' '重置任务二' $true
Shot '04_two_reset_tasks'
Click-El ((Find-Name $main2 '开始执行')[0])
$warn = Wait-Win $p2.Id '重置额度风险提示' 4
if ($warn) {
    Log 'PASS: 出现重置额度风险提示'
    Shot '05_reset_warning'
    $no = $null
    foreach ($b in $warn.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($b.Current.Name -match '否|No') { $no = $b; break }
    }
    if ($no) { Click-El $no }
    Start-Sleep -Milliseconds 800
    $confirm = Get-Win $p2.Id '开始执行'
    if (-not $confirm) { Log 'PASS: 选择“否”后未开始执行' } else { Log 'FAIL: 选择“否”后仍出现开始确认框' }
} else {
    Log 'FAIL: 未出现重置额度风险提示'
    Shot '05_reset_warning_missing'
}
Stop-Process -Id $p2.Id -Force
Log '验证结束'
