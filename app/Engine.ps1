# ChatGPT 定时发送助手 - 执行引擎（无界面，由界面程序调用）
# 所有输出保存在软件目录 output 下

param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ---------- 路径（便携：仅使用软件目录） ----------
$root = $env:CHATGPT_SENDER_HOME
if ($root) {
    $appDir = Join-Path $root 'app'
} else {
    $appDir = $PSScriptRoot
    if (-not $appDir) { $appDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $root = Split-Path -Parent $appDir
}
$interop = Join-Path $appDir 'Interop.dll'
[void][System.Reflection.Assembly]::LoadFrom($interop)
[void][ChatGPTTool.Win32]::SetProcessDPIAware()

if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) { exit 2 }

$cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tasks = @($cfg.Tasks)
$dryRun = [bool]$cfg.DryRun
$runFolder = [string]$cfg.RunFolder
if (-not $runFolder) {
    $runFolder = Join-Path (Join-Path $root 'output') (Get-Date -Format 'yyyyMMdd_HHmmss')
}
if (-not (Test-Path $runFolder)) { New-Item -ItemType Directory -Path $runFolder -Force | Out-Null }
$logPath = Join-Path $runFolder 'run.log'

function Log([string]$m) {
    $line = "$(Get-Date -Format 'HH:mm:ss.fff') $m"
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host $line
}

$SendLabel  = [string]([char]0x53D1) + [char]0x9001
$ResetLabel = [string]([char]0x91CD) + [char]0x7F6E + [char]0x4F7F + [char]0x7528 + [char]0x91CF

$script:win = $null
$script:hWnd = [IntPtr]::Zero

function Shot([string]$folder, [string]$name) {
    $file = Join-Path $folder ($name + '.png')
    $saved = $false
    try {
        if ($script:hWnd -ne [IntPtr]::Zero) {
            $rc = New-Object ChatGPTTool.RECT
            if ([ChatGPTTool.Win32]::GetWindowRect($script:hWnd, [ref]$rc)) {
                $w = $rc.Right - $rc.Left
                $h = $rc.Bottom - $rc.Top
                if ($w -gt 100 -and $h -gt 100) {
                    $bmp = New-Object System.Drawing.Bitmap $w, $h
                    $g = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.CopyFromScreen($rc.Left, $rc.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
                    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
                    $g.Dispose(); $bmp.Dispose()
                    $saved = $true
                }
            }
        }
    } catch {
        Log "窗口截图失败：$($_.Exception.Message)"
    }
    if (-not $saved) {
        try {
            $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, (New-Object System.Drawing.Size($vs.Width, $vs.Height)))
            $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose(); $bmp.Dispose()
            $saved = $true
        } catch {
            Log "全屏截图失败：$($_.Exception.Message)"
        }
    }
    if ($saved) { Log "截图：$file" } else { Log "截图未生成：$name" }
}
function KeyDownUp([byte]$vk) {
    [ChatGPTTool.Win32]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    [ChatGPTTool.Win32]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
}
function CtrlCombo([byte]$vk) {
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    [ChatGPTTool.Win32]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 120
    [ChatGPTTool.Win32]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    [ChatGPTTool.Win32]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
}
function Find-ByName([string]$name, [string[]]$typeNames) {
    $list = @()
    if (-not $name -or -not $script:win) { return $list }
    $all = $script:win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        if ($el.Current.IsOffscreen) { continue }
        if ($el.Current.Name -ne $name) { continue }
        if ($typeNames -and ($typeNames -notcontains $el.Current.ControlType.ProgrammaticName)) { continue }
        $list += $el
    }
    return $list
}
function Invoke-Control($el) {
    try {
        $p = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return $true }
        if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return $true }
    } catch {
        Log "控件 Invoke 失败：$($_.Exception.Message)"
    }
    try {
        $r = $el.Current.BoundingRectangle
        if ($r.Width -le 0 -or $r.Height -le 0) { return $false }
        $cx = [int]($r.X + $r.Width / 2)
        $cy = [int]($r.Y + $r.Height / 2)
        [void][ChatGPTTool.Win32]::SetCursorPos($cx, $cy)
        Start-Sleep -Milliseconds 150
        [ChatGPTTool.Win32]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 60
        [ChatGPTTool.Win32]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
        return $true
    } catch {
        Log "鼠标点击失败：$($_.Exception.Message)"
        return $false
    }
}
function Select-BestControl($items) {
    $sorted = $items | Sort-Object { $_.Current.BoundingRectangle.Y }
    foreach ($it in $sorted) {
        $p = $null
        if ($it.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { return $it }
    }
    return ($sorted | Select-Object -First 1)
}
function Get-SendButton {
    $all = $script:win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        if ($el.Current.ControlType.ProgrammaticName -eq 'ControlType.Button' -and $el.Current.Name -eq $SendLabel -and -not $el.Current.IsOffscreen) { return $el }
    }
    return $null
}
function Find-Composer {
    $edits = @()
    $all = $script:win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        if ($el.Current.ControlType.ProgrammaticName -eq 'ControlType.Edit' -and -not $el.Current.IsOffscreen) { $edits += $el }
    }
    if ($edits.Count -eq 0) { return $null }
    return ($edits | Sort-Object { $_.Current.BoundingRectangle.Y } -Descending | Select-Object -First 1)
}
function Wait-Foreground([int]$procId, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $fg = [ChatGPTTool.Win32]::GetForegroundWindow()
        if ($fg -ne [IntPtr]::Zero) {
            $fgPid = [uint32]0
            [void][ChatGPTTool.Win32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
            if ([int]$fgPid -eq $procId) { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
function Wait-ForDocument([string]$title, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Find-ByName $title @('ControlType.Document')).Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}
function Wait-ForComposer([int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $e = Find-Composer
        if ($e) { return $e }
        Start-Sleep -Milliseconds 400
    }
    return $null
}
function Wait-ForSendEnabled([int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $s = Get-SendButton
        if ($s) {
            $last = $s
            if ($s.Current.IsEnabled) { return $s }
        }
        Start-Sleep -Milliseconds 300
    }
    return $last
}
function Wait-ForSendDone([int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $s = Get-SendButton
        if (-not $s) { return $true }
        if (-not $s.Current.IsEnabled) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}
function Open-Chat([string]$ProjectName, [string]$ChatName) {
    if (-not $ChatName) { Log '未指定聊天名称，使用当前聊天'; return $true }
    if ((Find-ByName $ChatName @('ControlType.Document')).Count -gt 0) { Log "目标聊天已打开：$ChatName"; return $true }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($ProjectName -and $attempt -eq 1) {
            $proj = Find-ByName $ProjectName @('ControlType.Group', 'ControlType.Button', 'ControlType.ListItem', 'ControlType.TreeItem')
            if ($proj.Count -gt 0) {
                Log "点击项目：$ProjectName"
                [void](Invoke-Control (Select-BestControl $proj))
                Start-Sleep -Milliseconds 1500
            } else {
                Log "未找到项目入口：$ProjectName"
            }
        }
        $chats = Find-ByName $ChatName @('ControlType.Group', 'ControlType.Button', 'ControlType.ListItem', 'ControlType.TreeItem')
        if ($chats.Count -gt 0) {
            Log "点击聊天：$ChatName（第 $attempt 次尝试）"
            [void](Invoke-Control (Select-BestControl $chats))
            if (Wait-ForDocument $ChatName 12) {
                Log '已通过侧边栏打开聊天'
                return $true
            }
            Log '点击后暂未检测到聊天标题，等待后重试'
        } else {
            Log '侧边栏未找到聊天入口'
        }
        Start-Sleep -Milliseconds 800
    }

    Log '尝试使用聊天搜索（Ctrl+K）'
    $ws2 = New-Object -ComObject WScript.Shell
    if ($proc) { [void]$ws2.AppActivate([int]$proc.Id) }
    Start-Sleep -Milliseconds 600
    CtrlCombo 0x4B
    Start-Sleep -Milliseconds 1000
    Set-Clipboard -Value $ChatName
    CtrlCombo 0x56
    Start-Sleep -Milliseconds 1000
    KeyDownUp 0x0D
    if (Wait-ForDocument $ChatName 15) {
        Log '已通过搜索打开聊天'
        return $true
    }
    KeyDownUp 0x1B
    Log '警告：聊天切换失败，为避免发错聊天将跳过该任务'
    return $false
}

Log '===== ChatGPT 定时发送助手（引擎启动） ====='
Log "软件目录：$root"
Log "输出目录：$runFolder"
Log "任务数量：$($tasks.Count)"
if ($dryRun) { Log '试运行模式：只执行到粘贴，不发送' }

$sortedTasks = @($tasks | Sort-Object { [datetime]::Parse([string]$_.Time) })
$blocked = $false
$index = 0

foreach ($t in $sortedTasks) {
    $index++
    $taskTime = [datetime]::Parse([string]$t.Time)
    $proj = [string]$t.Project
    $chat = [string]$t.Chat
    $msg = [string]$t.Message
    $useReset = [bool]$t.UseReset
    $taskFolder = Join-Path $runFolder ("task{0:00}" -f $index)
    if (-not (Test-Path $taskFolder)) { New-Item -ItemType Directory -Path $taskFolder -Force | Out-Null }

    Log "===== 任务 $index / $($sortedTasks.Count)：时间=$($taskTime.ToString('yyyy-MM-dd HH:mm:ss'))，项目='$proj'，聊天='$chat' ====="

    if ((Get-Date) -lt $taskTime) {
        Log "等待到任务时间 $($taskTime.ToString('yyyy-MM-dd HH:mm:ss')) ..."
        $lastReport = -1
        while ((Get-Date) -lt $taskTime) {
            $left = [int]($taskTime - (Get-Date)).TotalSeconds
            if ($left -ne $lastReport -and ($left % 60) -eq 0) {
                $lastReport = $left
                Log "等待中，剩余 $left 秒"
            }
            Start-Sleep -Milliseconds 200
        }
    } else {
        Log '任务时间已过，立即执行'
    }
    Log '到达任务时间，开始自动化操作'

    try {
        $proc = $null
        for ($r = 1; $r -le 3; $r++) {
            $proc = Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($proc) { break }
            Log "第 $r 次未找到 ChatGPT 窗口，2 秒后重试"
            Start-Sleep -Seconds 2
        }
        if (-not $proc) {
            Log '错误：ChatGPT 未运行，跳过该任务'
            continue
        }
        $script:hWnd = [IntPtr]$proc.MainWindowHandle
        [void][ChatGPTTool.Win32]::ShowWindow($script:hWnd, 9)
        $ws = New-Object -ComObject WScript.Shell
        [void]$ws.AppActivate([int]$proc.Id)
        if (-not (Wait-Foreground $proc.Id 6)) {
            Log '警告：ChatGPT 未能切换到前台（可能锁屏或被占用），跳过该任务'
            Shot $taskFolder '01_not_foreground'
            continue
        }
        Log 'ChatGPT 已切换到前台'
        Start-Sleep -Milliseconds 600

        $script:win = $null
        for ($r = 1; $r -le 3; $r++) {
            $rootEl = [System.Windows.Automation.AutomationElement]::RootElement
            $pidCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
            $script:win = $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Children, $pidCond)
            if ($script:win) { break }
            Log "第 $r 次未获取 UI 自动化窗口，等待重试"
            Start-Sleep -Milliseconds 800
        }
        if (-not $script:win) {
            Log '错误：无法连接 ChatGPT 界面，跳过该任务'
            continue
        }
        Shot $taskFolder '01_activated'

        if (-not (Open-Chat $proj $chat)) {
            Shot $taskFolder '02_chat_failed'
            continue
        }
        Start-Sleep -Milliseconds 800
        Shot $taskFolder '02_chat'

        $edit = Wait-ForComposer 10
        if (-not $edit) {
            Log '未找到输入框，重新激活窗口后重试'
            [void]$ws.AppActivate([int]$proc.Id)
            Start-Sleep -Seconds 1
            $edit = Wait-ForComposer 8
        }
        if (-not $edit) {
            Log '错误：未找到消息输入框，跳过该任务'
            Shot $taskFolder '03_no_composer'
            continue
        }
        $edit.SetFocus()
        $focusDeadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $focusDeadline) {
            if ($edit.Current.HasKeyboardFocus) { break }
            Start-Sleep -Milliseconds 200
        }
        Log "已聚焦输入框：$($edit.Current.Name)"
        Start-Sleep -Milliseconds 500

        CtrlCombo 0x41
        KeyDownUp 0x2E
        Start-Sleep -Milliseconds 400
        Set-Clipboard -Value $msg
        $clip = Get-Clipboard -Raw
        if ($clip -ne $msg) {
            Log '剪贴板内容不一致，重试一次'
            Set-Clipboard -Value $msg
            Start-Sleep -Milliseconds 300
            $clip = Get-Clipboard -Raw
        }
        Log "剪贴板写入完成，内容一致=$($clip -eq $msg)"
        CtrlCombo 0x56
        $send = Wait-ForSendEnabled 10
        Shot $taskFolder '03_input'

        if ($dryRun) {
            Log '试运行：已粘贴内容并截图，现在清空输入框，不发送'
            CtrlCombo 0x41
            KeyDownUp 0x2E
            Start-Sleep -Milliseconds 300
            Shot $taskFolder '04_dryrun_cleared'
            continue
        }

        if ((!$send) -or (-not $send.Current.IsEnabled)) {
            if ($useReset) {
                Log '发送按钮被禁用，按任务设置点击“重置使用量”'
                $resets = Find-ByName $ResetLabel @('ControlType.Button')
                if ($resets.Count -gt 0) {
                    [void](Invoke-Control ($resets | Select-Object -First 1))
                    Log '已点击重置按钮，等待额度生效'
                    Start-Sleep -Seconds 4
                    $send = Wait-ForSendEnabled 10
                    Shot $taskFolder '04_after_reset'
                } else {
                    Log '未找到重置按钮'
                }
            }
        }

        if ($send -and -not $send.Current.IsEnabled) {
            Log '已阻止发送：发送按钮不可用（额度或速率限制），内容保留在输入框'
            Shot $taskFolder '04_blocked'
            $blocked = $true
            break
        }

        if ($send) { Log "发送按钮可用状态：$($send.Current.IsEnabled)" } else { Log '未找到发送按钮，将按回车尝试' }

        KeyDownUp 0x0D
        Log '已按回车，等待发送结果反馈...'
        $done = Wait-ForSendDone 15
        if (-not $done) {
            Log '未确认发送完成，尝试点击发送按钮'
            $s2 = Get-SendButton
            if ($s2 -and $s2.Current.IsEnabled) {
                [void](Invoke-Control $s2)
                $done = Wait-ForSendDone 8
            }
        }
        if ($done) {
            Log '已确认消息提交'
        } else {
            Log '警告：未能确认发送结果，请查看截图'
        }
        Shot $taskFolder '04_after_send'
    } catch {
        Log "任务 $index 执行异常：$($_.Exception.Message)"
        try { Shot $taskFolder '99_error' } catch { }
    }

    Start-Sleep -Milliseconds 1200
}

if ($blocked) {
    Log '整体结束：因额度限制提前终止'
} else {
    Log '整体结束：全部任务已处理'
}
exit 0
