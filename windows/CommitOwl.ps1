# =====================================================================
#  CommitOwl - daily auto commit and push for electronics projects
#  The window: pick repositories, set the daily time, read the log.
#
#  Developed by: EMR Industries
#  Version 1.3 - Built 2026.11.06
# =====================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

# If anything stops the window from opening, say so instead of failing silently
trap {
    $why  = $_.Exception.Message
    $line = $_.InvocationInfo.ScriptLineNumber
    $file = Split-Path -Leaf ([string]$_.InvocationInfo.ScriptName)
    try {
        $log = Join-Path $env:USERPROFILE 'commitowl.log'
        [IO.File]::AppendAllText($log, ('{0}  [ERROR] CommitOwl window could not start ({1} line {2}): {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $file, $line, $why) + "`r`n")
    } catch { }
    [System.Windows.Forms.MessageBox]::Show("CommitOwl could not start.`n`n$why`n`n($file, line $line)", 'CommitOwl', 'OK', 'Error') | Out-Null
    exit 1
}

. (Join-Path $PSScriptRoot 'commitowl-common.ps1')

# Files downloaded from the internet are blocked; unblock our own files once
try { Get-ChildItem -LiteralPath $PSScriptRoot -File | Unblock-File -ErrorAction SilentlyContinue } catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()

$IconFile = Find-OwlFile 'assets\commitowl.ico'
$LogoFile = Find-OwlFile 'assets\commitowl.png'
$IgnoreTemplate = Find-OwlFile 'electronics.gitignore'
$Worker = Join-Path $PSScriptRoot 'commitowl-run.ps1'

$script:Config  = Get-OwlConfig
$script:Running = $null
$script:Loading = $false

function Show-Msg([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [System.Windows.Forms.MessageBox]::Show($form, $Text, 'CommitOwl',
        [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

if (-not $script:Git) {
    [System.Windows.Forms.MessageBox]::Show("git.exe was not found.`n`nInstall Git for Windows from https://git-scm.com/download/win, then start CommitOwl again.", 'CommitOwl', 'OK', 'Error') | Out-Null
    exit 1
}

# ---------------------------------------------------------------------
# Window (self-sizing layout, works at any display scaling)
# ---------------------------------------------------------------------
$font = New-Object System.Drawing.Font('Segoe UI', 9)
$mono = New-Object System.Drawing.Font('Consolas', 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = "CommitOwl $script:AppVersion"
$form.Font = $font
$form.StartPosition = 'CenterScreen'
$g = $form.CreateGraphics(); $dpi = $g.DpiX / 96.0; $g.Dispose()
$form.Size = New-Object System.Drawing.Size([int](900 * $dpi), [int](620 * $dpi))
$form.MinimumSize = New-Object System.Drawing.Size([int](720 * $dpi), [int](480 * $dpi))
if (Test-Path -LiteralPath $IconFile) { $form.Icon = New-Object System.Drawing.Icon $IconFile }

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)

function New-Button([string]$Text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
    $b
}
function New-Label([string]$Text, [bool]$Grey = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 6, 6)
    if ($Grey) { $l.ForeColor = [System.Drawing.Color]::DimGray }
    $l
}
function New-Flow {
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true
    $f.AutoSizeMode = 'GrowAndShrink'
    $f.WrapContents = $true
    $f.Dock = 'Fill'
    $f.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $f
}
# A one-column grid; rows are added top to bottom. Pass -Fill for the row that takes the spare height.
function New-Grid([System.Windows.Forms.Control]$Parent) {
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.Dock = 'Fill'
    $t.ColumnCount = 1
    $t.RowCount = 0
    $t.Padding = New-Object System.Windows.Forms.Padding(8)
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    $Parent.Controls.Add($t)
    $t
}
function Add-Row($Grid, $Control, [switch]$Fill) {
    if ($Fill) { [void]$Grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100))) }
    else       { [void]$Grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
    $Grid.RowCount++
    if ($Fill) { $Control.Dock = 'Fill' }
    $Grid.Controls.Add($Control, 0, $Grid.RowCount - 1)
}

# =============================== Tab 1: Repositories ===============================
$tabRepos = New-Object System.Windows.Forms.TabPage
$tabRepos.Text = 'Repositories'
$tabs.TabPages.Add($tabRepos)
$gridRepos = New-Grid $tabRepos

$lblIntro = New-Label 'Active repositories are committed and pushed every day. Use the Auto push drop-down to pause one, for a day or until you resume it.'
Add-Row $gridRepos $lblIntro

$PauseChoices = @('Active', 'Pause 1 day', 'Pause 3 days', 'Pause 1 week', 'Pause until I resume')

$grid = New-Object System.Windows.Forms.DataGridView
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AllowUserToOrderColumns = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.EditMode = 'EditOnKeystrokeOrF2'
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.BorderStyle = 'Fixed3D'
$grid.ColumnHeadersHeightSizeMode = 'AutoSize'
$grid.AutoSizeRowsMode = 'AllCells'
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(204, 228, 247)
$grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black

function Add-GridText([string]$Header, [int]$Width) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.HeaderText = $Header
    $c.Width = [int]($Width * $dpi)
    $c.ReadOnly = $true
    $c.SortMode = 'NotSortable'
    [void]$grid.Columns.Add($c)
    $c
}
[void](Add-GridText 'Repository' 260)
$colPause = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colPause.HeaderText = 'Auto push'
$colPause.Width = [int](160 * $dpi)
$colPause.DisplayStyle = 'DropDownButton'
$colPause.FlatStyle = 'Flat'   # draws the text in normal black instead of the faded system style
$colPause.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Black
$colPause.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
$colPause.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
$colPause.ToolTipText = 'Pause daily commit and push for this repository. Pause 1 day skips today.'
[void]$colPause.Items.AddRange([object[]]$PauseChoices)
[void]$grid.Columns.Add($colPause)
[void](Add-GridText 'Branch' 80)
[void](Add-GridText 'Remote' 65)
[void](Add-GridText 'Last push' 110)
$colHash = Add-GridText 'Commit' 70
$colHash.DefaultCellStyle.Font = $mono
$colHash.ToolTipText = 'Last commit (short hash). Double-click to copy it.'
$colResult = Add-GridText 'Result' 200
$colResult.AutoSizeMode = 'Fill'
Add-Row $gridRepos $grid -Fill

$btnAdd    = New-Button 'Add repository...'
$btnRemove = New-Button 'Remove'
$btnRunOne = New-Button 'Commit && Push'
$btnRunAll = New-Button 'Commit && Push all'
$btnIgnore = New-Button 'Add .gitignore'
$btnOpen   = New-Button 'Open folder'
$flowRepos = New-Flow
$flowRepos.Controls.AddRange(@($btnAdd, $btnRemove, $btnRunOne, $btnRunAll, $btnIgnore, $btnOpen))
Add-Row $gridRepos $flowRepos

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnRunOne, 'Commit all changes in the selected repository and push them now')
$tips.SetToolTip($btnRunAll, 'Commit and push every active repository now (paused ones are skipped)')

$lblStatus = New-Label '' $true
Add-Row $gridRepos $lblStatus

# =============================== Tab: Commit message ===============================
$tabMsg = New-Object System.Windows.Forms.TabPage
$tabMsg.Text = 'Commit message'
$tabs.TabPages.Add($tabMsg)
$gridMsg = New-Grid $tabMsg

Add-Row $gridMsg (New-Label 'Every automatic commit starts with this header line. It is added for you and cannot be changed:')
$txtHeader = New-Object System.Windows.Forms.TextBox
$txtHeader.ReadOnly = $true
$txtHeader.Font = $mono
$txtHeader.Text = 'Auto-commit YYYY-MM-DD HH:mm (N files)'
$txtHeader.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
Add-Row $gridMsg $txtHeader
$txtHeader.Dock = 'Fill'

Add-Row $gridMsg (New-Label 'Your message, added below the header (leave empty for the default line):')
$txtMsg = New-Object System.Windows.Forms.TextBox
$txtMsg.Multiline = $true
$txtMsg.AcceptsReturn = $true
$txtMsg.ScrollBars = 'Vertical'
$txtMsg.Font = $mono
Add-Row $gridMsg $txtMsg -Fill

$chkList = New-Object System.Windows.Forms.CheckBox
$chkList.Text = 'Add the list of changed files at the end'
$chkList.AutoSize = $true
$chkList.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
Add-Row $gridMsg $chkList

Add-Row $gridMsg (New-Label 'Preview')
$txtPreview = New-Object System.Windows.Forms.TextBox
$txtPreview.Multiline = $true
$txtPreview.ReadOnly = $true
$txtPreview.ScrollBars = 'Vertical'
$txtPreview.Font = $mono
$txtPreview.BackColor = [System.Drawing.Color]::FromArgb(246, 246, 246)
Add-Row $gridMsg $txtPreview -Fill

$btnMsgSave  = New-Button 'Save message'
$btnMsgReset = New-Button 'Use default'
$lblMsgState = New-Label '' $true
$flowMsg = New-Flow; $flowMsg.Controls.AddRange(@($btnMsgSave, $btnMsgReset, $lblMsgState))
Add-Row $gridMsg $flowMsg

# =============================== Tab 2: Schedule & log ===============================
$tabSched = New-Object System.Windows.Forms.TabPage
$tabSched.Text = 'Schedule & log'
$tabs.TabPages.Add($tabSched)
$gridSched = New-Grid $tabSched

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Daily commit and push'
$grp.AutoSize = $true
$grp.AutoSizeMode = 'GrowAndShrink'
$grp.Dock = 'Fill'
$grp.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
$gridGrp = New-Grid $grp
$gridGrp.AutoSize = $true
$gridGrp.AutoSizeMode = 'GrowAndShrink'
$gridGrp.Dock = 'Top'
$gridGrp.Padding = New-Object System.Windows.Forms.Padding(0)

$chkDaily = New-Object System.Windows.Forms.CheckBox
$chkDaily.Text = 'Commit and push every day at'
$chkDaily.AutoSize = $true
$chkDaily.Margin = New-Object System.Windows.Forms.Padding(0, 5, 4, 0)
$time = New-Object System.Windows.Forms.DateTimePicker
$time.Format = 'Custom'
$time.CustomFormat = 'HH:mm'
$time.ShowUpDown = $true
$time.Width = [int](70 * $dpi)
$time.Value = (Get-Date).Date.AddHours(21)
$lblCatch = New-Label 'If the PC is off or asleep then, it runs as soon as you are back.' $true
$row1 = New-Flow; $row1.Controls.AddRange(@($chkDaily, $time, $lblCatch))
Add-Row $gridGrp $row1

$lblNotify = New-Label 'Notify me'
$cmbNotify = New-Object System.Windows.Forms.ComboBox
$cmbNotify.DropDownStyle = 'DropDownList'
[void]$cmbNotify.Items.AddRange(@('Only when something needs attention', 'After every push', 'Never'))
$cmbNotify.Width = [int](240 * $dpi)
$cmbNotify.Margin = New-Object System.Windows.Forms.Padding(0, 2, 20, 0)
$lblMax = New-Label 'Skip files larger than (MB)'
$numMax = New-Object System.Windows.Forms.NumericUpDown
$numMax.Minimum = 1
$numMax.Maximum = 2000
$numMax.Width = [int](70 * $dpi)
$row2 = New-Flow; $row2.Controls.AddRange(@($lblNotify, $cmbNotify, $lblMax, $numMax))
Add-Row $gridGrp $row2

$btnSave = New-Button 'Save schedule'
$lblTask = New-Label '' $true
$row3 = New-Flow; $row3.Controls.AddRange(@($btnSave, $lblTask))
Add-Row $gridGrp $row3

Add-Row $gridSched $grp

$lblLog = New-Label "Log ($script:LogFile)"
Add-Row $gridSched $lblLog

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Both'
$txtLog.WordWrap = $false
$txtLog.Font = $mono
$txtLog.BackColor = [System.Drawing.Color]::White
Add-Row $gridSched $txtLog -Fill

$btnRefresh = New-Button 'Refresh'
$btnLogOpen = New-Button 'Open log'
$flowLog = New-Flow; $flowLog.Controls.AddRange(@($btnRefresh, $btnLogOpen))
Add-Row $gridSched $flowLog

# =============================== Tab 3: About ===============================
$tabAbout = New-Object System.Windows.Forms.TabPage
$tabAbout.Text = 'About'
$tabs.TabPages.Add($tabAbout)

$flowAbout = New-Object System.Windows.Forms.FlowLayoutPanel
$flowAbout.Dock = 'Fill'
$flowAbout.WrapContents = $false
$flowAbout.Padding = New-Object System.Windows.Forms.Padding(20)
$tabAbout.Controls.Add($flowAbout)

if (Test-Path -LiteralPath $LogoFile) {
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Image = [System.Drawing.Image]::FromFile($LogoFile)
    $pic.SizeMode = 'Zoom'
    $pic.Size = New-Object System.Drawing.Size([int](96 * $dpi), [int](96 * $dpi))
    $pic.Margin = New-Object System.Windows.Forms.Padding(0, 0, 16, 0)
    $flowAbout.Controls.Add($pic)
}
$aboutText = New-Object System.Windows.Forms.FlowLayoutPanel
$aboutText.FlowDirection = 'TopDown'
$aboutText.WrapContents = $false
$aboutText.AutoSize = $true
$flowAbout.Controls.Add($aboutText)

$lblName = New-Label 'CommitOwl'
$lblName.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$lblName.Margin = New-Object System.Windows.Forms.Padding(0)
$aboutText.Controls.Add($lblName)

$lblAbout = New-Label ("Daily auto commit and push for electronics projects.`n`n" +
    "Version:  $script:AppVersion`n" +
    "Developed by:  $script:AppVendor`n" +
    "Build date:  $script:AppBuildDate`n`n" +
    "Every day CommitOwl commits all changes in your design repositories and pushes them,`n" +
    "so schematics, layouts and firmware are backed up even when you forget to commit.`n" +
    "It works with Git for Windows and any Git client you already use.`n`n" +
    "Free and open source under the MIT License.`n" +
    "Copyright (c) 2026 $script:AppVendor`n`n" +
    "Git is a trademark of its respective owner. CommitOwl is an independent tool`n" +
    "and is not affiliated with or endorsed by the Git project.")
$aboutText.Controls.Add($lblAbout)

# ---------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------
function Set-Busy([bool]$Busy) {
    foreach ($b in @($btnAdd, $btnRemove, $btnRunOne, $btnRunAll, $btnIgnore)) { $b.Enabled = -not $Busy }
    $form.Cursor = $(if ($Busy) { [System.Windows.Forms.Cursors]::AppStarting } else { [System.Windows.Forms.Cursors]::Default })
}

function Get-SelectedRepo {
    if ($null -eq $grid.CurrentRow) {
        Show-Msg 'Select a repository in the list first.' | Out-Null
        return $null
    }
    return $grid.CurrentRow.Tag
}

function Get-RepoCounts {
    $all = @($script:Config.repos)
    $active = @($all | Where-Object { -not (Get-OwlPause $_) }).Count
    return @($active, $all.Count)
}

function Update-StatusText {
    if ($script:Running) { return }
    $c = Get-RepoCounts
    $paused = $c[1] - $c[0]
    $lblStatus.Text = "$($c[0]) of $($c[1]) repositories are committed and pushed every day." + $(if ($paused) { " $paused paused." } else { '' })
}

function Update-RepoList {
    $script:Loading = $true
    try {
        $state = Get-OwlState
        $sel = $(if ($grid.CurrentRow) { $grid.CurrentRow.Tag.path } else { $null })
        [void]$grid.EndEdit()
        $grid.Rows.Clear()
        foreach ($r in @($script:Config.repos)) {
            $i = $grid.Rows.Add()
            $row = $grid.Rows[$i]
            $row.Tag = $r
            $row.Cells[0].Value = $r.path

            $until = Get-OwlPause $r
            $label = $(if ($until) { Format-OwlPause $until } else { 'Active' })
            $cell = $row.Cells[1]
            $cell.Items.Clear()
            [void]$cell.Items.AddRange([object[]](@($label) + @($PauseChoices | Where-Object { $_ -ne $label })))
            $cell.Value = $label

            $br = $r.branch
            if (-not $br) {
                if (-not (Test-Path -LiteralPath $r.path)) { $br = '(missing)' }
                else {
                    $h = Invoke-Git $r.path @('symbolic-ref', '--quiet', '--short', 'HEAD')
                    $br = $(if ($h.ExitCode -eq 0) { Get-GitText $h } else { '?' })
                }
            }
            $row.Cells[2].Value = [string]$br
            $row.Cells[3].Value = $r.remote

            $st = $state[$r.path.ToLowerInvariant()]
            if ($st) {
                $row.Cells[4].Value = [string]$st.time
                $row.Cells[5].Value = $(if ($st.hash) { [string]$st.hash } else { '-' })
                $row.Cells[6].Value = [string]$st.detail
                if ($st.result -in @('error', 'conflict')) { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick }
                elseif ($st.result -eq 'local') { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkOrange }
            } else {
                $row.Cells[4].Value = '-'
                $row.Cells[5].Value = '-'
                $row.Cells[6].Value = 'Not pushed yet'
            }
            if ($until) { $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
            $cell.Style.ForeColor = [System.Drawing.Color]::Black   # drop-down text stays black, even on grey or red rows
            if ($sel -and $r.path -eq $sel) { $grid.CurrentCell = $row.Cells[0] }
        }
    } finally {
        $script:Loading = $false
    }
    Update-StatusText
}

# Applies a choice from the Auto push drop-down. Returns $true if something changed.
function Set-RepoPause($Repo, [string]$Choice) {
    switch ($Choice) {
        'Active'               { $Repo.enabled = $true;  $Repo.pausedUntil = '' }
        'Pause 1 day'          { $Repo.enabled = $true;  $Repo.pausedUntil = (Get-Date).Date.AddDays(1).ToString('yyyy-MM-dd') }
        'Pause 3 days'         { $Repo.enabled = $true;  $Repo.pausedUntil = (Get-Date).Date.AddDays(3).ToString('yyyy-MM-dd') }
        'Pause 1 week'         { $Repo.enabled = $true;  $Repo.pausedUntil = (Get-Date).Date.AddDays(7).ToString('yyyy-MM-dd') }
        'Pause until I resume' { $Repo.enabled = $false; $Repo.pausedUntil = '' }
        default { return $false }   # the current state was picked again
    }
    $name = Split-Path -Leaf $Repo.path
    $until = Get-OwlPause $Repo
    Write-OwlLog $(if ($until) { "[$name] [PAUSED] $(Format-OwlPause $until)." } else { "[$name] Auto push resumed." }) | Out-Null
    return $true
}

function Update-Log {
    if (Test-Path -LiteralPath $script:LogFile) {
        $txtLog.Text = (Get-Content -LiteralPath $script:LogFile -Tail 400 -Encoding UTF8) -join "`r`n"
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    } else {
        $txtLog.Text = 'Nothing has been pushed yet.'
    }
}

function Get-OwlTask {
    Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskName -ErrorAction SilentlyContinue
}

function Register-OwlTask([datetime]$At) {
    $vbs = Join-Path $PSScriptRoot 'commitowl-hidden.vbs'
    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"') -WorkingDirectory $PSScriptRoot
    $trigger  = New-ScheduledTaskTrigger -Daily -At $At
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $desc = 'CommitOwl by EMR Industries: commits and pushes your electronics project repositories once a day.'
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description $desc -Force | Out-Null
}

# Version 1.0/1.1 named the task "Daily snapshot". Move it to the new name, same time.
function Convert-LegacyTask {
    try {
        $old = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:LegacyTaskName -ErrorAction SilentlyContinue
        if (-not $old) { return }
        if (-not (Get-OwlTask) -and $old.State -ne 'Disabled') {
            Register-OwlTask ((Get-Date).Date.Add(([datetime]$old.Triggers[0].StartBoundary).TimeOfDay))
        }
        Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:LegacyTaskName -Confirm:$false
    } catch { }
}

function Update-Schedule {
    $map = @{ problems = 0; always = 1; never = 2 }
    $cmbNotify.SelectedIndex = $(if ($map.ContainsKey([string]$script:Config.notify)) { $map[[string]$script:Config.notify] } else { 0 })
    $numMax.Value = [decimal][Math]::Min(2000, [Math]::Max(1, [int]$script:Config.maxFileMB))
    $t = Get-OwlTask
    if ($t) {
        $chkDaily.Checked = ($t.State -ne 'Disabled')
        try { $time.Value = (Get-Date).Date.Add(([datetime]$t.Triggers[0].StartBoundary).TimeOfDay) } catch { }
        $info = Get-ScheduledTaskInfo -TaskPath $script:TaskPath -TaskName $script:TaskName -ErrorAction SilentlyContinue
        $next = $(if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('ddd d MMM, HH:mm') } else { '-' })
        $last = '-'
        if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) {
            $res = $(switch ($info.LastTaskResult) { 0 { 'OK' } 1 { 'needs attention, see log' } 3 { 'stopped: conflict' } 267009 { 'running' } default { "code $($info.LastTaskResult)" } })
            $last = $info.LastRunTime.ToString('ddd d MMM, HH:mm') + " ($res)"
        }
        $lblTask.Text = $(if ($t.State -eq 'Disabled') { 'Schedule is off.' } else { "Next push: $next     Last: $last" })
    } else {
        $chkDaily.Checked = $false
        $lblTask.Text = 'No schedule yet. Tick the box, pick a time and click Save schedule.'
    }
}

function Save-Schedule {
    $script:Config.notify = @('problems', 'always', 'never')[[Math]::Max(0, $cmbNotify.SelectedIndex)]
    $script:Config.maxFileMB = [int]$numMax.Value
    Save-OwlConfig $script:Config

    $existing = Get-OwlTask
    if (-not $chkDaily.Checked) {
        if ($existing) { Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:TaskName -Confirm:$false }
        Update-Schedule
        Show-Msg 'Daily commit and push is off. Your repositories stay in the list.' | Out-Null
        return
    }
    Register-OwlTask $time.Value
    Update-Schedule
    Show-Msg ('Saved. CommitOwl will commit and push every day at ' + $time.Value.ToString('HH:mm') + '.') | Out-Null
}

function Start-OwlRun([string]$RepoPath) {
    if ($script:Running) { return }
    $argList = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Worker + '" -Manual'
    if ($RepoPath) { $argList += ' -RepoPath "' + $RepoPath + '"' }
    # Start PowerShell with no console window at all (no flash, also with Windows Terminal)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = $argList
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:Running = [System.Diagnostics.Process]::Start($psi)
    Set-Busy $true
    $lblStatus.Text = $(if ($RepoPath) { "Committing and pushing $(Split-Path -Leaf $RepoPath)..." } else { 'Committing and pushing all active repositories...' })
    $timer.Start()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($script:Running -and $script:Running.HasExited) {
        $timer.Stop()
        $code = $script:Running.ExitCode
        $script:Running = $null
        Set-Busy $false
        Update-RepoList
        Update-Log
        $lblStatus.Text = $(if ($code -eq 0) { 'Commit and push finished.' } else { 'Commit and push finished with problems. See the Result column and the log.' })
        if ($code -eq 3) {
            $state = Get-OwlState
            $names = @($script:Config.repos | Where-Object { $s = $state[$_.path.ToLowerInvariant()]; $s -and $s.result -eq 'conflict' } | ForEach-Object { Split-Path -Leaf $_.path })
            Show-Msg ("Auto commit stopped: conflict with the remote in " + ($names -join ', ') + ".`n`nThe remote has changes to the same files. Nothing was pushed, and your work is committed locally.`n`nPull and resolve the conflict in your Git client (git pull). The next run pushes it.") 'Warning' | Out-Null
        }
    }
})

function Test-GitIdentity([string]$Repo) {
    $n = Invoke-Git $Repo @('config', 'user.name')
    $e = Invoke-Git $Repo @('config', 'user.email')
    if ($n.ExitCode -eq 0 -and $e.ExitCode -eq 0) { return }
    Show-Msg "Git needs your name and email to sign commits. You will be asked for them now (saved in your global Git settings)." | Out-Null
    $name  = [Microsoft.VisualBasic.Interaction]::InputBox('Your name for Git commits:', 'CommitOwl', $env:USERNAME)
    $email = [Microsoft.VisualBasic.Interaction]::InputBox('Your email for Git commits:', 'CommitOwl', '')
    if ($name)  { Invoke-Git $Repo @('config', '--global', 'user.name', $name) | Out-Null }
    if ($email) { Invoke-Git $Repo @('config', '--global', 'user.email', $email) | Out-Null }
}

function Add-OwlIgnore([string]$Repo) {
    $target = Join-Path $Repo '.gitignore'
    $template = Get-Content -LiteralPath $IgnoreTemplate -Encoding UTF8
    if (-not (Test-Path -LiteralPath $target)) {
        Copy-Item -LiteralPath $IgnoreTemplate -Destination $target
        return -1
    }
    $have = @(Get-Content -LiteralPath $target -Encoding UTF8 | ForEach-Object { $_.Trim() })
    $add = @($template | Where-Object { $_ -and -not $_.StartsWith('#') -and ($have -notcontains $_.Trim()) })
    if ($add.Count -gt 0) {
        $text = "`r`n# ---- Added by CommitOwl ----`r`n" + ($add -join "`r`n") + "`r`n"
        [IO.File]::AppendAllText($target, $text, (New-Object Text.UTF8Encoding $false))
    }
    return $add.Count
}

function Update-MsgPreview {
    $tmp = [pscustomobject]@{ commitMessage = $txtMsg.Text; listFiles = $chkList.Checked }
    $sample = @("M`tboard.kicad_sch", "M`tboard.kicad_pcb", "A`tfirmware/src/main.c")
    $txtPreview.Text = (New-OwlCommitMessage (Get-Date).ToString('yyyy-MM-dd HH:mm') $sample $tmp $false) -replace "`n", "`r`n"
    $dirty = (($txtMsg.Text.Trim()) -ne ([string]$script:Config.commitMessage).Trim()) -or ($chkList.Checked -ne [bool]$script:Config.listFiles)
    $lblMsgState.Text = $(if ($dirty) { 'Not saved yet.' } else { 'Saved. Used for every automatic and Commit & Push commit.' })
}

function Update-MsgTab {
    $txtMsg.Text = ([string]$script:Config.commitMessage) -replace "(?<!`r)`n", "`r`n"
    $chkList.Checked = [bool]$script:Config.listFiles
    Update-MsgPreview
}

# ---------------- events ----------------
$grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })

# Apply a drop-down choice as soon as it is picked
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty -and $grid.CurrentCell -is [System.Windows.Forms.DataGridViewComboBoxCell]) {
        [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})
$grid.Add_CellValueChanged({
    param($s, $e)
    if ($script:Loading -or $e.RowIndex -lt 0 -or $e.ColumnIndex -ne 1) { return }
    $row = $grid.Rows[$e.RowIndex]
    if (Set-RepoPause $row.Tag ([string]$row.Cells[1].Value)) {
        Save-OwlConfig $script:Config
    }
    $refreshTimer.Start()   # redraw the list after the drop-down closes
})

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 50
$refreshTimer.Add_Tick({
    $refreshTimer.Stop()
    [void]$grid.EndEdit()
    Update-RepoList
})

# Black text in the open drop-down list too
$grid.Add_EditingControlShowing({
    param($s, $e)
    if ($e.Control -is [System.Windows.Forms.ComboBox]) {
        $e.Control.ForeColor = [System.Drawing.Color]::Black
        $e.Control.BackColor = [System.Drawing.Color]::White
    }
})

# One click on the Auto push cell opens its drop-down
$grid.Add_CellClick({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 1) { return }
    $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[1]
    if ($grid.BeginEdit($true) -and $grid.EditingControl -is [System.Windows.Forms.ComboBox]) {
        $grid.EditingControl.DroppedDown = $true
    }
})

$grid.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -eq 1) { return }
    if ($e.ColumnIndex -eq 5) {
        $h = [string]$grid.Rows[$e.RowIndex].Cells[5].Value
        if ($h -and $h -ne '-') {
            [System.Windows.Forms.Clipboard]::SetText($h)
            $lblStatus.Text = "Copied commit $h to the clipboard."
        }
        return
    }
    $r = $grid.Rows[$e.RowIndex].Tag
    Start-Process explorer.exe -ArgumentList ('"' + $r.path + '"')
})

$btnAdd.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the repository folder (or a project folder to turn into a Git repository).'
    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    $folder = $dlg.SelectedPath
    $url = ''

    $top = Invoke-Git $folder @('rev-parse', '--show-toplevel')
    if ($top.ExitCode -eq 0) {
        $repo = (Get-GitText $top) -replace '/', '\'
    } else {
        $ans = Show-Msg "$folder is not a Git repository yet.`n`nMake it one now? CommitOwl will run 'git init' and add a .gitignore for electronics projects." 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $init = Invoke-Git $folder @('init', '-b', 'main')
        if ($init.ExitCode -ne 0) {
            $init = Invoke-Git $folder @('init')
            if ($init.ExitCode -eq 0) { Invoke-Git $folder @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null }
        }
        if ($init.ExitCode -ne 0) { Show-Msg ('git init failed: ' + (Get-GitText $init)) 'Error' | Out-Null; return }
        [void](Add-OwlIgnore $folder)
        $url = [Microsoft.VisualBasic.Interaction]::InputBox("Remote URL to push to (for example https://github.com/you/$(Split-Path -Leaf $folder).git).`n`nCreate an empty repository on GitHub/GitLab first. Leave empty to add it later.", 'CommitOwl', '')
        if ($url) { Invoke-Git $folder @('remote', 'add', 'origin', $url.Trim()) | Out-Null }
        $repo = $folder
    }

    if (@($script:Config.repos | Where-Object { $_.path -eq $repo }).Count) {
        Show-Msg 'That repository is already in the list.' | Out-Null
        return
    }
    $remotes = @((Invoke-Git $repo @('remote')).Output | Where-Object { $_ })
    $remote = $(if ($remotes -contains 'origin') { 'origin' } elseif ($remotes.Count) { $remotes[0] } else { 'origin' })
    $script:Config.repos = @($script:Config.repos) + [pscustomobject]@{ path = $repo; remote = $remote; branch = ''; enabled = $true; pausedUntil = '' }
    Save-OwlConfig $script:Config
    Test-GitIdentity $repo
    Update-RepoList
    if (-not $remotes.Count -and -not $url) {
        Show-Msg "Added. This repository has no remote yet, so commits are kept on this PC only.`n`nAdd one with your Git client, or run:  git remote add origin <url>" 'Warning' | Out-Null
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.gitignore'))) {
        if ((Show-Msg 'This repository has no .gitignore. Add one for electronics projects (KiCad, Altium, Eagle, PlatformIO, STM32)?' 'Question' 'YesNo') -eq 'Yes') {
            [void](Add-OwlIgnore $repo)
        }
    }
})

$btnRemove.Add_Click({
    $r = Get-SelectedRepo; if (-not $r) { return }
    if ((Show-Msg "Remove $($r.path) from CommitOwl?`n`nThe repository itself is not touched." 'Question' 'YesNo') -ne 'Yes') { return }
    $script:Config.repos = @($script:Config.repos | Where-Object { $_.path -ne $r.path })
    Save-OwlConfig $script:Config
    Update-RepoList
})

$btnRunOne.Add_Click({
    $r = Get-SelectedRepo; if (-not $r) { return }
    $until = Get-OwlPause $r
    if ($until) {
        $ans = Show-Msg "$(Split-Path -Leaf $r.path) is paused ($(Format-OwlPause $until)).`n`nCommit and push it now anyway? It stays paused for the daily run." 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
    }
    Start-OwlRun $r.path
})
$btnRunAll.Add_Click({
    if (-not (Get-RepoCounts)[0]) { Show-Msg 'All repositories are paused.' | Out-Null; return }
    Start-OwlRun ''
})

$btnIgnore.Add_Click({
    $r = Get-SelectedRepo; if (-not $r) { return }
    $n = Add-OwlIgnore $r.path
    if ($n -lt 0) { Show-Msg 'Added a .gitignore for electronics projects.' | Out-Null }
    elseif ($n -eq 0) { Show-Msg 'The .gitignore already has every CommitOwl rule.' | Out-Null }
    else { Show-Msg "Added $n rule(s) to the existing .gitignore.`n`nFiles Git already tracks stay tracked; untrack them with:  git rm --cached <file>" | Out-Null }
})

$btnOpen.Add_Click({ $r = Get-SelectedRepo; if ($r) { Start-Process explorer.exe -ArgumentList ('"' + $r.path + '"') } })

$txtMsg.Add_TextChanged({ Update-MsgPreview })
$chkList.Add_CheckedChanged({ Update-MsgPreview })
$btnMsgSave.Add_Click({
    $script:Config.commitMessage = ($txtMsg.Text.Trim()) -replace "`r`n", "`n"
    $script:Config.listFiles = $chkList.Checked
    Save-OwlConfig $script:Config
    Update-MsgPreview
})
$btnMsgReset.Add_Click({
    $txtMsg.Text = ''
    $chkList.Checked = $true
})

$btnSave.Add_Click({
    try { Save-Schedule }
    catch { Show-Msg ('Could not save the schedule: ' + $_.Exception.Message) 'Error' | Out-Null }
})
$btnRefresh.Add_Click({ Update-Log; Update-Schedule; Update-RepoList })
$btnLogOpen.Add_Click({
    if (Test-Path -LiteralPath $script:LogFile) { Start-Process notepad.exe -ArgumentList ('"' + $script:LogFile + '"') }
    else { Show-Msg 'No log yet.' | Out-Null }
})
$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabSched) { Update-Log; Update-Schedule } })

# ---------------- start ----------------
$form.Add_Shown({ $form.Activate() })
Convert-LegacyTask
Update-RepoList
Update-MsgTab
Update-Schedule
Update-Log
[void]$form.ShowDialog()
$timer.Dispose()
$refreshTimer.Dispose()
