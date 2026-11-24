# ChatGPT 定时发送助手 - 界面程序（由 ChatGPTAutoSender.exe 加载）
# 注意：本文件必须以 UTF-8 BOM 保存

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 路径（全部位于软件目录内） ----------
$script:RootDir = $env:CHATGPT_SENDER_HOME
if ($script:RootDir) {
    $script:AppDir = Join-Path $script:RootDir 'app'
} else {
    $script:AppDir = $PSScriptRoot
    if (-not $script:AppDir) { $script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $script:RootDir = Split-Path -Parent $script:AppDir
}
$script:EnginePath = Join-Path $script:AppDir 'Engine.ps1'
$script:InteropPath = Join-Path $script:AppDir 'Interop.dll'
$script:IconPath = Join-Path $script:AppDir 'app.ico'
$script:IconPngPath = Join-Path $script:AppDir 'icon.png'

try {
    [void][System.Reflection.Assembly]::LoadFrom($script:InteropPath)
    [void][ChatGPTTool.Win32]::SetProcessDPIAware()
} catch { }
try {
    $conHwnd = [ChatGPTTool.Win32]::GetConsoleWindow()
    if ($conHwnd -ne [IntPtr]::Zero) { [void][ChatGPTTool.Win32]::ShowWindow($conHwnd, 0) }
} catch { }

$script:Tasks = New-Object System.Collections.ArrayList
$script:EngineProc = $null
$script:RunFolder = $null
$script:LogOffset = 0
$script:Running = $false
$script:DialogTask = $null

$C = @{
    Bg        = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')
    Card      = [System.Drawing.Color]::White
    Border    = [System.Drawing.ColorTranslator]::FromHtml('#E4E7EB')
    Text      = [System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    Muted     = [System.Drawing.ColorTranslator]::FromHtml('#475569')
    Navy      = [System.Drawing.ColorTranslator]::FromHtml('#1E3A5F')
    NavyHover = [System.Drawing.ColorTranslator]::FromHtml('#152C49')
    Accent    = [System.Drawing.ColorTranslator]::FromHtml('#059669')
    Danger    = [System.Drawing.ColorTranslator]::FromHtml('#DC2626')
    GridAlt   = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')
    Selection = [System.Drawing.ColorTranslator]::FromHtml('#E2E8F0')
    MutedBg   = [System.Drawing.ColorTranslator]::FromHtml('#F1F3F5')
}

$fontUI = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$fontSection = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = $fontUI
    $l.ForeColor = $C.Text
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}
function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Font = $fontUI
    $b.FlatStyle = 'Flat'
    $b.Cursor = 'Hand'
    $b.UseVisualStyleBackColor = $false
    if ($primary) {
        $b.BackColor = $C.Navy
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $C.NavyHover
    } else {
        $b.BackColor = [System.Drawing.Color]::White
        $b.ForeColor = $C.Text
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $C.Border
        $b.FlatAppearance.MouseOverBackColor = $C.MutedBg
    }
    return $b
}
function New-RowStyle([string]$sizeType, [int]$height) {
    $rs = New-Object System.Windows.Forms.RowStyle
    if ($sizeType -eq 'Percent') { $rs.SizeType = [System.Windows.Forms.SizeType]::Percent }
    else { $rs.SizeType = [System.Windows.Forms.SizeType]::Absolute }
    $rs.Height = $height
    return $rs
}

# ---------------- 主窗体 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'ChatGPT 定时发送助手'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.ClientSize = New-Object System.Drawing.Size(964, 791)
$form.MinimumSize = New-Object System.Drawing.Size(820, 580)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.Font = $fontUI
try { $form.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 68
$header.BackColor = [System.Drawing.Color]::White
$header.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen ($C.Border)
    $e.Graphics.DrawLine($pen, 0, $sender.Height - 1, $sender.Width, $sender.Height - 1)
    $pen.Dispose()
})
$form.Controls.Add($header)

try {
    $picLogo = New-Object System.Windows.Forms.PictureBox
    $picLogo.Image = [System.Drawing.Image]::FromFile($script:IconPngPath)
    $picLogo.SizeMode = 'StretchImage'
    $picLogo.Location = New-Object System.Drawing.Point(24, 18)
    $picLogo.Size = New-Object System.Drawing.Size(32, 32)
    $picLogo.BackColor = [System.Drawing.Color]::Transparent
    $header.Controls.Add($picLogo)
} catch { }

$lblTitle = New-Label 'ChatGPT 定时发送助手' 66 10 460 30
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $C.Navy
$header.Controls.Add($lblTitle)

$lblSub = New-Label '每个任务独立时间 · 绝对/相对时间 · 自动截图留证' 68 42 520 20
$lblSub.ForeColor = $C.Muted
$header.Controls.Add($lblSub)

$lblVer = New-Label 'v1.0.0 · 便携版 · 输出仅保存在软件目录' 540 24 400 20
$lblVer.TextAlign = 'MiddleRight'
$lblVer.Anchor = 'Top,Right'
$lblVer.ForeColor = $C.Muted
$header.Controls.Add($lblVer)

# ---------- 自适应主体 ----------
$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'
$main.ColumnCount = 1
$main.RowCount = 3
$main.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 12)
$main.BackColor = [System.Drawing.Color]::Transparent
[void]$main.RowStyles.Add((New-RowStyle 'Percent' 100))
[void]$main.RowStyles.Add((New-RowStyle 'Absolute' 46))
[void]$main.RowStyles.Add((New-RowStyle 'Absolute' 205))
$form.Controls.Add($main)
$main.BringToFront()

$taskCard = New-Object System.Windows.Forms.Panel
$taskCard.Dock = 'Fill'
$taskCard.BackColor = $C.Card
$taskCard.Padding = New-Object System.Windows.Forms.Padding(16, 10, 16, 12)
$taskCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$taskCard.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen ($C.Border)
    $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
    $pen.Dispose()
})
$main.Controls.Add($taskCard, 0, 0)

$cardLayout = New-Object System.Windows.Forms.TableLayoutPanel
$cardLayout.Dock = 'Fill'
$cardLayout.ColumnCount = 1
$cardLayout.RowCount = 3
$cardLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$cardLayout.BackColor = [System.Drawing.Color]::Transparent
[void]$cardLayout.RowStyles.Add((New-RowStyle 'Absolute' 32))
[void]$cardLayout.RowStyles.Add((New-RowStyle 'Percent' 100))
[void]$cardLayout.RowStyles.Add((New-RowStyle 'Absolute' 42))
$taskCard.Controls.Add($cardLayout)

$lblTaskTitle = New-Label '发送任务（每个任务单独设置时间，按时间先后执行）' 0 0 620 26
$lblTaskTitle.Dock = 'Fill'
$lblTaskTitle.TextAlign = 'MiddleLeft'
$lblTaskTitle.Font = $fontSection
$cardLayout.Controls.Add($lblTaskTitle, 0, 0)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'None'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.GridColor = $C.Border
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersHeight = 34
$grid.ColumnHeadersBorderStyle = 'Single'
$grid.ColumnHeadersDefaultCellStyle.BackColor = $C.MutedBg
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $C.Muted
$grid.ColumnHeadersDefaultCellStyle.Font = $fontUI
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $C.MutedBg
$grid.DefaultCellStyle.Font = $fontUI
$grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
$grid.DefaultCellStyle.ForeColor = $C.Text
$grid.DefaultCellStyle.SelectionBackColor = $C.Selection
$grid.DefaultCellStyle.SelectionForeColor = $C.Text
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
$grid.RowTemplate.Height = 34
$grid.AlternatingRowsDefaultCellStyle.BackColor = $C.GridAlt

$colTime = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTime.HeaderText = '执行时间'
$colTime.FillWeight = 30
$colTime.MinimumWidth = 180
[void]$grid.Columns.Add($colTime)

$colProj = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colProj.HeaderText = '项目'
$colProj.FillWeight = 18
[void]$grid.Columns.Add($colProj)

$colChat = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colChat.HeaderText = '聊天'
$colChat.FillWeight = 20
[void]$grid.Columns.Add($colChat)

$colMsg = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colMsg.HeaderText = '发送内容'
$colMsg.FillWeight = 26
[void]$grid.Columns.Add($colMsg)

$colReset = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colReset.HeaderText = '重置额度'
$colReset.FillWeight = 12
$colReset.MinimumWidth = 96
[void]$grid.Columns.Add($colReset)

$cardLayout.Controls.Add($grid, 0, 1)

$taskBottom = New-Object System.Windows.Forms.Panel
$taskBottom.Dock = 'Fill'
$taskBottom.BackColor = [System.Drawing.Color]::Transparent
$taskBottom.Margin = New-Object System.Windows.Forms.Padding(0)
$cardLayout.Controls.Add($taskBottom, 0, 2)

$btnAdd = New-Button '添加任务' 0 4 100 34 $true
$btnEdit = New-Button '编辑任务' 108 4 100 34 $false
$btnDel = New-Button '删除任务' 216 4 100 34 $false
$taskBottom.Controls.Add($btnAdd)
$taskBottom.Controls.Add($btnEdit)
$taskBottom.Controls.Add($btnDel)

$lblHint = New-Label '示例：my_project · My Chat · 支持绝对/相对时间' 330 11 400 20
$lblHint.ForeColor = $C.Muted
$taskBottom.Controls.Add($lblHint)

$lblCount = New-Label '共 0 个任务' 760 11 120 20
$lblCount.TextAlign = 'MiddleRight'
$lblCount.ForeColor = $C.Muted
$taskBottom.Controls.Add($lblCount)
$taskBottom.Add_Resize({
    param($sender, $e)
    $lblCount.Left = [Math]::Max(430, $sender.ClientSize.Width - $lblCount.Width)
})

# 操作行
$actionPanel = New-Object System.Windows.Forms.Panel
$actionPanel.Dock = 'Fill'
$actionPanel.BackColor = [System.Drawing.Color]::Transparent
$actionPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$main.Controls.Add($actionPanel, 0, 1)

$lblStatus = New-Label '就绪' 0 11 500 22
$lblStatus.ForeColor = $C.Muted
$actionPanel.Controls.Add($lblStatus)

$btnOpen = New-Button '打开输出目录' 556 4 140 34 $false
$actionPanel.Controls.Add($btnOpen)

$btnCancel = New-Button '取消任务' 704 4 100 34 $false
$btnCancel.Enabled = $false
$actionPanel.Controls.Add($btnCancel)

$btnStart = New-Button '开始执行' 812 4 112 34 $true
$actionPanel.Controls.Add($btnStart)

$actionPanel.Add_Resize({
    param($sender, $e)
    $w = $sender.ClientSize.Width
    $btnStart.Left = [Math]::Max(0, $w - $btnStart.Width)
    $btnCancel.Left = $btnStart.Left - 8 - $btnCancel.Width
    $btnOpen.Left = $btnCancel.Left - 8 - $btnOpen.Width
    $lblStatus.Width = [Math]::Max(150, $btnOpen.Left - 20)
})

# 日志 / 须知
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = $fontUI
$tabs.Margin = New-Object System.Windows.Forms.Padding(0)
$main.Controls.Add($tabs, 0, 2)

$pageLog = New-Object System.Windows.Forms.TabPage
$pageLog.Text = '运行日志'
$pageLog.BackColor = [System.Drawing.Color]::White
$pageLog.Padding = New-Object System.Windows.Forms.Padding(8)
$tabs.Controls.Add($pageLog)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock = 'Fill'
$rtbLog.ReadOnly = $true
$rtbLog.BorderStyle = 'None'
$rtbLog.BackColor = [System.Drawing.Color]::White
$rtbLog.ForeColor = $C.Text
$rtbLog.Font = $fontMono
$rtbLog.ScrollBars = 'Vertical'
$rtbLog.WordWrap = $true
$rtbLog.DetectUrls = $false
$pageLog.Controls.Add($rtbLog)

$pageNotes = New-Object System.Windows.Forms.TabPage
$pageNotes.Text = '使用须知'
$pageNotes.BackColor = [System.Drawing.Color]::White
$pageNotes.Padding = New-Object System.Windows.Forms.Padding(10)
$tabs.Controls.Add($pageNotes)

$rtbNotes = New-Object System.Windows.Forms.RichTextBox
$rtbNotes.Dock = 'Fill'
$rtbNotes.ReadOnly = $true
$rtbNotes.BorderStyle = 'None'
$rtbNotes.BackColor = [System.Drawing.Color]::White
$rtbNotes.ForeColor = $C.Text
$rtbNotes.Font = $fontUI
$rtbNotes.ScrollBars = 'Vertical'
$rtbNotes.DetectUrls = $false
$pageNotes.Controls.Add($rtbNotes)

$notesLines = @(
'使用须知与注意事项（v1.0.0）',
'',
'一、运行环境',
'1. 请确保已登录并保持运行 ChatGPT 桌面端；本工具通过界面模拟完成操作，非官方接口。',
'2. 执行期间电脑需保持唤醒、未锁屏，建议临时关闭睡眠与屏保；锁屏会导致按键无效。',
'3. 本工具为便携版，无需安装；日志、截图、配置全部保存在软件目录 output 下。',
'',
'二、任务与时间',
'1. 每个任务单独设置执行时间、项目、聊天、内容与“重置额度”选项，任务按时间先后依次执行。',
'2. 支持绝对时间与相对时间：',
'   · 绝对时间：直接输入 yyyy-MM-dd HH:mm:ss，或用日期/时间控件选择，两者自动同步。',
'   · 相对时间：填写“从现在起 X 小时 Y 分钟”，保存时计算为具体时间。',
'3. 发送内容不限长度与格式，支持多行文本，通过剪贴板粘贴发送。',
'4. 项目名可留空（不切换项目）；聊天名可留空（使用当前聊天）。名称需与界面显示完全一致。',
'',
'三、额度与重置',
'1. 每个任务可单独勾选“自动重置”：发送按钮因额度不足被禁用时会点击一次“重置使用量”。',
'2. 该操作会消耗一次重置机会；未勾选时不会发送，内容保留在输入框，日志标记为 BLOCKED。',
'',
'四、截图与日志',
'1. 每次运行创建 output\年月日_时分秒 文件夹，内含 run.log、config.json 与每任务截图子文件夹。',
'2. 截图优先截取 ChatGPT 窗口区域，支持多显示器；窗口最小化时会先恢复再截图。',
'',
'五、异常与干扰',
'1. 程序在每一步操作后都会等待 ChatGPT 的界面反馈，超时会自动重试或安全跳过该任务。',
'2. 聊天无法确认打开时会跳过发送，避免把内容发到错误聊天。',
'3. 执行开始后请勿操作键鼠，避免干扰输入。',
'4. 官网界面改版可能导致控件定位失败，可在日志中查看失败步骤。',
'',
'六、许可',
'本软件仅供个人学习与非商业用途，禁止商业使用。作者：Yu010912（2206394025@qq.com）。'
)
$rtbNotes.Text = ($notesLines -join "`r`n")

# ---------------- 辅助函数 ----------------
function Normalize-Tasks {
    $sorted = @($script:Tasks | Sort-Object { $_.Time })
    $script:Tasks.Clear()
    foreach ($t in $sorted) { [void]$script:Tasks.Add($t) }
}
function Refresh-Grid {
    $grid.Rows.Clear()
    $i = 1
    foreach ($t in $script:Tasks) {
        $projText = $t.Project
        if (-not $projText) { $projText = '（不指定）' }
        $chatText = $t.Chat
        if (-not $chatText) { $chatText = '（当前聊天）' }
        $sum = [string]$t.Message
        $sum = $sum.Replace("`r`n", ' ').Replace("`n", ' ')
        if ($sum.Length -gt 60) { $sum = $sum.Substring(0, 60) + '…' }
        $resetText = '否'
        if ($t.UseReset) { $resetText = '是' }
        [void]$grid.Rows.Add($t.Time.ToString('yyyy-MM-dd HH:mm:ss'), $projText, $chatText, $sum, $resetText)
        $i++
    }
    $lblCount.Text = "共 $($script:Tasks.Count) 个任务"
}
function Set-RunningUI([bool]$running) {
    $script:Running = $running
    $btnStart.Enabled = -not $running
    $btnCancel.Enabled = $running
    $btnAdd.Enabled = -not $running
    $btnEdit.Enabled = -not $running
    $btnDel.Enabled = -not $running
    $grid.Enabled = -not $running
    if ($running) {
        $btnStart.BackColor = $C.MutedBg
        $btnStart.ForeColor = $C.Muted
    } else {
        $btnStart.BackColor = $C.Navy
        $btnStart.ForeColor = [System.Drawing.Color]::White
    }
}
function Tail-Log {
    if (-not $script:RunFolder) { return }
    $p = Join-Path $script:RunFolder 'run.log'
    if (-not (Test-Path $p)) { return }
    try {
        $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [void]$fs.Seek($script:LogOffset, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd()
        $script:LogOffset = $fs.Position
        $sr.Close(); $fs.Close()
        if ($txt) {
            $rtbLog.AppendText($txt)
            $rtbLog.SelectionStart = $rtbLog.TextLength
            $rtbLog.ScrollToCaret()
        }
    } catch { }
}
function Parse-TaskTime([string]$text) {
    $formats = @('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm', 'yyyy/MM/dd HH:mm:ss', 'yyyy/MM/dd HH:mm')
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($text, $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)
    if (-not $ok) {
        $ok = [datetime]::TryParse($text, [ref]$dt)
    }
    if ($ok) { return $dt }
    return $null
}
function Show-TaskDialog($task) {
    $dlg = New-Object System.Windows.Forms.Form
    if ($task) { $dlg.Text = '编辑任务' } else { $dlg.Text = '添加任务' }
    $dlg.ClientSize = New-Object System.Drawing.Size(600, 612)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = $fontUI
    try { $dlg.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }

    $l1 = New-Label '执行时间（可直接输入，也可用控件选择）' 20 16 420 20
    $dlg.Controls.Add($l1)

    $rbAbs = New-Object System.Windows.Forms.RadioButton
    $rbAbs.Text = '绝对时间'
    $rbAbs.Location = New-Object System.Drawing.Point(20, 40)
    $rbAbs.Size = New-Object System.Drawing.Size(92, 24)
    $rbAbs.Font = $fontUI
    $rbAbs.ForeColor = $C.Text
    $rbAbs.Checked = $true
    $dlg.Controls.Add($rbAbs)

    $rbRel = New-Object System.Windows.Forms.RadioButton
    $rbRel.Text = '相对时间'
    $rbRel.Location = New-Object System.Drawing.Point(120, 40)
    $rbRel.Size = New-Object System.Drawing.Size(92, 24)
    $rbRel.Font = $fontUI
    $rbRel.ForeColor = $C.Text
    $dlg.Controls.Add($rbRel)

    $tTime = New-Object System.Windows.Forms.TextBox
    $tTime.Location = New-Object System.Drawing.Point(20, 70)
    $tTime.Size = New-Object System.Drawing.Size(300, 28)
    $tTime.Font = $fontUI
    $tTime.ForeColor = $C.Text
    $tTime.BackColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($tTime)

    $dtpDate = New-Object System.Windows.Forms.DateTimePicker
    $dtpDate.Format = 'Short'
    $dtpDate.Location = New-Object System.Drawing.Point(330, 70)
    $dtpDate.Size = New-Object System.Drawing.Size(150, 28)
    $dtpDate.Font = $fontUI
    $dlg.Controls.Add($dtpDate)

    $dtpTime = New-Object System.Windows.Forms.DateTimePicker
    $dtpTime.Format = 'Time'
    $dtpTime.ShowUpDown = $true
    $dtpTime.Location = New-Object System.Drawing.Point(488, 70)
    $dtpTime.Size = New-Object System.Drawing.Size(94, 28)
    $dtpTime.Font = $fontUI
    $dlg.Controls.Add($dtpTime)

    $hAbs = New-Label '格式：yyyy-MM-dd HH:mm:ss（示例 2026-12-31 09:30:00）' 20 102 570 18
    $hAbs.ForeColor = $C.Muted
    $dlg.Controls.Add($hAbs)

    $relPanel = New-Object System.Windows.Forms.Panel
    $relPanel.Location = New-Object System.Drawing.Point(20, 126)
    $relPanel.Size = New-Object System.Drawing.Size(560, 32)
    $relPanel.BackColor = [System.Drawing.Color]::Transparent
    $dlg.Controls.Add($relPanel)

    $lblFrom = New-Label '从现在起' 0 5 60 20
    $relPanel.Controls.Add($lblFrom)

    $numH = New-Object System.Windows.Forms.NumericUpDown
    $numH.Location = New-Object System.Drawing.Point(66, 2)
    $numH.Size = New-Object System.Drawing.Size(70, 28)
    $numH.Maximum = 9999
    $numH.Minimum = 0
    $numH.Value = 0
    $numH.Font = $fontUI
    $relPanel.Controls.Add($numH)

    $lblHour = New-Label '时' 142 5 24 20
    $relPanel.Controls.Add($lblHour)

    $numM = New-Object System.Windows.Forms.NumericUpDown
    $numM.Location = New-Object System.Drawing.Point(172, 2)
    $numM.Size = New-Object System.Drawing.Size(70, 28)
    $numM.Maximum = 59
    $numM.Minimum = 0
    $numM.Value = 10
    $numM.Font = $fontUI
    $relPanel.Controls.Add($numM)

    $lblMin = New-Label '分' 248 5 24 20
    $relPanel.Controls.Add($lblMin)

    $lblSuffix = New-Label '后执行' 278 5 52 20
    $relPanel.Controls.Add($lblSuffix)

    $lblPreview = New-Label '预计：--' 340 5 210 20
    $lblPreview.ForeColor = $C.Navy
    $relPanel.Controls.Add($lblPreview)

    $hRel = New-Label '提示：相对时间以点击“保存”时的当前时间为基准计算' 20 162 540 18
    $hRel.ForeColor = $C.Muted
    $dlg.Controls.Add($hRel)

    $l2 = New-Label '项目名称（可留空）' 20 194 300 20
    $dlg.Controls.Add($l2)
    $tProj = New-Object System.Windows.Forms.TextBox
    $tProj.Location = New-Object System.Drawing.Point(20, 216)
    $tProj.Size = New-Object System.Drawing.Size(560, 28)
    $tProj.Font = $fontUI
    $tProj.ForeColor = $C.Text
    $dlg.Controls.Add($tProj)
    $h2 = New-Label '示例：my_project（留空表示不指定项目）' 20 246 500 18
    $h2.ForeColor = $C.Muted
    $dlg.Controls.Add($h2)

    $l3 = New-Label '聊天名称（可留空）' 20 276 300 20
    $dlg.Controls.Add($l3)
    $tChat = New-Object System.Windows.Forms.TextBox
    $tChat.Location = New-Object System.Drawing.Point(20, 298)
    $tChat.Size = New-Object System.Drawing.Size(560, 28)
    $tChat.Font = $fontUI
    $tChat.ForeColor = $C.Text
    $dlg.Controls.Add($tChat)
    $h3 = New-Label '示例：My Chat（留空表示使用当前打开的聊天）' 20 328 500 18
    $h3.ForeColor = $C.Muted
    $dlg.Controls.Add($h3)

    $l4 = New-Label '发送内容（必填，不限长度与格式）' 20 358 400 20
    $dlg.Controls.Add($l4)
    $tMsg = New-Object System.Windows.Forms.TextBox
    $tMsg.Location = New-Object System.Drawing.Point(20, 380)
    $tMsg.Size = New-Object System.Drawing.Size(560, 120)
    $tMsg.Multiline = $true
    $tMsg.AcceptsReturn = $true
    $tMsg.MaxLength = 0
    $tMsg.ScrollBars = 'Vertical'
    $tMsg.Font = $fontUI
    $tMsg.ForeColor = $C.Text
    $dlg.Controls.Add($tMsg)
    $h4 = New-Label '示例：继续（支持多行文本）' 20 504 400 18
    $h4.ForeColor = $C.Muted
    $dlg.Controls.Add($h4)

    $chkResetDlg = New-Object System.Windows.Forms.CheckBox
    $chkResetDlg.Text = '本任务额度不足时自动点击“重置使用量”（消耗一次重置机会）'
    $chkResetDlg.Location = New-Object System.Drawing.Point(20, 528)
    $chkResetDlg.Size = New-Object System.Drawing.Size(560, 24)
    $chkResetDlg.Font = $fontUI
    $chkResetDlg.ForeColor = $C.Text
    $dlg.Controls.Add($chkResetDlg)

    $script:dialogUpdating = $false
    function Update-RelPreview {
        if (-not $rbRel.Checked) { $lblPreview.Text = '预计：--'; return }
        $d = (Get-Date).AddHours([double]$numH.Value).AddMinutes([double]$numM.Value)
        $lblPreview.Text = '预计：' + $d.ToString('MM-dd HH:mm:ss')
    }
    function Sync-FromPickers {
        if ($script:dialogUpdating) { return }
        $script:dialogUpdating = $true
        $tTime.Text = ($dtpDate.Value.Date.Add($dtpTime.Value.TimeOfDay)).ToString('yyyy-MM-dd HH:mm:ss')
        $script:dialogUpdating = $false
    }
    function Sync-FromText {
        if ($script:dialogUpdating) { return }
        $d = Parse-TaskTime $tTime.Text
        if ($d) {
            $script:dialogUpdating = $true
            $dtpDate.Value = $d.Date
            $dtpTime.Value = $d
            $script:dialogUpdating = $false
        }
    }
    function Update-TimeMode {
        $abs = $rbAbs.Checked
        $tTime.Enabled = $abs
        $dtpDate.Enabled = $abs
        $dtpTime.Enabled = $abs
        $numH.Enabled = -not $abs
        $numM.Enabled = -not $abs
        $hAbs.ForeColor = $C.Muted
        $hRel.ForeColor = $C.Muted
        Update-RelPreview
    }

    $dtpDate.Add_ValueChanged({ Sync-FromPickers })
    $dtpTime.Add_ValueChanged({ Sync-FromPickers })
    $tTime.Add_TextChanged({ Sync-FromText })
    $rbAbs.Add_CheckedChanged({ Update-TimeMode })
    $rbRel.Add_CheckedChanged({ Update-TimeMode })
    $numH.Add_ValueChanged({ Update-RelPreview })
    $numM.Add_ValueChanged({ Update-RelPreview })

    if ($task) {
        $tTime.Text = $task.Time.ToString('yyyy-MM-dd HH:mm:ss')
        $dtpDate.Value = $task.Time.Date
        $dtpTime.Value = $task.Time
        $tProj.Text = [string]$task.Project
        $tChat.Text = [string]$task.Chat
        $tMsg.Text = [string]$task.Message
        $chkResetDlg.Checked = [bool]$task.UseReset
    } else {
        $defaultTarget = (Get-Date).AddMinutes(10)
        $tTime.Text = $defaultTarget.ToString('yyyy-MM-dd HH:mm:ss')
        $dtpDate.Value = $defaultTarget.Date
        $dtpTime.Value = $defaultTarget
    }
    Update-TimeMode

    $btnSaveDlg = New-Button '保存' 380 548 90 32 $true
    $btnSaveDlg.Add_Click({
        $dt = $null
        if ($rbAbs.Checked) {
            $dt = Parse-TaskTime $tTime.Text
            if (-not $dt) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, '时间格式不正确。' + [Environment]::NewLine + '请使用：yyyy-MM-dd HH:mm:ss（示例 2026-12-31 09:30:00）', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
        } else {
            $h = [double]$numH.Value
            $m = [double]$numM.Value
            if ($h -eq 0 -and $m -eq 0) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, '相对时间不能为 0，请设置小时或分钟。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $dt = (Get-Date).AddHours($h).AddMinutes($m)
        }
        if (-not $tMsg.Text -or $tMsg.Text.Trim().Length -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, '发送内容不能为空，请填写内容。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($dt -lt (Get-Date)) {
            $ans = [System.Windows.Forms.MessageBox]::Show($dlg, '该时间早于当前时间，任务将立即执行。是否保存？', '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $script:DialogTask = [PSCustomObject]@{
            Time     = $dt
            Project  = $tProj.Text.Trim()
            Chat     = $tChat.Text.Trim()
            Message  = $tMsg.Text
            UseReset = [bool]$chkResetDlg.Checked
        }
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSaveDlg)

    $btnCancelDlg = New-Button '取消' 480 548 90 32 $false
    $btnCancelDlg.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCancelDlg)
    $dlg.CancelButton = $btnCancelDlg

    $script:DialogTask = $null
    [void]$dlg.ShowDialog($form)
    $result = $script:DialogTask
    $dlg.Dispose()
    return $result
}

# ---------------- 事件 ----------------
$btnAdd.Add_Click({
    $r = Show-TaskDialog $null
    if ($r) {
        [void]$script:Tasks.Add($r)
        Normalize-Tasks
        Refresh-Grid
    }
})
$btnEdit.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请先在列表中选择一个任务。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $idx = $grid.SelectedRows[0].Index
    if ($idx -lt 0 -or $idx -ge $script:Tasks.Count) { return }
    $r = Show-TaskDialog $script:Tasks[$idx]
    if ($r) {
        $script:Tasks[$idx] = $r
        Normalize-Tasks
        Refresh-Grid
    }
})
$btnDel.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请先在列表中选择一个任务。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $idx = $grid.SelectedRows[0].Index
    if ($idx -lt 0 -or $idx -ge $script:Tasks.Count) { return }
    $ans = [System.Windows.Forms.MessageBox]::Show('确定删除选中的任务吗？', '确认删除', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:Tasks.RemoveAt($idx)
        Refresh-Grid
    }
})
$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -ge 0 -and $e.RowIndex -lt $script:Tasks.Count) {
        $r = Show-TaskDialog $script:Tasks[$e.RowIndex]
        if ($r) {
            $script:Tasks[$e.RowIndex] = $r
            Normalize-Tasks
            Refresh-Grid
        }
    }
})
$btnOpen.Add_Click({
    $folder = $script:RunFolder
    if (-not $folder) { $folder = Join-Path $script:RootDir 'output' }
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    Start-Process explorer.exe $folder
})
$btnCancel.Add_Click({
    if ($script:EngineProc -and -not $script:EngineProc.HasExited) {
        try { $script:EngineProc.Kill() } catch { }
        $rtbLog.AppendText("$(Get-Date -Format 'HH:mm:ss') 已手动取消任务。`r`n")
    }
    $timer.Stop()
    $lblStatus.Text = '已取消'
    $lblStatus.ForeColor = $C.Danger
    Set-RunningUI $false
    $script:EngineProc = $null
})
$btnStart.Add_Click({
    if ($script:Running) { return }
    if ($script:Tasks.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请先添加至少一个发送任务。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    foreach ($t in $script:Tasks) {
        if (-not $t.Message -or $t.Message.Trim().Length -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('存在内容为空的任务，请检查。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
    }
    if (-not (Test-Path $script:EnginePath)) {
        [void][System.Windows.Forms.MessageBox]::Show('未找到执行引擎 app\Engine.ps1，请确认软件文件完整。', '错误', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $nextTask = ($script:Tasks | Sort-Object { $_.Time } | Select-Object -First 1)
    $confirm = [System.Windows.Forms.MessageBox]::Show("共 $($script:Tasks.Count) 个任务，将按时间先后执行。`r`n最近任务时间：$($nextTask.Time.ToString('yyyy-MM-dd HH:mm:ss'))`r`n`r`n现在开始等待并执行吗？", '开始执行', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $outRoot = Join-Path $script:RootDir 'output'
    if (-not (Test-Path $outRoot)) { New-Item -ItemType Directory -Path $outRoot -Force | Out-Null }
    $runFolder = Join-Path $outRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    $cfgPath = Join-Path $runFolder 'config.json'

    $taskList = @()
    foreach ($t in $script:Tasks) {
        $taskList += @{
            Time     = $t.Time.ToString('yyyy-MM-dd HH:mm:ss')
            Project  = [string]$t.Project
            Chat     = [string]$t.Chat
            Message  = [string]$t.Message
            UseReset = [bool]$t.UseReset
        }
    }
    $cfgObject = @{
        Tasks     = $taskList
        RunFolder = $runFolder
        DryRun    = $false
    }
    [System.IO.File]::WriteAllText($cfgPath, ($cfgObject | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))

    $script:RunFolder = $runFolder
    $script:LogOffset = 0
    $rtbLog.Clear()
    $rtbLog.AppendText("$(Get-Date -Format 'HH:mm:ss') 已启动，共 $($script:Tasks.Count) 个任务，输出目录：$runFolder`r`n")

    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:EnginePath)`" -ConfigPath `"$cfgPath`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.WorkingDirectory = $script:RootDir
    $psi.EnvironmentVariables['CHATGPT_SENDER_HOME'] = $script:RootDir
    $script:EngineProc = [System.Diagnostics.Process]::Start($psi)

    Set-RunningUI $true
    $lblStatus.Text = '等待任务…'
    $lblStatus.ForeColor = $C.Navy
    $timer.Start()
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:EngineProc -and -not $script:EngineProc.HasExited) {
        $ans = [System.Windows.Forms.MessageBox]::Show('任务正在等待或执行中，确定退出吗？退出将取消任务。', '确认退出', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
        try { $script:EngineProc.Kill() } catch { }
    }
})
$form.Add_Load({
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $w = [Math]::Min($form.Width, $wa.Width - 24)
    $h = [Math]::Min($form.Height, $wa.Height - 24)
    if ($w -ne $form.Width -or $h -ne $form.Height) {
        $form.Size = New-Object System.Drawing.Size($w, $h)
    }
    $form.Location = New-Object System.Drawing.Point(
        ($wa.X + [int](($wa.Width - $form.Width) / 2)),
        ($wa.Y + [int](($wa.Height - $form.Height) / 2))
    )
})

# ---------------- 定时刷新 ----------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({
    Tail-Log
    if ($script:EngineProc) {
        if ($script:EngineProc.HasExited) {
            $timer.Stop()
            $code = $script:EngineProc.ExitCode
            if ($code -eq 0) {
                $lblStatus.Text = "已完成（$(Get-Date -Format 'HH:mm:ss')）"
                $lblStatus.ForeColor = $C.Accent
            } else {
                $lblStatus.Text = "执行结束，退出码 $code（详见日志）"
                $lblStatus.ForeColor = $C.Danger
            }
            Set-RunningUI $false
            $script:EngineProc = $null
        } elseif ($script:Tasks.Count -gt 0) {
            $pending = @($script:Tasks | Where-Object { $_.Time -gt (Get-Date) } | Sort-Object { $_.Time } | Select-Object -First 1)
            if ($pending) {
                $left = $pending.Time - (Get-Date)
                $lblStatus.Text = ('等待中：下一任务 {0}，剩余 {1:hh\:mm\:ss}' -f $pending.Time.ToString('MM-dd HH:mm:ss'), $left)
                $lblStatus.ForeColor = $C.Navy
            } else {
                $lblStatus.Text = '执行中…'
                $lblStatus.ForeColor = $C.Navy
            }
        } else {
            $lblStatus.Text = '执行中…'
        }
    }
})

Refresh-Grid
[void]$form.ShowDialog()
$form.Dispose()
