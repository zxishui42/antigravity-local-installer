Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Pack = Get-Content (Join-Path $ScriptRoot 'pack.json') -Raw | ConvertFrom-Json
$RunRoot = Join-Path $env:TEMP ("aglocal-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
$StatusFile = Join-Path $RunRoot 'status.json'
$LogFile = Join-Path $RunRoot 'install.log'

function Read-Status {
    if (-not (Test-Path $StatusFile)) { return $null }
    try { return (Get-Content $StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

$fixedDrives = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Where-Object { $_.DeviceID } | Sort-Object FreeSpace -Descending)
if ($fixedDrives.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show('No writable local drive was found.','Antigravity Local') | Out-Null
    exit
}
$driveMap = @{}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Antigravity Local Installer'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(650, 565)
$form.MinimumSize = New-Object System.Drawing.Size(650, 565)
$form.BackColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Install Antigravity Local'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(34, 28)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'One installer chooses the tested setup for this PC.'
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(80,80,80)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(36, 70)
$form.Controls.Add($subtitle)

$line = New-Object System.Windows.Forms.Panel
$line.BackColor = [System.Drawing.Color]::Black
$line.Location = New-Object System.Drawing.Point(36, 105)
$line.Size = New-Object System.Drawing.Size(555, 1)
$form.Controls.Add($line)

$locationLabel = New-Object System.Windows.Forms.Label
$locationLabel.Text = 'Save files to'
$locationLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$locationLabel.AutoSize = $true
$locationLabel.Location = New-Object System.Drawing.Point(36, 129)
$form.Controls.Add($locationLabel)

$driveBox = New-Object System.Windows.Forms.ComboBox
$driveBox.DropDownStyle = 'DropDownList'
$driveBox.Location = New-Object System.Drawing.Point(40, 154)
$driveBox.Size = New-Object System.Drawing.Size(360, 30)
foreach ($d in $fixedDrives) {
    $free = [Math]::Round(([double]$d.FreeSpace / 1GB), 1)
    $display = "$($d.DeviceID)   $free GB free"
    [void]$driveBox.Items.Add($display)
    $driveMap[$display] = $d.DeviceID
}
$driveBox.SelectedIndex = 0
$form.Controls.Add($driveBox)

$locationHint = New-Object System.Windows.Forms.Label
$locationHint.Text = 'The selected local model and its required files will be kept on this drive.'
$locationHint.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
$locationHint.Size = New-Object System.Drawing.Size(550, 34)
$locationHint.Location = New-Object System.Drawing.Point(38, 189)
$form.Controls.Add($locationHint)

$statusTitle = New-Object System.Windows.Forms.Label
$statusTitle.Text = 'Ready to install'
$statusTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$statusTitle.AutoSize = $true
$statusTitle.Location = New-Object System.Drawing.Point(36, 235)
$form.Controls.Add($statusTitle)

$statusText = New-Object System.Windows.Forms.Label
$statusText.Text = 'Click Install. Everything else is handled automatically.'
$statusText.Size = New-Object System.Drawing.Size(550, 45)
$statusText.Location = New-Object System.Drawing.Point(38, 275)
$form.Controls.Add($statusText)

$details = New-Object System.Windows.Forms.Label
$details.Text = 'Existing Ollama models in other folders are left alone.'
$details.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
$details.Size = New-Object System.Drawing.Size(550, 42)
$details.Location = New-Object System.Drawing.Point(38, 318)
$form.Controls.Add($details)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(40, 375)
$progress.Size = New-Object System.Drawing.Size(545, 18)
$progress.Minimum = 0
$progress.Maximum = 100
$form.Controls.Add($progress)

$primary = New-Object System.Windows.Forms.Button
$primary.Text = 'Install'
$primary.Location = New-Object System.Drawing.Point(40, 430)
$primary.Size = New-Object System.Drawing.Size(160, 42)
$primary.FlatStyle = 'Flat'
$primary.BackColor = [System.Drawing.Color]::Black
$primary.ForeColor = [System.Drawing.Color]::White
$primary.FlatAppearance.BorderColor = [System.Drawing.Color]::Black
$form.Controls.Add($primary)

$secondary = New-Object System.Windows.Forms.Button
$secondary.Text = 'Cancel'
$secondary.Location = New-Object System.Drawing.Point(214, 430)
$secondary.Size = New-Object System.Drawing.Size(110, 42)
$secondary.FlatStyle = 'Flat'
$secondary.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($secondary)

$copy = New-Object System.Windows.Forms.Button
$copy.Text = 'Copy details'
$copy.Location = New-Object System.Drawing.Point(338, 430)
$copy.Size = New-Object System.Drawing.Size(120, 42)
$copy.FlatStyle = 'Flat'
$copy.Visible = $false
$form.Controls.Add($copy)

$openButton = New-Object System.Windows.Forms.Button
$openButton.Text = 'Test installation'
$openButton.Location = New-Object System.Drawing.Point(40, 430)
$openButton.Size = New-Object System.Drawing.Size(160, 42)
$openButton.FlatStyle = 'Flat'
$openButton.BackColor = [System.Drawing.Color]::Black
$openButton.ForeColor = [System.Drawing.Color]::White
$openButton.Visible = $false
$form.Controls.Add($openButton)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 650
$worker = $null
$installStarted = $false
$selectedRoot = $null

$primary.Add_Click({
    if ($installStarted) { return }
    $choice = [string]$driveBox.SelectedItem
    if (-not $choice -or -not $driveMap.ContainsKey($choice)) { return }
    $selectedRoot = [string]$driveMap[$choice]
    $installStarted = $true
    $driveBox.Enabled = $false
    $primary.Enabled = $false
    $secondary.Enabled = $false
    $statusTitle.Text = 'Checking this PC'
    $statusText.Text = 'This takes a few seconds.'
    $details.Text = ''
    $progress.Style = 'Marquee'
    $progress.MarqueeAnimationSpeed = 25
    $workerPath = Join-Path $ScriptRoot 'worker.ps1'
    $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$workerPath`" -ScriptRoot `"$ScriptRoot`" -RunRoot `"$RunRoot`" -TargetDrive `"$selectedRoot`""
    $worker = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
    $timer.Start()
})

$secondary.Add_Click({ $form.Close() })
$copy.Add_Click({
    if (Test-Path $LogFile) {
        [System.Windows.Forms.Clipboard]::SetText((Get-Content $LogFile -Raw))
        [System.Windows.Forms.MessageBox]::Show('Details copied.','Antigravity Local') | Out-Null
    }
})
$openButton.Add_Click({
    if (-not $selectedRoot) { return }
    $installRoot = Join-Path ($selectedRoot + '\') 'AntigravityLocal\gemma4-e2b'
    $app = Join-Path $installRoot 'AntigravityLocal.exe'
    if (-not (Test-Path $app)) {
        [System.Windows.Forms.MessageBox]::Show('The installed app was not found.','Antigravity Local') | Out-Null
        return
    }
    try {
        Start-Process -FilePath $app -WorkingDirectory $installRoot | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(('The app could not be opened.'+[Environment]::NewLine+[Environment]::NewLine+$_.Exception.Message),'Antigravity Local') | Out-Null
    }
})

$timer.Add_Tick({
    $s = Read-Status
    if ($null -eq $s) { return }
    if ($s.title) { $statusTitle.Text = [string]$s.title }
    if ($s.message) { $statusText.Text = [string]$s.message }
    if ($s.details) { $details.Text = [string]$s.details }
    if ($s.state -eq 'running') {
        if ($s.progress -ge 0 -and $s.progress -le 100) {
            $progress.Style = 'Blocks'; $progress.Value = [int]$s.progress
        } else { $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 25 }
    } elseif ($s.state -eq 'success') {
        $timer.Stop(); $progress.Style='Blocks'; $progress.Value=100
        $statusTitle.Text='Installation complete'
        $statusText.Text='Your local Antigravity setup is installed and ready.'
        $details.Text='Run the installation test once to confirm this PC can start the model and return a response. If this button does not open it, use the Antigravity Installation Test shortcut on your desktop.'
        $primary.Visible=$false; $secondary.Text='Finish'; $secondary.Enabled=$true
        $openButton.Visible=$true; $copy.Visible=$false
    } elseif ($s.state -eq 'error') {
        $timer.Stop(); $progress.Style='Blocks'; $progress.Value=0
        $primary.Text='Try again'; $primary.Enabled=$true; $primary.Visible=$true
        $secondary.Text='Close'; $secondary.Enabled=$true; $copy.Visible=$true
        $driveBox.Enabled=$true; $installStarted=$false
    }
})
$form.Add_FormClosing({
    if($installStarted -and $worker -and -not $worker.HasExited){
        $answer=[System.Windows.Forms.MessageBox]::Show('Installation is still running. Stop it?','Antigravity Local','YesNo','Question')
        if($answer -ne 'Yes'){ $_.Cancel=$true; return }
        try{$worker.Kill()}catch{}
        try{
            if($selectedRoot){
                $pidPath=Join-Path ($selectedRoot+'\') 'AntigravityLocal\gemma4-e2b\ollama-server.pid'
                if(Test-Path $pidPath){$pidValue=[int](Get-Content $pidPath);Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue}
            }
        }catch{}
    }
})
[void]$form.ShowDialog()
try { Remove-Item $RunRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
