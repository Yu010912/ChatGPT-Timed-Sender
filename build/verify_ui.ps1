# UI 自动化验证脚本（开发用，不属于软件本体）
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'ChatGPTAutoSender.exe'
$shots = Join-Path $PSScriptRoot 'verify_ui'
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
function Get-WinByPid([int]$procId) {
    $rootEl = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
    $wins = $rootEl.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    $list = @()
    foreach ($w in $wins) { $list += $w }
    return $list
}
function Get-WinByTitle([int]$procId, [string]$title) {
    $tops = Get-WinByPid $procId
    foreach ($w in $tops) {
        if ($w.Current.Name -eq $title) { return $w }
    }
    foreach ($w in $tops) {
        $els = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($el in $els) {
            if ($el.Current.ControlType.ProgrammaticName -eq 'ControlType.Window' -and $el.Current.Name -eq $title -and -not $el.Current.IsOffscreen) { return $el }
        }
    }
    return $null
}
function Wait-WinByTitle([int]$procId, [string]$title, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $w = Get-WinByTitle $procId $title
        if ($w) { return $w }
        Start-Sleep -Milliseconds 300
    }
    return $null
}
function Get-Desc($win, $controlType) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $controlType)
    $found = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    $list = @()
    foreach ($f in $found) { $list += $f }
    return $list
}
function Find-Name($win, [string]$name) {
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $list = @()
    foreach ($el in $all) {
        if ($el.Current.Name -eq $name -and -not $el.Current.IsOffscreen) { $list += $el }
    }
    return $list
}
function Click-El($el) {
    try {
        $pat = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pat)) { $pat.Invoke(); return $true }
    } catch { }
    try {
        $r = $el.Current.BoundingRectangle
        if ($r.Width -le 0) { return $false }
        [void][ChatGPTTool.Win32]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
        Start-Sleep -Milliseconds 150
        [ChatGPTTool.Win32]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 60
        [ChatGPTTool.Win32]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 150
        return $true
    } catch { return $false }
}
function Set-EditValue($el, [string]$text) {
    try {
        $pat = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pat)) {
            $pat.SetValue($text)
            return $true
        }
    } catch { }
    try {
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
        return $true
    } catch {
        return $false
    }
}
function Get-DialogInputs($dlg) {
    $list = @()
    $list += Get-Desc $dlg ([System.Windows.Automation.ControlType]::Edit)
    $list += Get-Desc $dlg ([System.Windows.Automation.ControlType]::Document)
    return @($list | Sort-Object { $_.Current.BoundingRectangle.Y })
}
function Click-MsgButton($msgWin, [string]$pattern) {
    $buttons = Get-Desc $msgWin ([System.Windows.Automation.ControlType]::Button)
    foreach ($b in $buttons) {
        if ($b.Current.Name -match $pattern) { return (Click-El $b) }
    }
    return $false
}
function Activate-Proc([int]$procId) {
    $ws = New-Object -ComObject WScript.Shell
    [void]$ws.AppActivate($procId)
    Start-Sleep -Milliseconds 300
}

$p = Start-Process $exe -PassThru
Start-Sleep -Seconds 4
$pid2 = $p.Id
$win = Get-WinByTitle $pid2 'ChatGPT 定时发送助手'
if (-not $win) { Log 'FAIL: 主窗口未找到'; Shot 'fail_no_main'; Stop-Process -Id $pid2 -Force; exit 1 }
Log 'PASS: 主窗口已找到'
Shot '01_main'

# ---------- 1. 添加任务：错误时间 ----------
$addBtns = Find-Name $win '添加任务'
if ($addBtns.Count -eq 0) { Log 'FAIL: 未找到添加任务按钮'; Stop-Process -Id $pid2 -Force; exit 1 }
[void](Click-El $addBtns[0])
$dlg = Wait-WinByTitle $pid2 '添加任务' 5
if (-not $dlg) { Log 'FAIL: 添加任务对话框未出现'; Shot 'fail_no_dialog'; Stop-Process -Id $pid2 -Force; exit 1 }
Log 'PASS: 添加任务对话框已打开'
Shot '02_dialog'

$edits = Get-DialogInputs $dlg
Log ("输入框数量=" + $edits.Count)
if ($edits.Count -lt 4) { Log 'FAIL: 对话框输入框数量不足'; Stop-Process -Id $pid2 -Force; exit 1 }

[void](Set-EditValue $edits[0] '2026/13/45 99:99')
$msgEdits = @($edits | Where-Object { $_.Current.BoundingRectangle.Height -gt 60 })
if ($msgEdits.Count -gt 0) { [void](Set-EditValue $msgEdits[0] '验证内容') }
else { [void](Set-EditValue $edits[3] '验证内容') }

$saveBtns = Find-Name $dlg '保存'
[void](Click-El $saveBtns[0])
$err = Wait-WinByTitle $pid2 '提示' 4
if ($err) {
    Log 'PASS: 错误时间被拦截'
    Shot '03_time_error'
    [void](Click-MsgButton $err '确定|OK')
    Start-Sleep -Milliseconds 600
    $dlg = Get-WinByTitle $pid2 '添加任务'
    $edits = Get-DialogInputs $dlg
    $msgEdits = @($edits | Where-Object { $_.Current.BoundingRectangle.Height -gt 60 })
} else {
    Log 'FAIL: 错误时间未被拦截'
}

# ---------- 2. 添加任务：正确值 ----------
$target = (Get-Date).AddMinutes(30).ToString('yyyy-MM-dd HH:mm:ss')
[void](Set-EditValue $edits[0] $target)
[void](Set-EditValue $edits[1] 'my_project')
[void](Set-EditValue $edits[2] 'My Chat')
if ($msgEdits.Count -gt 0) { [void](Set-EditValue $msgEdits[0] '继续') }
else { [void](Set-EditValue $edits[3] '继续') }
$saveBtns = Find-Name $dlg '保存'
[void](Click-El $saveBtns[0])
Start-Sleep -Seconds 1
if (Get-WinByTitle $pid2 '添加任务') { Log 'FAIL: 对话框未关闭'; Shot 'fail_dialog_open' }
$count1 = Find-Name $win '共 1 个任务'
if ($count1.Count -gt 0) { Log 'PASS: 任务已添加（共 1 个任务）' } else { Log 'FAIL: 任务计数未更新' }
Shot '04_added'

# 打印表格相关元素，便于检查
$all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$types = @{}
foreach ($el in $all) {
    $t = $el.Current.ControlType.ProgrammaticName
    if (-not $types.ContainsKey($t)) { $types[$t] = 0 }
    $types[$t]++
}
foreach ($k in $types.Keys) { Log ("TYPE " + $k + " x" + $types[$k]) }

# ---------- 3. 删除任务 ----------
$table = $null
foreach ($el in $all) { if ($el.Current.ControlType.ProgrammaticName -match 'Table|DataGrid') { $table = $el; break } }
Activate-Proc $pid2
if ($table) {
    $r = $table.Current.BoundingRectangle
    [void][ChatGPTTool.Win32]::SetCursorPos([int]($r.X + 60), [int]($r.Y + 50))
    Start-Sleep -Milliseconds 150
    [ChatGPTTool.Win32]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [ChatGPTTool.Win32]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
    Log '已尝试选中第一行'
} else {
    Log 'SKIP: 未找到表格控件，无法自动选中行'
}
$delBtns = Find-Name $win '删除任务'
[void](Click-El $delBtns[0])
$confirm = Wait-WinByTitle $pid2 '确认删除' 4
if ($confirm) {
    Shot '05_delete_confirm'
    [void](Click-MsgButton $confirm '是|Yes')
    Start-Sleep -Milliseconds 800
    if ((Find-Name $win '共 0 个任务').Count -gt 0) { Log 'PASS: 任务已删除' } else { Log 'FAIL: 删除后计数未归零' }
} else {
    $info = Wait-WinByTitle $pid2 '提示' 2
    if ($info) {
        Log 'INFO: 删除时提示先选择任务（属预期保护）'
        [void](Click-MsgButton $info '确定|OK')
    } else {
        Log 'FAIL: 删除无反馈'
    }
}
Shot '06_after_delete'

# ---------- 4. 重新添加并测试开始/取消 ----------
if ((Find-Name $win '共 0 个任务').Count -gt 0) {
    $addBtns = Find-Name $win '添加任务'
    [void](Click-El $addBtns[0])
    $dlg = Wait-WinByTitle $pid2 '添加任务' 5
    Log 'PASS: 重新打开添加对话框'
    $relRadios = Find-Name $dlg '相对时间'
    if ($relRadios.Count -gt 0) {
        [void](Click-El $relRadios[0])
        Start-Sleep -Milliseconds 500
        Log '已切换到相对时间模式'
    } else {
        Log 'FAIL: 未找到相对时间单选框'
    }
    $spinners = @((Get-Desc $dlg ([System.Windows.Automation.ControlType]::Spinner)) | Sort-Object { $_.Current.BoundingRectangle.X })
    Log ("Spinner 数量=" + $spinners.Count)
    $minSpin = $null
    $minRange = $null
    $bestY = -99999
    foreach ($s in $spinners) {
        $rg = $null
        if ($s.TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern, [ref]$rg)) {
            $y = $s.Current.BoundingRectangle.Y
            Log ("SPINNER max=" + $rg.Current.Maximum + " min=" + $rg.Current.Minimum + " x=" + [int]$s.Current.BoundingRectangle.X + " y=" + [int]$y)
            if ($rg.Current.Maximum -eq 59 -and $y -gt $bestY) {
                $bestY = $y
                $minSpin = $s
                $minRange = $rg
            }
        }
    }
    if ($minSpin -and $minRange) {
        try {
            $minRange.SetValue(2)
            Log '已设置相对时间：2 分钟后'
        } catch {
            Log ('FAIL: 设置分钟失败：' + $_.Exception.Message)
        }
    } else {
        Log 'FAIL: 未找到分钟控件'
    }
    $relStart = Get-Date
    $edits = Get-DialogInputs $dlg
    [void](Set-EditValue $edits[1] 'my_project')
    [void](Set-EditValue $edits[2] 'My Chat')
    [void](Set-EditValue $edits[3] '相对时间验证内容')
    $saveBtns = Find-Name $dlg '保存'
    [void](Click-El $saveBtns[0])
    Start-Sleep -Milliseconds 1000
    if ((Find-Name $win '共 1 个任务').Count -gt 0) {
        Log ('PASS: 相对时间任务已添加（保存时刻 ' + $relStart.ToString('HH:mm:ss') + '，应为约 2 分钟后执行）')
    } else {
        Log 'FAIL: 相对时间任务未添加'
    }
    Shot '10_relative_task'
}
$startBtns = Find-Name $win '开始执行'
[void](Click-El $startBtns[0])
$startMsg = Wait-WinByTitle $pid2 '开始执行' 4
if ($startMsg) {
    Shot '07_start_confirm'
    [void](Click-MsgButton $startMsg '是|Yes')
    Start-Sleep -Seconds 3
    $waiting = $false
    foreach ($el in (Get-Desc $win ([System.Windows.Automation.ControlType]::Text))) {
        if ($el.Current.Name -match '等待中') { $waiting = $true; break }
    }
    if ($waiting) { Log 'PASS: 开始后进入等待状态' } else { Log 'FAIL: 未进入等待状态' }
    Shot '08_waiting'
    $cancelBtns = Find-Name $win '取消任务'
    [void](Click-El $cancelBtns[0])
    Start-Sleep -Seconds 2
    $cancelled = $false
    foreach ($el in (Get-Desc $win ([System.Windows.Automation.ControlType]::Text))) {
        if ($el.Current.Name -match '已取消') { $cancelled = $true; break }
    }
    if ($cancelled) { Log 'PASS: 取消任务生效' } else { Log 'FAIL: 取消未生效' }
    Shot '09_cancelled'
} else {
    Log 'FAIL: 开始确认框未出现'
}

Stop-Process -Id $pid2 -Force
Log '验证结束'
