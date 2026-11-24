# ChatGPT Timed Sender - execution engine (no UI, launched by the app)
# All outputs stay inside the app folder.

param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ---------- Paths (portable: app folder only) ----------
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

# Localized button names are built from code points so the source stays ASCII.
$cnSend = [string]([char]0x53D1) + [char]0x9001
$cnReset = [string]([char]0x91CD) + [char]0x7F6E + [char]0x4F7F + [char]0x7528 + [char]0x91CF
$script:sendPattern = '(?i)(^Send$|Send message|' + $cnSend + ')'
$script:resetPattern = '(?i)(reset.*usage|reset.*limit|' + $cnReset + ')'

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
        Log "Window screenshot failed: $($_.Exception.Message)"
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
            Log "Full-screen screenshot failed: $($_.Exception.Message)"
        }
    }
    if ($saved) { Log "Screenshot: $file" } else { Log "Screenshot not created: $name" }
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
function Find-ButtonByRegex([string]$pattern) {
    if (-not $script:win) { return $null }
    $all = $script:win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        if ($el.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        if ($el.Current.IsOffscreen) { continue }
        if ($el.Current.Name -match $pattern) { return $el }
    }
    return $null
}
function Invoke-Control($el) {
    try {
        $p = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return $true }
        if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return $true }
    } catch {
        Log "Control invoke failed: $($_.Exception.Message)"
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
        Log "Mouse click failed: $($_.Exception.Message)"
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
    return (Find-ButtonByRegex $script:sendPattern)
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
    if (-not $ChatName) { Log 'No chat name given; using the current chat'; return $true }
    if ((Find-ByName $ChatName @('ControlType.Document')).Count -gt 0) { Log "Target chat is already open: $ChatName"; return $true }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($ProjectName -and $attempt -eq 1) {
            $proj = Find-ByName $ProjectName @('ControlType.Group', 'ControlType.Button', 'ControlType.ListItem', 'ControlType.TreeItem')
            if ($proj.Count -gt 0) {
                Log "Clicking project: $ProjectName"
                [void](Invoke-Control (Select-BestControl $proj))
                Start-Sleep -Milliseconds 1500
            } else {
                Log "Project not found: '$ProjectName'. Check the exact name in the project list (case and punctuation matter)."
            }
        }
        $chats = Find-ByName $ChatName @('ControlType.Group', 'ControlType.Button', 'ControlType.ListItem', 'ControlType.TreeItem')
        if ($chats.Count -gt 0) {
            Log "Clicking chat: $ChatName (attempt $attempt)"
            [void](Invoke-Control (Select-BestControl $chats))
            if (Wait-ForDocument $ChatName 12) {
                Log 'Chat opened from the sidebar'
                return $true
            }
            Log 'Chat title not detected yet; retrying after a short wait'
        } else {
            Log "Chat not found in the sidebar: '$ChatName'. Check the exact chat title in that project."
        }
        Start-Sleep -Milliseconds 800
    }

    Log 'Trying chat search (Ctrl+K)'
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
        Log 'Chat opened from search'
        return $true
    }
    KeyDownUp 0x1B
    Log "Could not open chat '$ChatName'. Skipping this task to avoid sending to the wrong chat."
    return $false
}

Log '===== ChatGPT Timed Sender (engine started) ====='
Log "App folder: $root"
Log "Output folder: $runFolder"
Log "Task count: $($tasks.Count)"
if ($dryRun) { Log 'Dry run: paste and screenshot only, no sending' }

$sortedTasks = @($tasks | Sort-Object { [datetime]::Parse([string]$_.Time) })
$okCount = 0
$skipCount = 0
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

    Log "===== Task $index / $($sortedTasks.Count): time=$($taskTime.ToString('yyyy-MM-dd HH:mm:ss')), project='$proj', chat='$chat' ====="

    if ((Get-Date) -lt $taskTime) {
        Log "Waiting until $($taskTime.ToString('yyyy-MM-dd HH:mm:ss')) ..."
        $lastReport = -1
        while ((Get-Date) -lt $taskTime) {
            $left = [int]($taskTime - (Get-Date)).TotalSeconds
            if ($left -ne $lastReport -and ($left % 60) -eq 0) {
                $lastReport = $left
                Log "Waiting, $left seconds left"
            }
            Start-Sleep -Milliseconds 200
        }
    } else {
        Log 'Task time already passed; running now'
    }
    Log 'Task time reached; starting automation'

    try {
        $proc = $null
        for ($r = 1; $r -le 3; $r++) {
            $proc = Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($proc) { break }
            Log "ChatGPT window not found (attempt $r); retrying in 2 seconds"
            Start-Sleep -Seconds 2
        }
        if (-not $proc) {
            Log 'ChatGPT window not found. Start and sign in to the ChatGPT desktop app. Remaining tasks cannot run.'
            break
        }
        $script:hWnd = [IntPtr]$proc.MainWindowHandle
        [void][ChatGPTTool.Win32]::ShowWindow($script:hWnd, 9)
        $ws = New-Object -ComObject WScript.Shell
        [void]$ws.AppActivate([int]$proc.Id)
        if (-not (Wait-Foreground $proc.Id 6)) {
            Log "Task $index skipped: ChatGPT could not be brought to the foreground (screen locked or another app is blocking). Nothing was sent."
            $skipCount++
            Shot $taskFolder '01_not_foreground'
            continue
        }
        Log 'ChatGPT is in the foreground'
        Start-Sleep -Milliseconds 600

        $script:win = $null
        for ($r = 1; $r -le 3; $r++) {
            $rootEl = [System.Windows.Automation.AutomationElement]::RootElement
            $pidCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
            $script:win = $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Children, $pidCond)
            if ($script:win) { break }
            Log "UI Automation window not available (attempt $r); retrying"
            Start-Sleep -Milliseconds 800
        }
        if (-not $script:win) {
            Log "Task $index skipped: could not attach to the ChatGPT UI (the app may be updating or still loading)."
            $skipCount++
            continue
        }
        Shot $taskFolder '01_activated'

        if (-not (Open-Chat $proj $chat)) {
            Log "Task $index skipped: chat '$chat' could not be confirmed. Nothing was sent. Check project '$proj' and the chat name."
            $skipCount++
            Shot $taskFolder '02_chat_failed'
            continue
        }
        Start-Sleep -Milliseconds 800
        Shot $taskFolder '02_chat'

        $edit = Wait-ForComposer 10
        if (-not $edit) {
            Log 'Composer not found; reactivating the window and retrying'
            [void]$ws.AppActivate([int]$proc.Id)
            Start-Sleep -Seconds 1
            $edit = Wait-ForComposer 8
        }
        if (-not $edit) {
            Log "Task $index skipped: message composer not found; the chat UI may not be fully loaded."
            $skipCount++
            Shot $taskFolder '03_no_composer'
            continue
        }
        $edit.SetFocus()
        $focusDeadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $focusDeadline) {
            if ($edit.Current.HasKeyboardFocus) { break }
            Start-Sleep -Milliseconds 200
        }
        Log "Composer focused: $($edit.Current.Name)"
        Start-Sleep -Milliseconds 500

        CtrlCombo 0x41
        KeyDownUp 0x2E
        Start-Sleep -Milliseconds 400
        Set-Clipboard -Value $msg
        $clip = Get-Clipboard -Raw
        if ($clip -ne $msg) {
            Log 'Clipboard content mismatch; retrying once'
            Set-Clipboard -Value $msg
            Start-Sleep -Milliseconds 300
            $clip = Get-Clipboard -Raw
        }
        Log "Clipboard written; content matches=$($clip -eq $msg)"
        CtrlCombo 0x56
        $send = Wait-ForSendEnabled 10
        Shot $taskFolder '03_input'

        if ($dryRun) {
            Log 'Dry run: message pasted and captured; clearing the composer without sending'
            CtrlCombo 0x41
            KeyDownUp 0x2E
            Start-Sleep -Milliseconds 300
            Shot $taskFolder '04_dryrun_cleared'
            $okCount++
            continue
        }

        if ((!$send) -or (-not $send.Current.IsEnabled)) {
            if ($useReset) {
                Log 'Send button disabled; trying "Reset usage" because this task allows it'
                $resetBtn = Find-ButtonByRegex $script:resetPattern
                if ($resetBtn) {
                    [void](Invoke-Control $resetBtn)
                    Log 'Reset button clicked; waiting for quota to recover'
                    Start-Sleep -Seconds 4
                    $send = Wait-ForSendEnabled 10
                    Shot $taskFolder '04_after_reset'
                } else {
                    Log 'Reset button not found'
                }
            }
        }

        if ($send -and -not $send.Current.IsEnabled) {
            Log "Task $index skipped: send button is disabled (quota or rate limit). The message remains in the composer. Other tasks will continue independently."
            Shot $taskFolder '04_blocked'
            $skipCount++
            continue
        }

        if ($send) { Log "Send button enabled: $($send.Current.IsEnabled)" } else { Log 'Send button not found; trying Enter' }

        KeyDownUp 0x0D
        Log 'Enter pressed; waiting for the send result'
        $done = Wait-ForSendDone 15
        if (-not $done) {
            Log 'Send not confirmed yet; trying to click the send button'
            $s2 = Get-SendButton
            if ($s2 -and $s2.Current.IsEnabled) {
                [void](Invoke-Control $s2)
                $done = Wait-ForSendDone 8
            }
        }
        if ($done) {
            Log 'Message submission confirmed'
        } else {
            Log 'Warning: could not confirm the send result. Check the screenshots. If the chat did not receive the message, inspect ChatGPT for errors.'
        }
        Shot $taskFolder '04_after_send'
        $okCount++
    } catch {
        Log "Task $index failed with an unexpected error: $($_.Exception.Message)"
        $skipCount++
        try { Shot $taskFolder '99_error' } catch { }
    }

    Start-Sleep -Milliseconds 1200
}

if ($skipCount -gt 0) {
    Log "Finished: $okCount succeeded, $skipCount skipped (see the skip reasons above)."
} else {
    Log "Finished: $okCount succeeded, all tasks processed."
}
exit 0
