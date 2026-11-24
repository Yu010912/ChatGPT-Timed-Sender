# ChatGPT Timed Sender - UI (loaded by ChatGPTAutoSender.exe)
# This file must be saved as UTF-8 with BOM.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- Paths (everything stays inside the app folder) ----------
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
$script:SettingsPath = Join-Path $script:AppDir 'settings.json'

try {
    [void][System.Reflection.Assembly]::LoadFrom($script:InteropPath)
    [void][ChatGPTTool.Win32]::SetProcessDPIAware()
} catch { }
try {
    $conHwnd = [ChatGPTTool.Win32]::GetConsoleWindow()
    if ($conHwnd -ne [IntPtr]::Zero) { [void][ChatGPTTool.Win32]::ShowWindow($conHwnd, 0) }
} catch { }

# ---------- Localization ----------
$script:LangCode = 'en'
$script:Lang = @{}

function Get-DefaultLanguage {
    try {
        if (Test-Path $script:SettingsPath) {
            $cfg = Get-Content -Path $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.Language -eq 'zh' -or $cfg.Language -eq 'en') { return [string]$cfg.Language }
        }
    } catch { }
    if ([System.Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*') { return 'zh' }
    return 'en'
}
function Load-Language([string]$code) {
    $path = Join-Path $script:AppDir ('lang.' + $code + '.json')
    if (-not (Test-Path $path)) { $path = Join-Path $script:AppDir 'lang.en.json' }
    $json = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $table = @{}
    foreach ($p in $json.PSObject.Properties) { $table[$p.Name] = [string]$p.Value }
    $script:Lang = $table
    $script:LangCode = $code
}
function T([string]$key, $fmtArgs) {
    if ($script:Lang.ContainsKey($key)) { $s = [string]$script:Lang[$key] } else { $s = $key }
    if ($null -ne $fmtArgs) {
        $arr = @($fmtArgs)
        if ($arr.Count -gt 0) {
            try { return [string]::Format($s, $arr) } catch { return $s }
        }
    }
    return $s
}
function Save-Language([string]$code) {
    try {
        $json = '{"Language":"' + $code + '"}'
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}
Load-Language (Get-DefaultLanguage)

$script:Tasks = New-Object System.Collections.ArrayList
$script:EngineProc = $null
$script:RunFolder = $null
$script:LogOffset = 0
$script:Running = $false
$script:ApplyingLang = $false
$script:DialogTask = $null
$script:gridUpdating = $false

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

$fontUI = New-Object System.Drawing.Font('Segoe UI', 9)
$fontUIZh = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$fontSection = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)

function Get-UIFont {
    if ($script:LangCode -eq 'zh') { return $fontUIZh }
    return $fontUI
}
function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = Get-UIFont
    $l.ForeColor = $C.Text
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}
function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Font = Get-UIFont
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
function New-LinkButton([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $b = New-Button $text $x $y $w $h $false
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = [System.Drawing.Color]::White
    $b.ForeColor = $C.Navy
    $b.Font = New-Object System.Drawing.Font((Get-UIFont).Name, 9, [System.Drawing.FontStyle]::Underline)
    $b.FlatAppearance.MouseOverBackColor = $C.MutedBg
    return $b
}
function New-RowStyle([string]$sizeType, [int]$height) {
    $rs = New-Object System.Windows.Forms.RowStyle
    if ($sizeType -eq 'Percent') { $rs.SizeType = [System.Windows.Forms.SizeType]::Percent }
    else { $rs.SizeType = [System.Windows.Forms.SizeType]::Absolute }
    $rs.Height = $height
    return $rs
}

# ---------------- Main form ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = T 'app.title'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.ClientSize = New-Object System.Drawing.Size(964, 791)
$form.MinimumSize = New-Object System.Drawing.Size(900, 580)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.Font = Get-UIFont
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

$lblTitle = New-Label (T 'app.title') 66 10 460 30
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $C.Navy
$header.Controls.Add($lblTitle)

$lblSub = New-Label (T 'app.subtitle') 68 42 560 20
$lblSub.ForeColor = $C.Muted
$header.Controls.Add($lblSub)

$lblVer = New-Label (T 'app.version') 500 10 440 18
$lblVer.TextAlign = 'MiddleRight'
$lblVer.Anchor = 'Top,Right'
$lblVer.ForeColor = $C.Muted
$header.Controls.Add($lblVer)

$script:VersionText = '1.1.0'
$btnAbout = New-LinkButton (T 'header.about') 640 34 88 22
$btnAbout.Anchor = 'Top,Right'
$header.Controls.Add($btnAbout)

$btnLicense = New-LinkButton (T 'header.license') 730 34 88 22
$btnLicense.Anchor = 'Top,Right'
$header.Controls.Add($btnLicense)

$cboLang = New-Object System.Windows.Forms.ComboBox
$cboLang.DropDownStyle = 'DropDownList'
$cboLang.Location = New-Object System.Drawing.Point(828, 31)
$cboLang.Size = New-Object System.Drawing.Size(112, 28)
$cboLang.Font = Get-UIFont
$cboLang.Anchor = 'Top,Right'
[void]$cboLang.Items.Add((T 'lang.english'))
[void]$cboLang.Items.Add((T 'lang.chinese'))
if ($script:LangCode -eq 'zh') { $cboLang.SelectedIndex = 1 } else { $cboLang.SelectedIndex = 0 }
$header.Controls.Add($cboLang)
$btnAbout.BringToFront()
$btnLicense.BringToFront()
$cboLang.BringToFront()

# ---------- Main layout ----------
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

$lblTaskTitle = New-Label (T 'task.title') 0 0 620 26
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
$grid.ReadOnly = $false
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
$grid.ColumnHeadersDefaultCellStyle.Font = Get-UIFont
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $C.MutedBg
$grid.DefaultCellStyle.Font = Get-UIFont
$grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
$grid.DefaultCellStyle.ForeColor = $C.Text
$grid.DefaultCellStyle.SelectionBackColor = $C.Selection
$grid.DefaultCellStyle.SelectionForeColor = $C.Text
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
$grid.RowTemplate.Height = 34
$grid.AlternatingRowsDefaultCellStyle.BackColor = $C.GridAlt

$colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSel.HeaderText = T 'task.select'
$colSel.FillWeight = 8
$colSel.MinimumWidth = 56
$colSel.ReadOnly = $false
$colSel.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colSel)

$colTime = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTime.HeaderText = T 'task.time'
$colTime.FillWeight = 28
$colTime.MinimumWidth = 180
$colTime.ReadOnly = $true
[void]$grid.Columns.Add($colTime)

$colProj = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colProj.HeaderText = T 'task.project'
$colProj.FillWeight = 17
$colProj.ReadOnly = $true
[void]$grid.Columns.Add($colProj)

$colChat = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colChat.HeaderText = T 'task.chat'
$colChat.FillWeight = 19
$colChat.ReadOnly = $true
[void]$grid.Columns.Add($colChat)

$colMsg = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colMsg.HeaderText = T 'task.message'
$colMsg.FillWeight = 24
$colMsg.ReadOnly = $true
[void]$grid.Columns.Add($colMsg)

$colReset = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colReset.HeaderText = T 'task.reset'
$colReset.FillWeight = 13
$colReset.MinimumWidth = 110
$colReset.ReadOnly = $true
[void]$grid.Columns.Add($colReset)

$cardLayout.Controls.Add($grid, 0, 1)

$taskBottom = New-Object System.Windows.Forms.Panel
$taskBottom.Dock = 'Fill'
$taskBottom.BackColor = [System.Drawing.Color]::Transparent
$taskBottom.Margin = New-Object System.Windows.Forms.Padding(0)
$cardLayout.Controls.Add($taskBottom, 0, 2)

$btnAdd = New-Button (T 'task.add') 0 4 110 34 $true
$btnEdit = New-Button (T 'task.edit') 118 4 110 34 $false
$btnDel = New-Button (T 'task.delete') 236 4 110 34 $false
$taskBottom.Controls.Add($btnAdd)
$taskBottom.Controls.Add($btnEdit)
$taskBottom.Controls.Add($btnDel)

$lblHint = New-Label (T 'task.hint') 360 11 320 20
$lblHint.ForeColor = $C.Muted
$taskBottom.Controls.Add($lblHint)

$lblCount = New-Label '' 707 11 185 20
$lblCount.TextAlign = 'MiddleRight'
$lblCount.ForeColor = $C.Muted
$taskBottom.Controls.Add($lblCount)
$taskBottom.Add_Resize({
    param($sender, $e)
    $lblCount.Left = [Math]::Max(430, $sender.ClientSize.Width - $lblCount.Width)
    $lblHint.Width = [Math]::Max(140, $lblCount.Left - $lblHint.Left - 10)
})

# Action row
$actionPanel = New-Object System.Windows.Forms.Panel
$actionPanel.Dock = 'Fill'
$actionPanel.BackColor = [System.Drawing.Color]::Transparent
$actionPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$main.Controls.Add($actionPanel, 0, 1)

$lblStatus = New-Label (T 'status.ready') 0 11 500 22
$lblStatus.ForeColor = $C.Muted
$actionPanel.Controls.Add($lblStatus)

$btnOpen = New-Button (T 'action.openOutput') 530 4 170 34 $false
$actionPanel.Controls.Add($btnOpen)

$btnCancel = New-Button (T 'action.cancel') 708 4 96 34 $false
$actionPanel.Controls.Add($btnCancel)

$btnStart = New-Button (T 'action.start') 812 4 112 34 $true
$actionPanel.Controls.Add($btnStart)

$actionPanel.Add_Resize({
    param($sender, $e)
    $w = $sender.ClientSize.Width
    $btnStart.Left = [Math]::Max(0, $w - $btnStart.Width)
    $btnCancel.Left = $btnStart.Left - 8 - $btnCancel.Width
    $btnOpen.Left = $btnCancel.Left - 8 - $btnOpen.Width
    $lblStatus.Width = [Math]::Max(150, $btnOpen.Left - 20)
})

# Log / notes
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = Get-UIFont
$tabs.Margin = New-Object System.Windows.Forms.Padding(0)
$main.Controls.Add($tabs, 0, 2)

$pageLog = New-Object System.Windows.Forms.TabPage
$pageLog.Text = T 'tabs.log'
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
$pageNotes.Text = T 'tabs.notes'
$pageNotes.BackColor = [System.Drawing.Color]::White
$pageNotes.Padding = New-Object System.Windows.Forms.Padding(10)
$tabs.Controls.Add($pageNotes)

$rtbNotes = New-Object System.Windows.Forms.RichTextBox
$rtbNotes.Dock = 'Fill'
$rtbNotes.ReadOnly = $true
$rtbNotes.BorderStyle = 'None'
$rtbNotes.BackColor = [System.Drawing.Color]::White
$rtbNotes.ForeColor = $C.Text
$rtbNotes.Font = Get-UIFont
$rtbNotes.ScrollBars = 'Vertical'
$rtbNotes.DetectUrls = $false
$rtbNotes.Text = T 'notes.body'
$pageNotes.Controls.Add($rtbNotes)

# ---------------- Helpers ----------------
function Normalize-Tasks {
    $sorted = @($script:Tasks | Sort-Object { $_.Time })
    $script:Tasks.Clear()
    foreach ($t in $sorted) { [void]$script:Tasks.Add($t) }
}
function Refresh-Grid {
    $script:gridUpdating = $true
    $grid.Rows.Clear()
    $selectedCount = 0
    foreach ($t in $script:Tasks) {
        $projText = $t.Project
        if (-not $projText) { $projText = T 'task.noneProject' }
        $chatText = $t.Chat
        if (-not $chatText) { $chatText = T 'task.currentChat' }
        $sum = [string]$t.Message
        $sum = $sum.Replace("`r`n", ' ').Replace("`n", ' ')
        if ($sum.Length -gt 60) { $sum = $sum.Substring(0, 60) + '…' }
        $resetText = T 'task.no'
        if ($t.UseReset) { $resetText = T 'task.yes' }
        if ($t.Selected) { $selectedCount++ }
        [void]$grid.Rows.Add([bool]$t.Selected, $t.Time.ToString('yyyy-MM-dd HH:mm:ss'), $projText, $chatText, $sum, $resetText)
    }
    $script:gridUpdating = $false
    $lblCount.Text = (T 'task.count' @($script:Tasks.Count, $selectedCount))
}
function Set-RunningUI([bool]$running) {
    $script:Running = $running
    if ($running) { $btnStart.Text = T 'action.running' } else { $btnStart.Text = T 'action.start' }
    $btnStart.BackColor = $C.Navy
    $btnStart.ForeColor = [System.Drawing.Color]::White
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
    if (-not $ok) { $ok = [datetime]::TryParse($text, [ref]$dt) }
    if ($ok) { return $dt }
    return $null
}
function Show-AboutDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = T 'about.title'
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 500)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = Get-UIFont
    try { $dlg.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }

    try {
        $logo = New-Object System.Windows.Forms.PictureBox
        $logo.Image = [System.Drawing.Image]::FromFile($script:IconPngPath)
        $logo.SizeMode = 'StretchImage'
        $logo.Location = New-Object System.Drawing.Point(24, 22)
        $logo.Size = New-Object System.Drawing.Size(48, 48)
        $dlg.Controls.Add($logo)
    } catch { }

    $name = New-Label (T 'app.title') 88 20 440 30
    $name.Font = New-Object System.Drawing.Font((Get-UIFont).Name, 14, [System.Drawing.FontStyle]::Bold)
    $name.ForeColor = $C.Navy
    $dlg.Controls.Add($name)

    $ver = New-Label (T 'about.version' @($script:VersionText)) 90 52 300 20
    $ver.ForeColor = $C.Muted
    $dlg.Controls.Add($ver)

    $purposeTitle = New-Label (T 'about.purposeTitle') 24 92 500 20
    $purposeTitle.Font = $fontSection
    $dlg.Controls.Add($purposeTitle)

    $purpose = New-Label (T 'about.purpose') 24 116 512 150
    $purpose.ForeColor = $C.Text
    $dlg.Controls.Add($purpose)

    $author = New-Label (T 'about.author') 24 264 500 20
    $dlg.Controls.Add($author)

    $email = New-Label (T 'about.email') 24 288 500 20
    $dlg.Controls.Add($email)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = T 'about.github'
    $link.Location = New-Object System.Drawing.Point(24, 312)
    $link.Size = New-Object System.Drawing.Size(500, 20)
    $link.Font = Get-UIFont
    $link.LinkColor = $C.Navy
    $link.ActiveLinkColor = $C.Navy
    $link.Add_LinkClicked({ try { Start-Process 'https://github.com/Yu010912' } catch { } })
    $dlg.Controls.Add($link)

    $licenseNote = New-Label (T 'about.nonCommercial') 24 344 512 44
    $licenseNote.ForeColor = $C.Muted
    $dlg.Controls.Add($licenseNote)

    $close = New-Button (T 'about.close') 440 448 96 32 $true
    $close.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($close)
    $dlg.AcceptButton = $close

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}
function Show-LicenseDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = T 'license.title'
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 560)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = Get-UIFont
    try { $dlg.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }

    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Location = New-Object System.Drawing.Point(20, 20)
    $box.Size = New-Object System.Drawing.Size(580, 460)
    $box.ReadOnly = $true
    $box.BorderStyle = 'FixedSingle'
    $box.BackColor = [System.Drawing.Color]::White
    $box.ForeColor = $C.Text
    $box.Font = Get-UIFont
    $box.WordWrap = $true
    $box.ScrollBars = 'Vertical'
    $box.Text = T 'license.body'
    $dlg.Controls.Add($box)

    $close = New-Button (T 'license.close') 500 496 100 34 $true
    $close.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($close)
    $dlg.AcceptButton = $close

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}
function Show-TaskDialog($task) {
    $dlg = New-Object System.Windows.Forms.Form
    if ($task) { $dlg.Text = T 'dialog.editTitle' } else { $dlg.Text = T 'dialog.addTitle' }
    $dlg.ClientSize = New-Object System.Drawing.Size(600, 612)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::White
    $dlg.Font = Get-UIFont
    try { $dlg.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }

    $l1 = New-Label (T 'dialog.timeLabel') 20 16 420 20
    $dlg.Controls.Add($l1)

    $rbAbs = New-Object System.Windows.Forms.RadioButton
    $rbAbs.Text = T 'dialog.absolute'
    $rbAbs.Location = New-Object System.Drawing.Point(20, 40)
    $rbAbs.Size = New-Object System.Drawing.Size(92, 24)
    $rbAbs.Font = Get-UIFont
    $rbAbs.ForeColor = $C.Text
    $rbAbs.Checked = $true
    $dlg.Controls.Add($rbAbs)

    $rbRel = New-Object System.Windows.Forms.RadioButton
    $rbRel.Text = T 'dialog.relative'
    $rbRel.Location = New-Object System.Drawing.Point(120, 40)
    $rbRel.Size = New-Object System.Drawing.Size(92, 24)
    $rbRel.Font = Get-UIFont
    $rbRel.ForeColor = $C.Text
    $dlg.Controls.Add($rbRel)

    $tTime = New-Object System.Windows.Forms.TextBox
    $tTime.Location = New-Object System.Drawing.Point(20, 70)
    $tTime.Size = New-Object System.Drawing.Size(300, 28)
    $tTime.Font = Get-UIFont
    $tTime.ForeColor = $C.Text
    $tTime.BackColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($tTime)

    $dtpDate = New-Object System.Windows.Forms.DateTimePicker
    $dtpDate.Format = 'Short'
    $dtpDate.Location = New-Object System.Drawing.Point(330, 70)
    $dtpDate.Size = New-Object System.Drawing.Size(150, 28)
    $dtpDate.Font = Get-UIFont
    $dlg.Controls.Add($dtpDate)

    $dtpTime = New-Object System.Windows.Forms.DateTimePicker
    $dtpTime.Format = 'Time'
    $dtpTime.ShowUpDown = $true
    $dtpTime.Location = New-Object System.Drawing.Point(488, 70)
    $dtpTime.Size = New-Object System.Drawing.Size(94, 28)
    $dtpTime.Font = Get-UIFont
    $dlg.Controls.Add($dtpTime)

    $hAbs = New-Label (T 'dialog.timeHint') 20 102 570 18
    $hAbs.ForeColor = $C.Muted
    $dlg.Controls.Add($hAbs)

    $relPanel = New-Object System.Windows.Forms.Panel
    $relPanel.Location = New-Object System.Drawing.Point(20, 126)
    $relPanel.Size = New-Object System.Drawing.Size(560, 32)
    $relPanel.BackColor = [System.Drawing.Color]::Transparent
    $dlg.Controls.Add($relPanel)

    $lblFrom = New-Label (T 'dialog.fromNow') 0 5 84 20
    $relPanel.Controls.Add($lblFrom)

    $numH = New-Object System.Windows.Forms.NumericUpDown
    $numH.Location = New-Object System.Drawing.Point(90, 2)
    $numH.Size = New-Object System.Drawing.Size(70, 28)
    $numH.Maximum = 9999
    $numH.Minimum = 0
    $numH.Value = 0
    $numH.Font = Get-UIFont
    $relPanel.Controls.Add($numH)

    $lblHour = New-Label (T 'dialog.hours') 166 5 24 20
    $relPanel.Controls.Add($lblHour)

    $numM = New-Object System.Windows.Forms.NumericUpDown
    $numM.Location = New-Object System.Drawing.Point(196, 2)
    $numM.Size = New-Object System.Drawing.Size(70, 28)
    $numM.Maximum = 59
    $numM.Minimum = 0
    $numM.Value = 10
    $numM.Font = Get-UIFont
    $relPanel.Controls.Add($numM)

    $lblMin = New-Label (T 'dialog.minutes') 272 5 24 20
    $relPanel.Controls.Add($lblMin)

    $lblSuffix = New-Label (T 'dialog.after') 302 5 60 20
    $relPanel.Controls.Add($lblSuffix)

    $lblPreview = New-Label (T 'dialog.previewEmpty') 372 5 184 20
    $lblPreview.ForeColor = $C.Navy
    $relPanel.Controls.Add($lblPreview)

    $hRel = New-Label (T 'dialog.relativeHint') 20 162 540 18
    $hRel.ForeColor = $C.Muted
    $dlg.Controls.Add($hRel)

    $l2 = New-Label (T 'dialog.projectLabel') 20 194 300 20
    $dlg.Controls.Add($l2)
    $tProj = New-Object System.Windows.Forms.TextBox
    $tProj.Location = New-Object System.Drawing.Point(20, 216)
    $tProj.Size = New-Object System.Drawing.Size(560, 28)
    $tProj.Font = Get-UIFont
    $tProj.ForeColor = $C.Text
    $dlg.Controls.Add($tProj)
    $h2 = New-Label (T 'dialog.projectHint') 20 246 500 18
    $h2.ForeColor = $C.Muted
    $dlg.Controls.Add($h2)

    $l3 = New-Label (T 'dialog.chatLabel') 20 276 300 20
    $dlg.Controls.Add($l3)
    $tChat = New-Object System.Windows.Forms.TextBox
    $tChat.Location = New-Object System.Drawing.Point(20, 298)
    $tChat.Size = New-Object System.Drawing.Size(560, 28)
    $tChat.Font = Get-UIFont
    $tChat.ForeColor = $C.Text
    $dlg.Controls.Add($tChat)
    $h3 = New-Label (T 'dialog.chatHint') 20 328 500 18
    $h3.ForeColor = $C.Muted
    $dlg.Controls.Add($h3)

    $l4 = New-Label (T 'dialog.messageLabel') 20 358 420 20
    $dlg.Controls.Add($l4)
    $tMsg = New-Object System.Windows.Forms.TextBox
    $tMsg.Location = New-Object System.Drawing.Point(20, 380)
    $tMsg.Size = New-Object System.Drawing.Size(560, 120)
    $tMsg.Multiline = $true
    $tMsg.AcceptsReturn = $true
    $tMsg.MaxLength = 0
    $tMsg.ScrollBars = 'Vertical'
    $tMsg.Font = Get-UIFont
    $tMsg.ForeColor = $C.Text
    $dlg.Controls.Add($tMsg)
    $h4 = New-Label (T 'dialog.messageHint') 20 504 400 18
    $h4.ForeColor = $C.Muted
    $dlg.Controls.Add($h4)

    $chkResetDlg = New-Object System.Windows.Forms.CheckBox
    $chkResetDlg.Text = T 'dialog.resetCheck'
    $chkResetDlg.Location = New-Object System.Drawing.Point(20, 528)
    $chkResetDlg.Size = New-Object System.Drawing.Size(560, 24)
    $chkResetDlg.Font = Get-UIFont
    $chkResetDlg.ForeColor = $C.Text
    $dlg.Controls.Add($chkResetDlg)

    $script:dialogUpdating = $false
    function Update-RelPreview {
        if (-not $rbRel.Checked) { $lblPreview.Text = T 'dialog.previewEmpty'; return }
        $d = (Get-Date).AddHours([double]$numH.Value).AddMinutes([double]$numM.Value)
        $lblPreview.Text = (T 'dialog.preview' @($d.ToString('MM-dd HH:mm:ss')))
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
        $tTime.Visible = $abs
        $dtpDate.Visible = $abs
        $dtpTime.Visible = $abs
        $hAbs.Visible = $abs
        $relPanel.Visible = -not $abs
        $hRel.Visible = -not $abs
        if (-not $abs) { Update-RelPreview }
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

    $btnSaveDlg = New-Button (T 'dialog.save') 380 548 90 32 $true
    $btnSaveDlg.Add_Click({
        $dt = $null
        if ($rbAbs.Checked) {
            $dt = Parse-TaskTime $tTime.Text
            if (-not $dt) {
                [void][System.Windows.Forms.MessageBox]::Show($dlg, (T 'msg.timeFormat'), (T 'msg.titleWarning'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
        } else {
            $h = [double]$numH.Value
            $m = [double]$numM.Value
            if ($h -eq 0 -and $m -eq 0) {
                $ans0 = [System.Windows.Forms.MessageBox]::Show($dlg, (T 'msg.relativeZero'), (T 'msg.titleConfirm'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($ans0 -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            $dt = (Get-Date).AddHours($h).AddMinutes($m)
        }
        if (-not $tMsg.Text -or $tMsg.Text.Trim().Length -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, (T 'msg.messageRequired'), (T 'msg.titleWarning'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($dt -lt (Get-Date)) {
            $ans = [System.Windows.Forms.MessageBox]::Show($dlg, (T 'msg.pastConfirm'), (T 'msg.titleConfirm'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $script:DialogTask = [PSCustomObject]@{
            Time     = $dt
            Project  = $tProj.Text.Trim()
            Chat     = $tChat.Text.Trim()
            Message  = $tMsg.Text
            UseReset = [bool]$chkResetDlg.Checked
            Selected = $true
        }
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSaveDlg)

    $btnCancelDlg = New-Button (T 'dialog.cancel') 480 548 90 32 $false
    $btnCancelDlg.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCancelDlg)
    $dlg.CancelButton = $btnCancelDlg

    $script:DialogTask = $null
    [void]$dlg.ShowDialog($form)
    $result = $script:DialogTask
    $dlg.Dispose()
    return $result
}

function Apply-Language {
    $form.Font = Get-UIFont
    $form.Text = T 'app.title'
    $lblTitle.Font = New-Object System.Drawing.Font((Get-UIFont).Name, 16, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Text = T 'app.title'
    $lblSub.Text = T 'app.subtitle'
    $lblVer.Text = T 'app.version'
    $btnAbout.Text = T 'header.about'
    $btnLicense.Text = T 'header.license'
    $lblTaskTitle.Font = New-Object System.Drawing.Font((Get-UIFont).Name, 10, [System.Drawing.FontStyle]::Bold)
    $lblTaskTitle.Text = T 'task.title'
    $grid.Columns[0].HeaderText = T 'task.select'
    $grid.Columns[1].HeaderText = T 'task.time'
    $grid.Columns[2].HeaderText = T 'task.project'
    $grid.Columns[3].HeaderText = T 'task.chat'
    $grid.Columns[4].HeaderText = T 'task.message'
    $grid.Columns[5].HeaderText = T 'task.reset'
    $btnAdd.Text = T 'task.add'
    $btnEdit.Text = T 'task.edit'
    $btnDel.Text = T 'task.delete'
    $lblHint.Text = T 'task.hint'
    $btnOpen.Text = T 'action.openOutput'
    $btnCancel.Text = T 'action.cancel'
    if ($script:Running) { $btnStart.Text = T 'action.running' } else { $btnStart.Text = T 'action.start' }
    $pageLog.Text = T 'tabs.log'
    $pageNotes.Text = T 'tabs.notes'
    $rtbNotes.Text = T 'notes.body'
    if (-not $script:Running) {
        $lblStatus.Text = T 'status.ready'
        $lblStatus.ForeColor = $C.Muted
    }
    $script:ApplyingLang = $true
    $cboLang.Items.Clear()
    [void]$cboLang.Items.Add((T 'lang.english'))
    [void]$cboLang.Items.Add((T 'lang.chinese'))
    if ($script:LangCode -eq 'zh') { $cboLang.SelectedIndex = 1 } else { $cboLang.SelectedIndex = 0 }
    $script:ApplyingLang = $false
    Refresh-Grid
}

# ---------------- Events ----------------
$btnAbout.Add_Click({ Show-AboutDialog })
$btnLicense.Add_Click({ Show-LicenseDialog })
$cboLang.Add_SelectedIndexChanged({
    if ($script:ApplyingLang) { return }
    $code = 'en'
    if ($cboLang.SelectedIndex -eq 1) { $code = 'zh' }
    if ($code -eq $script:LangCode) { return }
    Save-Language $code
    Load-Language $code
    Apply-Language
})
$btnAdd.Add_Click({
    if ($script:Running) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.runningLock'), (T 'msg.titleInfo'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $r = Show-TaskDialog $null
    if ($r) {
        [void]$script:Tasks.Add($r)
        Normalize-Tasks
        Refresh-Grid
    }
})
$btnEdit.Add_Click({
    if ($script:Running) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.runningLock'), (T 'msg.titleInfo'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if ($grid.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.selectFirst'), (T 'msg.titleInfo'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $idx = $grid.SelectedRows[0].Index
    if ($idx -lt 0 -or $idx -ge $script:Tasks.Count) { return }
    $r = Show-TaskDialog $script:Tasks[$idx]
    if ($r) {
        $r.Selected = [bool]$script:Tasks[$idx].Selected
        $script:Tasks[$idx] = $r
        Normalize-Tasks
        Refresh-Grid
    }
})
$btnDel.Add_Click({
    if ($script:Running) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.runningLock'), (T 'msg.titleInfo'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if ($grid.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.selectFirst'), (T 'msg.titleInfo'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $idx = $grid.SelectedRows[0].Index
    if ($idx -lt 0 -or $idx -ge $script:Tasks.Count) { return }
    $ans = [System.Windows.Forms.MessageBox]::Show((T 'msg.deleteConfirm'), (T 'msg.titleDelete'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:Tasks.RemoveAt($idx)
        Refresh-Grid
    }
})
$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($script:Running) { return }
    if ($e.RowIndex -ge 0 -and $e.RowIndex -lt $script:Tasks.Count) {
        $r = Show-TaskDialog $script:Tasks[$e.RowIndex]
        if ($r) {
            $r.Selected = [bool]$script:Tasks[$e.RowIndex].Selected
            $script:Tasks[$e.RowIndex] = $r
            Normalize-Tasks
            Refresh-Grid
        }
    }
})
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) {
        $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})
$grid.Add_CellValueChanged({
    param($sender, $e)
    if ($script:gridUpdating) { return }
    if ($e.RowIndex -lt 0 -or $e.RowIndex -ge $script:Tasks.Count) { return }
    if ($e.ColumnIndex -ne 0) { return }
    $script:Tasks[$e.RowIndex].Selected = [bool]$grid.Rows[$e.RowIndex].Cells[0].Value
    $sel = @($script:Tasks | Where-Object { $_.Selected }).Count
    $lblCount.Text = (T 'task.count' @($script:Tasks.Count, $sel))
})
$btnOpen.Add_Click({
    $folder = $script:RunFolder
    if (-not $folder) { $folder = Join-Path $script:RootDir 'output' }
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    Start-Process explorer.exe $folder
})
$btnCancel.Add_Click({
    if (-not $script:EngineProc -or $script:EngineProc.HasExited) { return }
    try { $script:EngineProc.Kill() } catch { }
    $rtbLog.AppendText("$(Get-Date -Format 'HH:mm:ss') " + (T 'status.cancelHint') + "`r`n")
    $timer.Stop()
    $lblStatus.Text = T 'status.cancelled'
    $lblStatus.ForeColor = $C.Danger
    Set-RunningUI $false
    $script:EngineProc = $null
})
$btnStart.Add_Click({
    if ($script:Running) { return }
    if ($script:Tasks.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.noTasks'), (T 'msg.titleWarning'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $selectedTasks = @($script:Tasks | Where-Object { $_.Selected })
    if ($selectedTasks.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.selectOne'), (T 'msg.titleWarning'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    foreach ($t in $selectedTasks) {
        if (-not $t.Message -or $t.Message.Trim().Length -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show((T 'msg.emptySelected'), (T 'msg.titleWarning'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
    }
    $resetCount = @($selectedTasks | Where-Object { $_.UseReset }).Count
    if ($resetCount -ge 2) {
        $warn = [System.Windows.Forms.MessageBox]::Show((T 'msg.resetWarning' @($selectedTasks.Count, $resetCount)), (T 'msg.titleRisk'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($warn -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    if (-not (Test-Path $script:EnginePath)) {
        [void][System.Windows.Forms.MessageBox]::Show((T 'msg.engineMissing'), (T 'msg.titleError'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $nextTask = ($selectedTasks | Sort-Object { $_.Time } | Select-Object -First 1)
    $confirm = [System.Windows.Forms.MessageBox]::Show((T 'msg.startConfirm' @($selectedTasks.Count, $nextTask.Time.ToString('yyyy-MM-dd HH:mm:ss'))), (T 'msg.titleStart'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $outRoot = Join-Path $script:RootDir 'output'
    if (-not (Test-Path $outRoot)) { New-Item -ItemType Directory -Path $outRoot -Force | Out-Null }
    $runFolder = Join-Path $outRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
    $cfgPath = Join-Path $runFolder 'config.json'

    $taskList = @()
    foreach ($t in $selectedTasks) {
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
    $rtbLog.AppendText("$(Get-Date -Format 'HH:mm:ss') " + (T 'msg.saved' @($selectedTasks.Count, $runFolder)) + "`r`n")

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
    $lblStatus.Text = T 'status.running'
    $lblStatus.ForeColor = $C.Navy
    $timer.Start()
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:EngineProc -and -not $script:EngineProc.HasExited) {
        $ans = [System.Windows.Forms.MessageBox]::Show((T 'msg.exitRunning'), (T 'msg.titleExit'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
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

# ---------------- Timer ----------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({
    Tail-Log
    if ($script:EngineProc) {
        if ($script:EngineProc.HasExited) {
            $timer.Stop()
            $code = $script:EngineProc.ExitCode
            if ($code -eq 0) {
                $lblStatus.Text = (T 'status.done' @((Get-Date -Format 'HH:mm:ss')))
                $lblStatus.ForeColor = $C.Accent
            } else {
                $lblStatus.Text = (T 'status.exit' @($code))
                $lblStatus.ForeColor = $C.Danger
            }
            Set-RunningUI $false
            $script:EngineProc = $null
        } elseif ($script:Tasks.Count -gt 0) {
            $pending = @($script:Tasks | Where-Object { $_.Time -gt (Get-Date) } | Sort-Object { $_.Time } | Select-Object -First 1)
            if ($pending) {
                $left = $pending.Time - (Get-Date)
                $lblStatus.Text = (T 'status.waiting' @($pending.Time.ToString('MM-dd HH:mm:ss'), $left.ToString('hh\:mm\:ss')))
                $lblStatus.ForeColor = $C.Navy
            } else {
                $lblStatus.Text = T 'status.running'
                $lblStatus.ForeColor = $C.Navy
            }
        } else {
            $lblStatus.Text = T 'status.running'
        }
    }
})

Apply-Language
[void]$form.ShowDialog()
$form.Dispose()
