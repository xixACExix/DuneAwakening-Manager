# DuneManager GUI.

param(
    [switch]$SmokeTest,
    [switch]$WorkerSmokeTest
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Resolve-DuneServerRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-Candidate {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
        $key = $expanded.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $candidates.Add($expanded) | Out-Null
        }
    }

    function Add-SteamRoot {
        param([string]$SteamRoot)
        if ([string]::IsNullOrWhiteSpace($SteamRoot)) { return }
        $steamRoot = [Environment]::ExpandEnvironmentVariables($SteamRoot.Trim())
        Add-Candidate (Join-Path $steamRoot 'steamapps\common\Dune Awakening Self-Hosted Server')

        $libraryFile = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $libraryFile)) { return }

        foreach ($line in Get-Content -LiteralPath $libraryFile -ErrorAction SilentlyContinue) {
            if ($line -match '"path"\s+"([^"]+)"') {
                $libraryPath = $Matches[1] -replace '\\\\', '\'
                Add-Candidate (Join-Path $libraryPath 'steamapps\common\Dune Awakening Self-Hosted Server')
            }
        }
    }

    Add-Candidate $env:DUNE_SERVER_ROOT

    foreach ($registryPath in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $steam = Get-ItemProperty -Path $registryPath -ErrorAction Stop
            Add-SteamRoot $steam.SteamPath
            Add-SteamRoot $steam.InstallPath
        } catch {
        }
    }

    Add-SteamRoot (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    Add-SteamRoot (Join-Path $env:ProgramFiles 'Steam')

    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        $root = "$($drive.Name):\"
        Add-Candidate (Join-Path $root 'SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server')
        Add-Candidate (Join-Path $root 'Steam\steamapps\common\Dune Awakening Self-Hosted Server')
        Add-Candidate (Join-Path $root 'Games\SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server')
        Add-Candidate (Join-Path $root 'Program Files (x86)\Steam\steamapps\common\Dune Awakening Self-Hosted Server')
        Add-Candidate (Join-Path $root 'Program Files\Steam\steamapps\common\Dune Awakening Self-Hosted Server')
    }

    foreach ($candidate in $candidates) {
        if (
            (Test-Path -LiteralPath $candidate) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'battlegroup-management\battlegroup.ps1'))
        ) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

$ServerRoot = Resolve-DuneServerRoot
$VmName = 'dune-awakening'
$SshKey = Join-Path $env:LOCALAPPDATA 'DuneAwakeningServer\sshKey'
$AutomationScript = Join-Path $PSScriptRoot 'DuneManager-Automation.ps1'
$LogsDir = Join-Path $PSScriptRoot 'logs'
$RunDir = Join-Path $PSScriptRoot 'run'
$BackupsDir = Join-Path $PSScriptRoot 'backups'
New-Item -ItemType Directory -Force -Path $LogsDir, $RunDir, $BackupsDir | Out-Null

$script:CurrentProcess = $null
$script:ActiveLogPath = $null
$script:ActiveLogOffset = 0
$script:ActiveWorkerScript = $null
$script:ActionButtons = New-Object System.Collections.Generic.List[System.Windows.Forms.Control]
$script:DriveMap = @{}
$script:NicMap = @{}
$script:WatchdogNextRun = [datetime]::MinValue
$script:RegionMap = @{
    'Asia' = '1'
    'Europe' = '2'
    'North America' = '3'
    'Oceania' = '4'
    'South America' = '5'
}

function Write-CrashLog {
    param([string]$Message)
    try {
        $path = Join-Path $LogsDir 'gui-crash.log'
        Add-Content -LiteralPath $path -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch {
    }
}

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $eventArgs)
    Write-CrashLog $eventArgs.Exception.ToString()
    [System.Windows.Forms.MessageBox]::Show($eventArgs.Exception.Message, 'DuneManager error') | Out-Null
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $eventArgs)
    Write-CrashLog ($eventArgs.ExceptionObject | Out-String)
})

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DuneVm {
    try {
        $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($vm) { return $vm }

        $candidates = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
            Join-Path "$($_.Name):\" 'DuneAwakeningServer'
        })
        $vms = @(Get-VM -ErrorAction SilentlyContinue)
        foreach ($candidate in $candidates) {
            if (-not (Test-Path $candidate)) { continue }
            $resolved = (Resolve-Path -LiteralPath $candidate).Path
            $match = @($vms | Where-Object { $_.ConfigurationLocation -and $_.ConfigurationLocation -like "$resolved*" })
            if ($match.Count -eq 1) { return $match[0] }
        }
        return $null
    } catch {
        $null
    }
}

function Get-DuneVmIp {
    try {
        $vm = Get-DuneVm
        if (-not $vm -or $vm.State -ne 'Running') { return $null }
        Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
            Select-Object -First 1
    } catch {
        $null
    }
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 22)
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.SetBounds($X, $Y, $W, $H)
    $label
}

function New-TextBox {
    param([int]$X, [int]$Y, [int]$W = 190, [string]$Text = '', [switch]$Password)
    $box = [System.Windows.Forms.TextBox]::new()
    $box.Text = $Text
    $box.SetBounds($X, $Y, $W, 24)
    $box.UseSystemPasswordChar = [bool]$Password
    $box
}

function New-ComboBox {
    param([int]$X, [int]$Y, [object[]]$Items, [int]$W = 100, [int]$SelectedIndex = 0)
    $combo = [System.Windows.Forms.ComboBox]::new()
    $combo.DropDownStyle = 'DropDownList'
    $combo.Items.AddRange($Items)
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = $SelectedIndex }
    $combo.SetBounds($X, $Y, $W, 24)
    $combo
}

function New-NumberBox {
    param(
        [int]$X,
        [int]$Y,
        [decimal]$Min,
        [decimal]$Max,
        [decimal]$Value,
        [decimal]$Increment = 1,
        [int]$DecimalPlaces = 0,
        [int]$W = 80
    )
    $box = [System.Windows.Forms.NumericUpDown]::new()
    $box.Minimum = $Min
    $box.Maximum = $Max
    $box.Value = $Value
    $box.Increment = $Increment
    $box.DecimalPlaces = $DecimalPlaces
    $box.SetBounds($X, $Y, $W, 24)
    $box
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 170, [int]$H = 34)
    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.SetBounds($X, $Y, $W, $H)
    $script:ActionButtons.Add($button) | Out-Null
    $button
}

function Add-LogLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    if ($script:LogBox -and $script:LogBox.InvokeRequired) {
        $null = $script:LogBox.BeginInvoke([Action[string]]{ param($text) Add-LogLine $text }, $Line)
        return
    }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $text = "[$stamp] $Line"
    if ($script:LogBox) {
        $script:LogBox.AppendText($text + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Add-RawLogText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    if ($script:LogBox -and $script:LogBox.InvokeRequired) {
        $null = $script:LogBox.BeginInvoke([Action[string]]{ param($value) Add-RawLogText $value }, $Text)
        return
    }
    if ($script:LogBox) {
        $script:LogBox.AppendText($Text)
        if (-not $Text.EndsWith([Environment]::NewLine)) {
            $script:LogBox.AppendText([Environment]::NewLine)
        }
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Set-Busy {
    param([bool]$Busy)
    foreach ($button in $script:ActionButtons) {
        $button.Enabled = -not $Busy
    }
    $script:Progress.Style = if ($Busy) { 'Marquee' } else { 'Blocks' }
    $script:Progress.MarqueeAnimationSpeed = if ($Busy) { 30 } else { 0 }
    $script:BusyLabel.Text = if ($Busy) { 'Running background task...' } else { 'Idle' }
    if (-not $Busy -and (Get-Command Update-SetupInstallState -ErrorAction SilentlyContinue)) {
        Update-SetupInstallState
    }
}

function Quote-ProcessArg {
    param([string]$Arg)
    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Poll-WorkerLog {
    if (-not $script:ActiveLogPath -or -not (Test-Path $script:ActiveLogPath)) { return }

    try {
        $text = [System.IO.File]::ReadAllText($script:ActiveLogPath, [Text.Encoding]::UTF8)
        if ($text.Length -gt $script:ActiveLogOffset) {
            $newText = $text.Substring($script:ActiveLogOffset)
            $script:ActiveLogOffset = $text.Length
            Add-RawLogText $newText
        }
    } catch {
    }
}

function Complete-WorkerIfExited {
    if (-not $script:CurrentProcess) { return }
    if (-not $script:CurrentProcess.HasExited) { return }

    Poll-WorkerLog
    $exitCode = $script:CurrentProcess.ExitCode
    Add-LogLine "Action finished with exit code $exitCode"
    $script:CurrentProcess.Dispose()
    $script:CurrentProcess = $null

    if ($script:ActiveWorkerScript -and (Test-Path $script:ActiveWorkerScript)) {
        Remove-Item -LiteralPath $script:ActiveWorkerScript -Force -ErrorAction SilentlyContinue
    }
    $script:ActiveWorkerScript = $null
    $script:ActiveLogPath = $null
    $script:ActiveLogOffset = 0

    Set-Busy $false
    Refresh-Status
}

function Stop-CurrentTask {
    if (-not $script:CurrentProcess -or $script:CurrentProcess.HasExited) {
        Add-LogLine 'No background task is running.'
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Stop the current background task?',
        'DuneManager',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        $parentId = $script:CurrentProcess.Id
        $children = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ParentProcessId -eq $parentId })
        foreach ($child in $children) {
            try { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
        try { $script:CurrentProcess.Kill() } catch {}
        Add-LogLine 'Stop requested for current background task.'
    } catch {
        Add-LogLine "ERROR: Could not stop task: $($_.Exception.Message)"
    }
}

function Start-Worker {
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$ConfigPath,
        [switch]$QuietIfBusy
    )

    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        if (-not $QuietIfBusy) {
            [System.Windows.Forms.MessageBox]::Show('A task is already running.', 'DuneManager') | Out-Null
        }
        return $false
    }

    if (-not (Test-Path $AutomationScript)) {
        if (-not $QuietIfBusy) {
            [System.Windows.Forms.MessageBox]::Show("Automation script missing: $AutomationScript", 'DuneManager') | Out-Null
        }
        return $false
    }

    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logPath = Join-Path $LogsDir ("manager-{0}-{1}.log" -f $Action, $stamp)
        $workerPath = Join-Path $RunDir ("worker-{0}-{1}.ps1" -f $Action, $stamp)
        $workerLines = @(
            '$ErrorActionPreference = ''Continue''',
            ('$action = {0}' -f (Quote-PowerShellLiteral $Action)),
            ('$automation = {0}' -f (Quote-PowerShellLiteral $AutomationScript)),
            ('$logPath = {0}' -f (Quote-PowerShellLiteral $logPath))
        )
        if ($ConfigPath) {
            $workerLines += ('$configPath = {0}' -f (Quote-PowerShellLiteral $ConfigPath))
            $workerLines += '& $automation -Action $action -ConfigPath $configPath *>&1 | ForEach-Object { $_ | Out-File -FilePath $logPath -Append -Encoding UTF8; $_ }'
        } else {
            $workerLines += '& $automation -Action $action *>&1 | ForEach-Object { $_ | Out-File -FilePath $logPath -Append -Encoding UTF8; $_ }'
        }
        $workerLines += 'exit $LASTEXITCODE'
        Set-Content -LiteralPath $workerPath -Value $workerLines -Encoding UTF8

        Set-Content -LiteralPath $logPath -Value @(
            ("[{0}] Starting action: {1}" -f (Get-Date -Format 'HH:mm:ss'), $Action),
            ("[{0}] Log file: {1}" -f (Get-Date -Format 'HH:mm:ss'), $logPath)
        ) -Encoding UTF8

        $script:ActiveLogPath = $logPath
        $script:ActiveLogOffset = 0
        $script:ActiveWorkerScript = $workerPath
        Poll-WorkerLog

        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerPath)
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = (($args | ForEach-Object { Quote-ProcessArg "$_" }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $PSScriptRoot

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi

        Set-Busy $true
        $script:CurrentProcess = $process
        $null = $process.Start()
        return $true
    } catch {
        Write-CrashLog $_.Exception.ToString()
        Add-LogLine "ERROR: $($_.Exception.Message)"
        Set-Busy $false
        if (-not $QuietIfBusy) {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'DuneManager action failed') | Out-Null
        }
        return $false
    }
}

function Populate-Drives {
    $script:DriveMap.Clear()
    $script:DriveCombo.Items.Clear()
    $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 100GB } | Sort-Object Name)
    foreach ($drive in $drives) {
        $free = [math]::Round($drive.Free / 1GB, 1)
        $text = "{0}: ({1} GB free)" -f $drive.Name, $free
        $script:DriveMap[$text] = "$($drive.Name):"
        $script:DriveCombo.Items.Add($text) | Out-Null
    }
    $preferred = $script:DriveCombo.Items | Where-Object { $_ -like 'E:*' } | Select-Object -First 1
    if ($preferred) { $script:DriveCombo.SelectedItem = $preferred }
    elseif ($script:DriveCombo.Items.Count -gt 0) { $script:DriveCombo.SelectedIndex = 0 }
}

function Populate-Nics {
    $script:NicMap.Clear()
    $script:NicCombo.Items.Clear()
    try {
        $nics = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual' } | Sort-Object Name)
        foreach ($nic in $nics) {
            $text = "{0} - {1}" -f $nic.Name, $nic.InterfaceDescription
            $script:NicMap[$text] = $nic.Name
            $script:NicCombo.Items.Add($text) | Out-Null
        }
        if ($script:NicCombo.Items.Count -gt 0) { $script:NicCombo.SelectedIndex = 0 }
    } catch {
        Add-LogLine "Could not list network adapters: $($_.Exception.Message)"
    }
}

function Refresh-Status {
    $admin = Test-IsAdmin
    $server = ($ServerRoot -and (Test-Path -LiteralPath $ServerRoot))
    $sshKey = Test-Path $SshKey
    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    $vm = Get-DuneVm
    $ip = Get-DuneVmIp

    $script:AdminValue.Text = if ($admin) { 'yes' } else { 'no' }
    $script:AdminValue.ForeColor = if ($admin) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }
    $script:ServerValue.Text = if ($server) { 'found' } else { 'missing' }
    $script:HyperVValue.Text = if ($vmms) { "$($vmms.Status)" } else { 'missing' }
    $script:VmValue.Text = if ($vm) { "$($vm.State)" } else { 'missing' }
    $script:IpValue.Text = if ($ip) { $ip } else { 'not available' }
    $script:SshValue.Text = if ($sshKey) { 'found' } else { 'missing' }

    $script:StatusSummary.Text = if (-not $admin) {
        'Relaunch through Start-DuneManager.bat for full automation.'
    } elseif (-not $server) {
        'Steam server package not found. Install it or set DUNE_SERVER_ROOT.'
    } elseif (-not $vm) {
        'Ready for first-time setup.'
    } elseif ($vm.State -ne 'Running') {
        'VM exists. Start it when ready.'
    } elseif (-not $ip) {
        'VM is running; waiting for network.'
    } elseif (-not $sshKey) {
        'VM is running, but SSH key is missing.'
    } else {
        'Ready.'
    }

    Update-SetupInstallState
}

function Update-StaticFields {
    $static = ($script:IpModeCombo.SelectedItem -eq 'Static')
    foreach ($control in @($script:StaticIpText, $script:StaticGatewayText, $script:StaticCidrText, $script:StaticDnsText)) {
        $control.Enabled = $static
    }
    $script:ManualPlayerIpText.Enabled = ($script:PlayerIpCombo.SelectedItem -eq 'Manual')
}

function Select-InstallDrive {
    param([string]$Drive)

    if (-not $Drive -or -not $script:DriveCombo) { return }
    foreach ($item in $script:DriveCombo.Items) {
        $text = [string]$item
        if ($text -like "$Drive*") {
            $script:DriveCombo.SelectedItem = $item
            return
        }
    }
}

function Update-SetupInstallState {
    if (-not $script:SetupStateLabel -or -not $script:SetupStartButton) { return }

    $vm = Get-DuneVm
    $ip = Get-DuneVmIp
    $installed = ($null -ne $vm)
    $replaceMode = ($script:ReplaceVmCheck -and $script:ReplaceVmCheck.Checked)

    if ($installed -and -not $replaceMode) {
        if ($vm.ConfigurationLocation -match '^([A-Z]:)\\') {
            Select-InstallDrive -Drive $Matches[1]
        }
        try {
            $memoryGB = [int][math]::Round([double]$vm.MemoryStartup / 1GB)
            if ($memoryGB -ge $script:MemoryNumeric.Minimum -and $memoryGB -le $script:MemoryNumeric.Maximum) {
                $script:MemoryNumeric.Value = $memoryGB
            }
        } catch {
        }
    }

    if (-not $installed) {
        $script:SetupStateLabel.Text = "No Dune VM install was detected.`r`nUse this tab for a fresh first-time setup."
        $script:SetupStateLabel.ForeColor = [Drawing.Color]::DarkGreen
        $script:SetupStartButton.Text = 'Run Automated Setup'
        $script:SetupStartButton.Enabled = -not ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited)
        return
    }

    $location = if ($vm.ConfigurationLocation) { $vm.ConfigurationLocation } else { 'unknown location' }
    $memory = try { "{0} GB" -f ([int][math]::Round([double]$vm.MemoryStartup / 1GB)) } catch { 'unknown memory' }
    $world = if ($script:WorldTitleText -and -not [string]::IsNullOrWhiteSpace($script:WorldTitleText.Text)) { $script:WorldTitleText.Text } else { 'not loaded yet' }
    $sietch = if ($script:ServerDisplayNameText -and -not [string]::IsNullOrWhiteSpace($script:ServerDisplayNameText.Text)) { $script:ServerDisplayNameText.Text } else { 'default or not loaded' }
    $passwordState = if ($script:PasswordModeCombo -and [string]$script:PasswordModeCombo.SelectedItem -eq 'Set') { 'set' } else { 'not set or not loaded' }
    $pvpState = if ($script:PvpModeCombo -and [string]$script:PvpModeCombo.SelectedItem) { [string]$script:PvpModeCombo.SelectedItem } else { 'not loaded' }
    $ipText = if ($ip) { $ip } else { 'VM not running' }

    if ($replaceMode) {
        $script:SetupStateLabel.Text = "Reinstall mode is enabled.`r`nExisting VM: $($vm.State), $memory, $ipText.`r`nThis will replace the VM at $location."
        $script:SetupStateLabel.ForeColor = [Drawing.Color]::Firebrick
        $script:SetupStartButton.Text = 'Reinstall / Replace Server'
        $script:SetupStartButton.Enabled = -not ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited)
    } else {
        $script:SetupStateLabel.Text = "Installed server detected: $($vm.State), $memory, $ipText.`r`nWorld: $world | Sietch: $sietch`r`nPassword: $passwordState | PvP: $pvpState. Setup is locked unless replace is checked."
        $script:SetupStateLabel.ForeColor = [Drawing.Color]::DarkBlue
        $script:SetupStartButton.Text = 'Setup Locked: Existing Server'
        $script:SetupStartButton.Enabled = $false
    }
}

function Build-SetupConfig {
    $existingVm = Get-DuneVm
    if ($existingVm -and -not $script:ReplaceVmCheck.Checked) {
        throw "An existing Dune server VM is already installed. Check 'Replace existing VM' only if you want to reinstall it."
    }

    $driveText = [string]$script:DriveCombo.SelectedItem
    if (-not $driveText -or -not $script:DriveMap.ContainsKey($driveText)) {
        throw 'Choose an install drive.'
    }

    $currentPassword = $script:CurrentPasswordText.Text
    if ([string]::IsNullOrWhiteSpace($currentPassword)) {
        throw 'Enter the current VM password. For a fresh install this is usually dune.'
    }

    $serverToken = $script:ServerTokenText.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($serverToken)) {
        throw 'Enter your Dune self-hosted server token.'
    }

    $newPassword = $script:NewPasswordText.Text
    if ($newPassword -ne $script:ConfirmPasswordText.Text) {
        throw 'New password and confirmation do not match.'
    }

    if ($script:IpModeCombo.SelectedItem -eq 'Static') {
        foreach ($pair in @(
            @('Static IP', $script:StaticIpText.Text),
            @('Static gateway', $script:StaticGatewayText.Text)
        )) {
            if ($pair[1] -notmatch '^\d+\.\d+\.\d+\.\d+$') {
                throw "$($pair[0]) is not a valid IPv4 address."
            }
        }
    }

    if ($script:PlayerIpCombo.SelectedItem -eq 'Manual' -and [string]::IsNullOrWhiteSpace($script:ManualPlayerIpText.Text)) {
        throw 'Enter the manual player connection IP, or switch player IP mode.'
    }

    $nicName = $null
    if ($script:UseExternalSwitchCheck.Checked -and $script:NicCombo.SelectedItem) {
        $nicName = $script:NicMap[[string]$script:NicCombo.SelectedItem]
    }

    [pscustomobject]@{
        InstallDrive = $script:DriveMap[$driveText]
        MemoryGB = [int]$script:MemoryNumeric.Value
        UseExternalSwitch = [bool]$script:UseExternalSwitchCheck.Checked
        NetworkAdapterName = $nicName
        ReplaceExistingVm = [bool]$script:ReplaceVmCheck.Checked
        ContinueOnCompatibilityWarnings = [bool]$script:CompatibilityWarningsCheck.Checked
        CurrentVmPassword = $currentPassword
        ServerToken = $serverToken
        WorldName = 'Dune Server'
        Region = $script:RegionMap[[string]$script:SetupRegionCombo.SelectedItem]
        NewVmPassword = $newPassword
        IpMode = [string]$script:IpModeCombo.SelectedItem
        StaticIp = $script:StaticIpText.Text
        StaticCidr = $script:StaticCidrText.Text
        StaticGateway = $script:StaticGatewayText.Text
        StaticDns = $script:StaticDnsText.Text
        PlayerIpMode = [string]$script:PlayerIpCombo.SelectedItem
        ManualPlayerIp = $script:ManualPlayerIpText.Text
        EnableSwapWhenLowMemory = [bool]$script:SwapCheck.Checked
        StartBattlegroupAfterSetup = [bool]$script:StartAfterSetupCheck.Checked
    }
}

function Start-InitialSetupFromUi {
    try {
        if (-not $ServerRoot -or -not (Test-Path -LiteralPath $ServerRoot)) {
            throw 'Could not find the Dune Awakening Self-Hosted Server Steam package. Install it through Steam Tools or set DUNE_SERVER_ROOT before launching DuneManager.'
        }

        $config = Build-SetupConfig
        if ($config.UseExternalSwitch) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                'Creating an external Hyper-V switch can briefly interrupt network connectivity. Continue?',
                'DuneManager setup',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if ($config.ReplaceExistingVm) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Replace existing VM '$VmName' if present? This removes that Hyper-V VM and the DuneAwakeningServer destination folder on the selected drive.",
                'DuneManager setup',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $configPath = Join-Path $RunDir ("setup-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
        Start-Worker -Action 'InitialSetup' -ConfigPath $configPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Setup validation') | Out-Null
    }
}

function Open-VmShell {
    $ip = Get-DuneVmIp
    if (-not $ip) {
        [System.Windows.Forms.MessageBox]::Show('VM is not running or has no IP address.', 'DuneManager') | Out-Null
        return
    }
    if (-not (Test-Path $SshKey)) {
        [System.Windows.Forms.MessageBox]::Show("SSH key is missing: $SshKey", 'DuneManager') | Out-Null
        return
    }
    $cmd = "ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i `"$SshKey`" dune@$ip"
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-Command', $cmd)
}

function Invoke-DuneSshScript {
    param([Parameter(Mandatory)][string]$RemoteScript)

    $ip = Get-DuneVmIp
    if (-not $ip) {
        throw 'VM is not running or has no IP address.'
    }
    if (-not (Test-Path $SshKey)) {
        throw "SSH key is missing: $SshKey"
    }

    $remoteScriptLf = $RemoteScript -replace "`r`n", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScriptLf))
    $output = & ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -i $SshKey "dune@$ip" "echo $encoded | base64 -d | bash" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SSH read failed. $($output | Out-String)"
    }
    return @($output)
}

function Decode-Base64Utf8 {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
    } catch {
        return ''
    }
}

function Select-ComboValue {
    param(
        [Parameter(Mandatory)]$Combo,
        [string]$Value,
        [string]$Fallback = 'Keep'
    )

    if ($Combo.Items.Contains($Value)) {
        $Combo.SelectedItem = $Value
    } elseif ($Combo.Items.Contains($Fallback)) {
        $Combo.SelectedItem = $Fallback
    }
}

function Select-ModeFromValue {
    param(
        [Parameter(Mandatory)]$Combo,
        [string]$Value,
        [switch]$Numeric
    )

    $normalized = "$Value".Trim()
    $mode = 'Keep'
    if ($Numeric) {
        if ($normalized -eq '1') { $mode = 'On' }
        elseif ($normalized -eq '0') { $mode = 'Off' }
    } else {
        if ($normalized -match '^(?i:true)$') { $mode = 'On' }
        elseif ($normalized -match '^(?i:false)$') { $mode = 'Off' }
    }
    Select-ComboValue -Combo $Combo -Value $mode
}

function Set-NumberBoxValue {
    param(
        [Parameter(Mandatory)]$Box,
        [string]$Value
    )

    if ("$Value" -notmatch '^-?\d+(\.\d+)?$') { return }
    $loaded = [decimal]$Value
    if ($loaded -lt $Box.Minimum) { $loaded = $Box.Minimum }
    if ($loaded -gt $Box.Maximum) { $loaded = $Box.Maximum }
    $Box.Value = $loaded
}

function Load-ServerSettingsFromUi {
    param([switch]$Quiet)

    try {
        Add-LogLine $(if ($Quiet) { 'Auto-loading current server settings...' } else { 'Loading current server settings...' })
        $remote = @'
set -e
engine='/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
game='/home/dune/.dune/download/scripts/setup/config/UserGame.ini'

extract_ini_value() {
  file="$1"
  section="$2"
  key="$3"
  awk -v section="$section" -v key="$key" '
    function clean_key(s) {
      sub(/=.*/, "", s)
      gsub(/^[ \t;]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN { in_section=0; value=""; header="[" section "]" }
    $0 == header { in_section=1; next }
    /^\[/ { in_section=0 }
    in_section && clean_key($0) == key {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[ \t]+/, "", value)
      gsub(/[ \t]+$/, "", value)
      if (value ~ /^".*"$/) {
        sub(/^"/, "", value)
        sub(/"$/, "", value)
      }
    }
    END { print value }
  ' "$file"
}

emit_b64() {
  key="$1"
  value="$2"
  encoded=$(printf '%s' "$value" | base64 | tr -d '\n')
  printf '%s=%s\n' "$key" "$encoded"
}

ns=$(sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name | grep '^funcom-seabass-' | head -n1 || true)
title=''
if [ -n "$ns" ]; then
  bg=${ns#funcom-seabass-}
  title=$(sudo kubectl get battlegroup "$bg" -n "$ns" -o jsonpath='{.spec.title}' 2>/dev/null || true)
fi

emit_b64 WORLD_TITLE "$title"
emit_b64 DISPLAY_NAME "$(extract_ini_value "$engine" "ConsoleVariables" "Bgd.ServerDisplayName")"
emit_b64 JOIN_PASSWORD "$(extract_ini_value "$engine" "ConsoleVariables" "Bgd.ServerLoginPassword")"
emit_b64 PVP_ALL "$(extract_ini_value "$game" "/Script/DuneSandbox.PvpPveSettings" "m_bShouldForceEnablePvpOnAllPartitions")"
emit_b64 SECURITY_ZONES "$(extract_ini_value "$game" "/Script/DuneSandbox.SecurityZonesSubsystem" "m_bAreSecurityZonesEnabled")"
emit_b64 MINING_MULTIPLIER "$(extract_ini_value "$engine" "ConsoleVariables" "Dune.GlobalMiningOutputMultiplier")"
emit_b64 PVP_RESOURCE_MULTIPLIER "$(extract_ini_value "$engine" "ConsoleVariables" "SecurityZones.PvpResourceMultiplier")"
emit_b64 VEHICLE_DURABILITY_MULTIPLIER "$(extract_ini_value "$engine" "ConsoleVariables" "dw.VehicleDurabilityDamageMultiplier")"
emit_b64 SANDSTORM "$(extract_ini_value "$engine" "ConsoleVariables" "Sandstorm.Enabled")"
emit_b64 SANDSTORM_TREASURE "$(extract_ini_value "$engine" "ConsoleVariables" "Sandstorm.Treasure.Enabled")"
emit_b64 SANDWORM "$(extract_ini_value "$engine" "ConsoleVariables" "sandworm.dune.Enabled")"
emit_b64 SANDWORM_VEHICLE_COLLISION "$(extract_ini_value "$engine" "ConsoleVariables" "Vehicle.SandwormCollisionInteraction")"
emit_b64 SANDWORM_DANGER_ZONES "$(extract_ini_value "$engine" "ConsoleVariables" "Sandworm.SandwormDangerZonesEnabled")"
emit_b64 SANDWORM_EXIT_INVULN "$(extract_ini_value "$engine" "ConsoleVariables" "Vehicle.SandwormInvulnerabilitySecondsOnExit")"
emit_b64 SANDWORM_RESTART_INVULN "$(extract_ini_value "$engine" "ConsoleVariables" "Vehicle.SandwormInvulnerabilitySecondsOnServerRestart")"
emit_b64 DETERIORATION_RATE "$(extract_ini_value "$game" "/DeteriorationSystem.ItemDeteriorationConstants" "UpdateRateInSeconds")"
emit_b64 CORIOLIS "$(extract_ini_value "$game" "/Script/DuneSandbox.SandStormConfig" "m_bCoriolisAutoSpawnEnabled")"
emit_b64 MAX_LANDCLAIMS "$(extract_ini_value "$game" "/Script/DuneSandbox.BuildingSettings" "m_MaxNumLandclaimSegments")"
emit_b64 BLUEPRINT_EXTENSIONS "$(extract_ini_value "$game" "/Script/DuneSandbox.BuildingSettings" "m_BuildingBlueprintMaxExtensions")"
emit_b64 BASE_BACKUP_EXTENSIONS "$(extract_ini_value "$game" "/Script/DuneSandbox.BuildingSettings" "m_BaseBackupMaxExtensions")"
emit_b64 BUILDING_RESTRICTIONS "$(extract_ini_value "$game" "/Script/DuneSandbox.BuildingSettings" "m_bBuildingRestrictionLimitsEnabled")"
'@
        $output = Invoke-DuneSshScript -RemoteScript $remote
        $values = @{}
        foreach ($line in $output) {
            if ("$line" -match '^([A-Z_]+)=(.*)$') {
                $values[$Matches[1]] = Decode-Base64Utf8 $Matches[2]
            }
        }

        $script:WorldTitleText.Text = $values['WORLD_TITLE']
        $script:ServerDisplayNameText.Text = $values['DISPLAY_NAME']
        $script:JoinPasswordText.Text = $values['JOIN_PASSWORD']
        $passwordMode = if ([string]::IsNullOrWhiteSpace($values['JOIN_PASSWORD'])) { 'Keep' } else { 'Set' }
        $pvpMode = if ($values['PVP_ALL'] -eq 'True') { 'On' } elseif ($values['PVP_ALL'] -eq 'False') { 'Off' } else { 'Keep' }
        $securityZoneMode = if ($values['SECURITY_ZONES'] -eq 'True') { 'On' } elseif ($values['SECURITY_ZONES'] -eq 'False') { 'Off' } else { 'Keep' }
        Select-ComboValue -Combo $script:PasswordModeCombo -Value $passwordMode
        Select-ComboValue -Combo $script:PvpModeCombo -Value $pvpMode
        Select-ComboValue -Combo $script:SecurityZoneModeCombo -Value $securityZoneMode
        Set-NumberBoxValue -Box $script:MiningMultiplierNumeric -Value $values['MINING_MULTIPLIER']
        Set-NumberBoxValue -Box $script:PvpResourceMultiplierNumeric -Value $values['PVP_RESOURCE_MULTIPLIER']
        Set-NumberBoxValue -Box $script:VehicleDurabilityNumeric -Value $values['VEHICLE_DURABILITY_MULTIPLIER']
        Set-NumberBoxValue -Box $script:DeteriorationRateNumeric -Value $values['DETERIORATION_RATE']
        Set-NumberBoxValue -Box $script:LandclaimSegmentsNumeric -Value $values['MAX_LANDCLAIMS']
        Set-NumberBoxValue -Box $script:BlueprintExtensionsNumeric -Value $values['BLUEPRINT_EXTENSIONS']
        Set-NumberBoxValue -Box $script:BaseBackupExtensionsNumeric -Value $values['BASE_BACKUP_EXTENSIONS']
        Set-NumberBoxValue -Box $script:SandwormExitInvulnNumeric -Value $values['SANDWORM_EXIT_INVULN']
        Set-NumberBoxValue -Box $script:SandwormRestartInvulnNumeric -Value $values['SANDWORM_RESTART_INVULN']
        Select-ModeFromValue -Combo $script:SandstormModeCombo -Value $values['SANDSTORM'] -Numeric
        Select-ModeFromValue -Combo $script:SandstormTreasureModeCombo -Value $values['SANDSTORM_TREASURE'] -Numeric
        Select-ModeFromValue -Combo $script:SandwormModeCombo -Value $values['SANDWORM'] -Numeric
        Select-ModeFromValue -Combo $script:SandwormVehicleCollisionModeCombo -Value $values['SANDWORM_VEHICLE_COLLISION']
        Select-ModeFromValue -Combo $script:SandwormDangerZonesModeCombo -Value $values['SANDWORM_DANGER_ZONES']
        Select-ModeFromValue -Combo $script:CoriolisModeCombo -Value $values['CORIOLIS']
        Select-ModeFromValue -Combo $script:BuildingRestrictionModeCombo -Value $values['BUILDING_RESTRICTIONS']
        Update-SetupInstallState
        Add-LogLine 'Current server settings loaded.'
    } catch {
        Add-LogLine "ERROR: $($_.Exception.Message)"
        if (-not $Quiet) {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Load settings') | Out-Null
        }
    }
}

function Start-SettingsAutoLoad {
    if (-not (Get-DuneVmIp) -or -not (Test-Path $SshKey)) {
        Add-LogLine 'Settings auto-load skipped; start the VM first if you want current server values.'
        return
    }
    Load-ServerSettingsFromUi -Quiet
}

function Build-SettingsConfig {
    $passwordMode = [string]$script:PasswordModeCombo.SelectedItem
    if (-not $passwordMode) { $passwordMode = 'Keep' }
    if ($passwordMode -eq 'Set' -and [string]::IsNullOrWhiteSpace($script:JoinPasswordText.Text)) {
        throw 'Enter a join password, or switch password mode to Keep or Clear.'
    }

    [pscustomobject]@{
        WorldTitle = $script:WorldTitleText.Text
        ServerDisplayName = $script:ServerDisplayNameText.Text
        PasswordMode = $passwordMode
        JoinPassword = $script:JoinPasswordText.Text
        PvpMode = [string]$script:PvpModeCombo.SelectedItem
        SecurityZoneMode = [string]$script:SecurityZoneModeCombo.SelectedItem
        SetMiningMultiplier = [bool]$script:MiningMultiplierCheck.Checked
        MiningMultiplier = $script:MiningMultiplierNumeric.Value.ToString([Globalization.CultureInfo]::InvariantCulture)
        SetPvpResourceMultiplier = [bool]$script:PvpResourceMultiplierCheck.Checked
        PvpResourceMultiplier = $script:PvpResourceMultiplierNumeric.Value.ToString([Globalization.CultureInfo]::InvariantCulture)
        SetVehicleDurabilityMultiplier = [bool]$script:VehicleDurabilityCheck.Checked
        VehicleDurabilityMultiplier = $script:VehicleDurabilityNumeric.Value.ToString([Globalization.CultureInfo]::InvariantCulture)
        SetDeteriorationRate = [bool]$script:DeteriorationRateCheck.Checked
        DeteriorationRate = $script:DeteriorationRateNumeric.Value.ToString([Globalization.CultureInfo]::InvariantCulture)
        SandstormMode = [string]$script:SandstormModeCombo.SelectedItem
        SandstormTreasureMode = [string]$script:SandstormTreasureModeCombo.SelectedItem
        CoriolisMode = [string]$script:CoriolisModeCombo.SelectedItem
        SandwormMode = [string]$script:SandwormModeCombo.SelectedItem
        SandwormVehicleCollisionMode = [string]$script:SandwormVehicleCollisionModeCombo.SelectedItem
        SandwormDangerZonesMode = [string]$script:SandwormDangerZonesModeCombo.SelectedItem
        SetSandwormInvulnerability = [bool]$script:SandwormInvulnCheck.Checked
        SandwormExitInvulnerabilitySeconds = $script:SandwormExitInvulnNumeric.Value.ToString([Globalization.CultureInfo]::InvariantCulture)
        SandwormRestartInvulnerabilitySeconds = $script:SandwormRestartInvulnNumeric.Value.ToString([Globalization.CultureInfo]::InvariantCulture)
        BuildingRestrictionMode = [string]$script:BuildingRestrictionModeCombo.SelectedItem
        SetBuildingLimits = [bool]$script:BuildingLimitsCheck.Checked
        LandclaimSegments = [int]$script:LandclaimSegmentsNumeric.Value
        BlueprintExtensions = [int]$script:BlueprintExtensionsNumeric.Value
        BaseBackupExtensions = [int]$script:BaseBackupExtensionsNumeric.Value
        RestartAfterApply = [bool]$script:RestartAfterSettingsCheck.Checked
    }
}

function Start-ApplySettingsFromUi {
    try {
        $config = Build-SettingsConfig
        if ($config.RestartAfterApply) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                'This will restart the battlegroup after applying settings. Continue?',
                'Apply server settings',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $configPath = Join-Path $RunDir ("settings-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
        Start-Worker -Action 'ApplySettings' -ConfigPath $configPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Settings validation') | Out-Null
    }
}

function Start-RestoreBackupFromUi {
    try {
        New-Item -ItemType Directory -Force -Path $BackupsDir | Out-Null

        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = 'Select DuneManager backup archive'
        $dialog.InitialDirectory = $BackupsDir
        $dialog.Filter = 'DuneManager backup (*.tar.gz)|*.tar.gz|All files (*.*)|*.*'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false

        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Restore this local backup?`r`n`r`n$($dialog.FileName)`r`n`r`nThis stops the battlegroup, imports the database backup, restores manager-edited ini settings when available, and starts the battlegroup again.",
            'Restore server backup',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $configPath = Join-Path $RunDir ("restore-{0}.json" -f [guid]::NewGuid().ToString('N'))
        [pscustomobject]@{
            BackupArchive = $dialog.FileName
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configPath -Encoding UTF8

        Start-Worker -Action 'RestoreBackup' -ConfigPath $configPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Restore backup') | Out-Null
    }
}

function Build-WatchdogConfig {
    param(
        [bool]$AutoRepair,
        [bool]$KeepRunning
    )

    [pscustomobject]@{
        AutoRepair = $AutoRepair
        KeepRunning = $KeepRunning
    }
}

function Start-HealthCheckFromUi {
    param(
        [switch]$FromWatchdog,
        [switch]$RepairNow
    )

    try {
        $autoRepair = if ($RepairNow) { $true } elseif ($script:WatchdogAutoRepairCheck) { [bool]$script:WatchdogAutoRepairCheck.Checked } else { $false }
        $keepRunning = if ($RepairNow) { $true } elseif ($script:WatchdogKeepRunningCheck) { [bool]$script:WatchdogKeepRunningCheck.Checked } else { $false }
        $config = Build-WatchdogConfig -AutoRepair $autoRepair -KeepRunning $keepRunning
        $configPath = Join-Path $RunDir ("watchdog-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

        $started = Start-Worker -Action 'HealthCheck' -ConfigPath $configPath -QuietIfBusy:$FromWatchdog
        if ($started -and $script:WatchdogLastLabel) {
            $script:WatchdogLastLabel.Text = "Last check: $(Get-Date -Format 'HH:mm:ss')"
        }
        if (-not $started) {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        if (-not $FromWatchdog) {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Health check') | Out-Null
        } else {
            Add-LogLine "Watchdog error: $($_.Exception.Message)"
        }
    }
}

function Invoke-WatchdogTimer {
    if (-not $script:WatchdogEnableCheck -or -not $script:WatchdogEnableCheck.Checked) { return }
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) { return }

    $now = Get-Date
    if (-not $script:WatchdogNextRun -or $script:WatchdogNextRun -le [datetime]::MinValue) {
        $script:WatchdogNextRun = $now
    }
    if ($now -lt $script:WatchdogNextRun) { return }

    Start-HealthCheckFromUi -FromWatchdog
    $seconds = if ($script:WatchdogIntervalNumeric) { [int]$script:WatchdogIntervalNumeric.Value } else { 60 }
    $script:WatchdogNextRun = $now.AddSeconds($seconds)
}

function Show-LicenseMessage {
    $message = @'
DuneManager usage note

You may use, copy, modify, and share this manager for personal, private, or community Dune Awakening self-hosted server management.

Do not sell it, bundle it as paid software, or present it as an official Funcom tool. Dune Awakening and related names belong to their owners.

This tool changes local Hyper-V and server files at your direction. Keep backups before updates, imports, or reinstalls.

Signed,
Ace
'@
    [System.Windows.Forms.MessageBox]::Show($message, 'DuneManager License / Use') | Out-Null
}

function Update-SettingsFields {
    $script:MiningMultiplierNumeric.Enabled = [bool]$script:MiningMultiplierCheck.Checked
    $script:PvpResourceMultiplierNumeric.Enabled = [bool]$script:PvpResourceMultiplierCheck.Checked
    $script:VehicleDurabilityNumeric.Enabled = [bool]$script:VehicleDurabilityCheck.Checked
    $script:DeteriorationRateNumeric.Enabled = [bool]$script:DeteriorationRateCheck.Checked
    foreach ($control in @($script:SandwormExitInvulnNumeric, $script:SandwormRestartInvulnNumeric)) {
        $control.Enabled = [bool]$script:SandwormInvulnCheck.Checked
    }
    foreach ($control in @($script:LandclaimSegmentsNumeric, $script:BlueprintExtensionsNumeric, $script:BaseBackupExtensionsNumeric)) {
        $control.Enabled = [bool]$script:BuildingLimitsCheck.Checked
    }
    $script:JoinPasswordText.Enabled = ([string]$script:PasswordModeCombo.SelectedItem -eq 'Set')
}

$script:Form = [System.Windows.Forms.Form]::new()
$script:Form.Text = 'DuneManager by Ace'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Size = [Drawing.Size]::new(1120, 780)
$script:Form.MinimumSize = [Drawing.Size]::new(980, 680)

$statusGroup = [System.Windows.Forms.GroupBox]::new()
$statusGroup.Text = 'Status'
$statusGroup.SetBounds(12, 10, 1080, 118)
$statusGroup.Anchor = 'Top,Left,Right'
$script:Form.Controls.Add($statusGroup)

$statusGroup.Controls.Add((New-Label 'Admin' 18 28 70))
$script:AdminValue = New-Label '-' 90 28 130
$statusGroup.Controls.Add($script:AdminValue)
$statusGroup.Controls.Add((New-Label 'Server' 230 28 70))
$script:ServerValue = New-Label '-' 302 28 120
$statusGroup.Controls.Add($script:ServerValue)
$statusGroup.Controls.Add((New-Label 'Hyper-V' 430 28 70))
$script:HyperVValue = New-Label '-' 505 28 120
$statusGroup.Controls.Add($script:HyperVValue)
$statusGroup.Controls.Add((New-Label 'VM' 635 28 40))
$script:VmValue = New-Label '-' 680 28 110
$statusGroup.Controls.Add($script:VmValue)
$statusGroup.Controls.Add((New-Label 'IP' 800 28 30))
$script:IpValue = New-Label '-' 835 28 130
$statusGroup.Controls.Add($script:IpValue)
$statusGroup.Controls.Add((New-Label 'SSH' 975 28 35))
$script:SshValue = New-Label '-' 1012 28 60
$statusGroup.Controls.Add($script:SshValue)

$script:StatusSummary = New-Label '-' 18 64 520
$statusGroup.Controls.Add($script:StatusSummary)
$refreshButton = New-Button 'Refresh' 900 62 80 30
$refreshButton.Add_Click({ Refresh-Status })
$statusGroup.Controls.Add($refreshButton)
$openServerButton = New-Button 'Server Folder' 990 62 82 30
$openServerButton.Add_Click({
    if ($ServerRoot -and (Test-Path -LiteralPath $ServerRoot)) {
        Start-Process $ServerRoot
    } else {
        [System.Windows.Forms.MessageBox]::Show('Steam server package not found. Install it through Steam Tools or set DUNE_SERVER_ROOT before launching DuneManager.', 'DuneManager') | Out-Null
    }
})
$statusGroup.Controls.Add($openServerButton)

$split = [System.Windows.Forms.SplitContainer]::new()
$split.SetBounds(12, 138, 1080, 590)
$split.Anchor = 'Top,Bottom,Left,Right'
$split.SplitterDistance = 450
$split.FixedPanel = 'Panel1'
$script:Form.Controls.Add($split)

$tabs = [System.Windows.Forms.TabControl]::new()
$tabs.Dock = 'Fill'
$split.Panel1.Controls.Add($tabs)

$setupTab = [System.Windows.Forms.TabPage]::new()
$setupTab.Text = 'First-Time Setup'
$setupTab.AutoScroll = $true
$tabs.TabPages.Add($setupTab)

$actionsTab = [System.Windows.Forms.TabPage]::new()
$actionsTab.Text = 'Actions'
$actionsTab.AutoScroll = $true
$tabs.TabPages.Add($actionsTab)

$settingsTab = [System.Windows.Forms.TabPage]::new()
$settingsTab.Text = 'Settings'
$settingsTab.AutoScroll = $true
$tabs.TabPages.Add($settingsTab)

$script:SetupStateGroup = [System.Windows.Forms.GroupBox]::new()
$script:SetupStateGroup.Text = 'Detected Install'
$script:SetupStateGroup.SetBounds(16, 12, 400, 100)
$setupTab.Controls.Add($script:SetupStateGroup)
$script:SetupStateLabel = New-Label 'Checking install state...' 14 22 370 64
$script:SetupStateLabel.ForeColor = [Drawing.Color]::DarkBlue
$script:SetupStateGroup.Controls.Add($script:SetupStateLabel)

$setupTab.Controls.Add((New-Label 'Install drive' 16 20 130))
$script:DriveCombo = [System.Windows.Forms.ComboBox]::new()
$script:DriveCombo.DropDownStyle = 'DropDownList'
$script:DriveCombo.SetBounds(160, 18, 245, 24)
$setupTab.Controls.Add($script:DriveCombo)

$setupTab.Controls.Add((New-Label 'Memory GB' 16 54 130))
$script:MemoryNumeric = [System.Windows.Forms.NumericUpDown]::new()
$script:MemoryNumeric.Minimum = 10
$script:MemoryNumeric.Maximum = 128
$script:MemoryNumeric.Value = 20
$script:MemoryNumeric.SetBounds(160, 52, 80, 24)
$setupTab.Controls.Add($script:MemoryNumeric)

$script:UseExternalSwitchCheck = [System.Windows.Forms.CheckBox]::new()
$script:UseExternalSwitchCheck.Text = 'Use external switch'
$script:UseExternalSwitchCheck.Checked = $true
$script:UseExternalSwitchCheck.SetBounds(16, 88, 150, 24)
$setupTab.Controls.Add($script:UseExternalSwitchCheck)

$script:NicCombo = [System.Windows.Forms.ComboBox]::new()
$script:NicCombo.DropDownStyle = 'DropDownList'
$script:NicCombo.SetBounds(160, 88, 245, 24)
$setupTab.Controls.Add($script:NicCombo)

$setupTab.Controls.Add((New-Label 'Current VM password' 16 126 140))
$script:CurrentPasswordText = New-TextBox 160 124 245 'dune' -Password
$setupTab.Controls.Add($script:CurrentPasswordText)

$setupTab.Controls.Add((New-Label 'Server token' 16 160 140))
$script:ServerTokenText = New-TextBox 160 158 245 '' -Password
$setupTab.Controls.Add($script:ServerTokenText)

$setupRegionLabel = New-Label 'Region' 16 194 140
$setupRegionLabel.Tag = 'InsertRegion'
$setupTab.Controls.Add($setupRegionLabel)
$script:SetupRegionCombo = [System.Windows.Forms.ComboBox]::new()
$script:SetupRegionCombo.DropDownStyle = 'DropDownList'
$script:SetupRegionCombo.Items.AddRange(@('Asia', 'Europe', 'North America', 'Oceania', 'South America'))
$script:SetupRegionCombo.SelectedItem = 'Europe'
$script:SetupRegionCombo.SetBounds(160, 192, 160, 24)
$script:SetupRegionCombo.Tag = 'InsertRegion'
$setupTab.Controls.Add($script:SetupRegionCombo)

$setupTab.Controls.Add((New-Label 'New VM password' 16 194 140))
$script:NewPasswordText = New-TextBox 160 192 245 '' -Password
$setupTab.Controls.Add($script:NewPasswordText)

$setupTab.Controls.Add((New-Label 'Confirm password' 16 228 140))
$script:ConfirmPasswordText = New-TextBox 160 226 245 '' -Password
$setupTab.Controls.Add($script:ConfirmPasswordText)

$setupTab.Controls.Add((New-Label 'IP mode' 16 266 130))
$script:IpModeCombo = [System.Windows.Forms.ComboBox]::new()
$script:IpModeCombo.DropDownStyle = 'DropDownList'
$script:IpModeCombo.Items.AddRange(@('DHCP', 'Static'))
$script:IpModeCombo.SelectedIndex = 0
$script:IpModeCombo.SetBounds(160, 264, 120, 24)
$setupTab.Controls.Add($script:IpModeCombo)

$setupTab.Controls.Add((New-Label 'Static IP' 16 300 130))
$script:StaticIpText = New-TextBox 160 298 120
$setupTab.Controls.Add($script:StaticIpText)
$setupTab.Controls.Add((New-Label 'Gateway' 16 334 130))
$script:StaticGatewayText = New-TextBox 160 332 120
$setupTab.Controls.Add($script:StaticGatewayText)
$setupTab.Controls.Add((New-Label 'CIDR' 292 300 45))
$script:StaticCidrText = New-TextBox 338 298 67 '/24'
$setupTab.Controls.Add($script:StaticCidrText)
$setupTab.Controls.Add((New-Label 'DNS' 292 334 45))
$script:StaticDnsText = New-TextBox 338 332 67 '1.1.1.1'
$setupTab.Controls.Add($script:StaticDnsText)

$setupTab.Controls.Add((New-Label 'Player IP' 16 372 130))
$script:PlayerIpCombo = [System.Windows.Forms.ComboBox]::new()
$script:PlayerIpCombo.DropDownStyle = 'DropDownList'
$script:PlayerIpCombo.Items.AddRange(@('Private', 'Public', 'Manual'))
$script:PlayerIpCombo.SelectedIndex = 1
$script:PlayerIpCombo.SetBounds(160, 370, 120, 24)
$setupTab.Controls.Add($script:PlayerIpCombo)
$script:ManualPlayerIpText = New-TextBox 292 370 113
$setupTab.Controls.Add($script:ManualPlayerIpText)

$script:ReplaceVmCheck = [System.Windows.Forms.CheckBox]::new()
$script:ReplaceVmCheck.Text = 'Replace existing VM / reinstall'
$script:ReplaceVmCheck.SetBounds(16, 408, 230, 24)
$setupTab.Controls.Add($script:ReplaceVmCheck)

$script:CompatibilityWarningsCheck = [System.Windows.Forms.CheckBox]::new()
$script:CompatibilityWarningsCheck.Text = 'Continue on compatibility warnings'
$script:CompatibilityWarningsCheck.Checked = $true
$script:CompatibilityWarningsCheck.SetBounds(250, 408, 170, 24)
$setupTab.Controls.Add($script:CompatibilityWarningsCheck)

$script:SwapCheck = [System.Windows.Forms.CheckBox]::new()
$script:SwapCheck.Text = 'Enable swap if memory is below 20GB'
$script:SwapCheck.Checked = $true
$script:SwapCheck.SetBounds(16, 438, 250, 24)
$setupTab.Controls.Add($script:SwapCheck)

$script:StartAfterSetupCheck = [System.Windows.Forms.CheckBox]::new()
$script:StartAfterSetupCheck.Text = 'Start battlegroup after setup'
$script:StartAfterSetupCheck.SetBounds(16, 468, 220, 24)
$setupTab.Controls.Add($script:StartAfterSetupCheck)

$script:SetupStartButton = New-Button 'Run Automated Setup' 16 514 390 42
$script:SetupStartButton.Font = [Drawing.Font]::new($script:SetupStartButton.Font, [Drawing.FontStyle]::Bold)
$script:SetupStartButton.Add_Click({ Start-InitialSetupFromUi })
$setupTab.Controls.Add($script:SetupStartButton)

foreach ($control in @($setupTab.Controls)) {
    if ($control -ne $script:SetupStateGroup -and $control.Tag -ne 'InsertRegion' -and $control.Top -ge 192) {
        $control.Top += 34
    }
}

foreach ($control in @($setupTab.Controls)) {
    if ($control -ne $script:SetupStateGroup) {
        $control.Top += 112
    }
}

$script:IpModeCombo.Add_SelectedIndexChanged({ Update-StaticFields })
$script:PlayerIpCombo.Add_SelectedIndexChanged({ Update-StaticFields })
$script:UseExternalSwitchCheck.Add_CheckedChanged({ $script:NicCombo.Enabled = $script:UseExternalSwitchCheck.Checked })
$script:ReplaceVmCheck.Add_CheckedChanged({ Update-SetupInstallState })

$settingsGroup = [System.Windows.Forms.GroupBox]::new()
$settingsGroup.Text = 'Server Settings'
$settingsGroup.SetBounds(16, 18, 400, 760)
$settingsTab.Controls.Add($settingsGroup)

$settingsGroup.Controls.Add((New-Label 'World title' 18 30 130))
$script:WorldTitleText = New-TextBox 160 28 220
$settingsGroup.Controls.Add($script:WorldTitleText)

$settingsGroup.Controls.Add((New-Label 'Sietch name' 18 64 130))
$script:ServerDisplayNameText = New-TextBox 160 62 220
$settingsGroup.Controls.Add($script:ServerDisplayNameText)

$settingsGroup.Controls.Add((New-Label 'Password mode' 18 98 130))
$script:PasswordModeCombo = [System.Windows.Forms.ComboBox]::new()
$script:PasswordModeCombo.DropDownStyle = 'DropDownList'
$script:PasswordModeCombo.Items.AddRange(@('Keep', 'Set', 'Clear'))
$script:PasswordModeCombo.SelectedIndex = 0
$script:PasswordModeCombo.SetBounds(160, 96, 78, 24)
$settingsGroup.Controls.Add($script:PasswordModeCombo)
$script:JoinPasswordText = New-TextBox 248 96 132 '' -Password
$settingsGroup.Controls.Add($script:JoinPasswordText)

$settingsGroup.Controls.Add((New-Label 'PvP all' 18 132 130))
$script:PvpModeCombo = [System.Windows.Forms.ComboBox]::new()
$script:PvpModeCombo.DropDownStyle = 'DropDownList'
$script:PvpModeCombo.Items.AddRange(@('Keep', 'Off', 'On'))
$script:PvpModeCombo.SelectedIndex = 0
$script:PvpModeCombo.SetBounds(160, 130, 100, 24)
$settingsGroup.Controls.Add($script:PvpModeCombo)

$settingsGroup.Controls.Add((New-Label 'Security zones' 18 166 130))
$script:SecurityZoneModeCombo = [System.Windows.Forms.ComboBox]::new()
$script:SecurityZoneModeCombo.DropDownStyle = 'DropDownList'
$script:SecurityZoneModeCombo.Items.AddRange(@('Keep', 'On', 'Off'))
$script:SecurityZoneModeCombo.SelectedIndex = 0
$script:SecurityZoneModeCombo.SetBounds(160, 164, 100, 24)
$settingsGroup.Controls.Add($script:SecurityZoneModeCombo)

$script:MiningMultiplierCheck = [System.Windows.Forms.CheckBox]::new()
$script:MiningMultiplierCheck.Text = 'Mining x'
$script:MiningMultiplierCheck.SetBounds(18, 198, 130, 24)
$settingsGroup.Controls.Add($script:MiningMultiplierCheck)
$script:MiningMultiplierNumeric = [System.Windows.Forms.NumericUpDown]::new()
$script:MiningMultiplierNumeric.Minimum = 0
$script:MiningMultiplierNumeric.Maximum = 10
$script:MiningMultiplierNumeric.DecimalPlaces = 2
$script:MiningMultiplierNumeric.Increment = 0.25
$script:MiningMultiplierNumeric.Value = 1
$script:MiningMultiplierNumeric.SetBounds(160, 198, 80, 24)
$settingsGroup.Controls.Add($script:MiningMultiplierNumeric)

$script:PvpResourceMultiplierCheck = [System.Windows.Forms.CheckBox]::new()
$script:PvpResourceMultiplierCheck.Text = 'PvP resource x'
$script:PvpResourceMultiplierCheck.SetBounds(18, 230, 130, 24)
$settingsGroup.Controls.Add($script:PvpResourceMultiplierCheck)
$script:PvpResourceMultiplierNumeric = New-NumberBox 160 230 0 10 2.5 0.25 2
$settingsGroup.Controls.Add($script:PvpResourceMultiplierNumeric)

$script:VehicleDurabilityCheck = [System.Windows.Forms.CheckBox]::new()
$script:VehicleDurabilityCheck.Text = 'Vehicle damage x'
$script:VehicleDurabilityCheck.SetBounds(18, 262, 130, 24)
$settingsGroup.Controls.Add($script:VehicleDurabilityCheck)
$script:VehicleDurabilityNumeric = New-NumberBox 160 262 0 10 1 0.25 2
$settingsGroup.Controls.Add($script:VehicleDurabilityNumeric)

$script:DeteriorationRateCheck = [System.Windows.Forms.CheckBox]::new()
$script:DeteriorationRateCheck.Text = 'Deterioration'
$script:DeteriorationRateCheck.SetBounds(18, 294, 130, 24)
$settingsGroup.Controls.Add($script:DeteriorationRateCheck)
$script:DeteriorationRateNumeric = New-NumberBox 160 294 0 10 1 0.25 2
$settingsGroup.Controls.Add($script:DeteriorationRateNumeric)

$settingsGroup.Controls.Add((New-Label 'Sandstorm' 18 328 130))
$script:SandstormModeCombo = New-ComboBox 160 326 @('Keep', 'Off', 'On')
$settingsGroup.Controls.Add($script:SandstormModeCombo)

$settingsGroup.Controls.Add((New-Label 'Storm treasure' 18 362 130))
$script:SandstormTreasureModeCombo = New-ComboBox 160 360 @('Keep', 'Off', 'On')
$settingsGroup.Controls.Add($script:SandstormTreasureModeCombo)

$settingsGroup.Controls.Add((New-Label 'Coriolis storm' 18 396 130))
$script:CoriolisModeCombo = New-ComboBox 160 394 @('Keep', 'Off', 'On')
$settingsGroup.Controls.Add($script:CoriolisModeCombo)

$settingsGroup.Controls.Add((New-Label 'Sandworm' 18 430 130))
$script:SandwormModeCombo = New-ComboBox 160 428 @('Keep', 'Off', 'On')
$settingsGroup.Controls.Add($script:SandwormModeCombo)

$settingsGroup.Controls.Add((New-Label 'Worm hits vehicles' 18 464 130))
$script:SandwormVehicleCollisionModeCombo = New-ComboBox 160 462 @('Keep', 'Off', 'On')
$settingsGroup.Controls.Add($script:SandwormVehicleCollisionModeCombo)

$settingsGroup.Controls.Add((New-Label 'Worm danger zones' 18 498 130))
$script:SandwormDangerZonesModeCombo = New-ComboBox 160 496 @('Keep', 'Off', 'On')
$settingsGroup.Controls.Add($script:SandwormDangerZonesModeCombo)

$script:SandwormInvulnCheck = [System.Windows.Forms.CheckBox]::new()
$script:SandwormInvulnCheck.Text = 'Worm safe seconds'
$script:SandwormInvulnCheck.SetBounds(18, 530, 140, 24)
$settingsGroup.Controls.Add($script:SandwormInvulnCheck)
$settingsGroup.Controls.Add((New-Label 'Exit' 160 532 32))
$script:SandwormExitInvulnNumeric = New-NumberBox 195 530 0 99999 900 60 0 78
$settingsGroup.Controls.Add($script:SandwormExitInvulnNumeric)
$settingsGroup.Controls.Add((New-Label 'Restart' 280 532 52))
$script:SandwormRestartInvulnNumeric = New-NumberBox 332 530 0 99999 7200 300 0 58
$settingsGroup.Controls.Add($script:SandwormRestartInvulnNumeric)

$settingsGroup.Controls.Add((New-Label 'Build limits' 18 566 130))
$script:BuildingRestrictionModeCombo = New-ComboBox 160 564 @('Keep', 'Off', 'On')
$settingsGroup.Controls.Add($script:BuildingRestrictionModeCombo)

$script:BuildingLimitsCheck = [System.Windows.Forms.CheckBox]::new()
$script:BuildingLimitsCheck.Text = 'Land claims'
$script:BuildingLimitsCheck.SetBounds(18, 598, 110, 24)
$settingsGroup.Controls.Add($script:BuildingLimitsCheck)
$script:LandclaimSegmentsNumeric = New-NumberBox 132 598 0 999 6 1 0 58
$settingsGroup.Controls.Add($script:LandclaimSegmentsNumeric)
$settingsGroup.Controls.Add((New-Label 'Ext' 198 600 28))
$script:BlueprintExtensionsNumeric = New-NumberBox 230 598 0 999 4 1 0 58
$settingsGroup.Controls.Add($script:BlueprintExtensionsNumeric)
$settingsGroup.Controls.Add((New-Label 'Backup' 296 600 48))
$script:BaseBackupExtensionsNumeric = New-NumberBox 342 598 0 999 8 1 0 48
$settingsGroup.Controls.Add($script:BaseBackupExtensionsNumeric)

$script:RestartAfterSettingsCheck = [System.Windows.Forms.CheckBox]::new()
$script:RestartAfterSettingsCheck.Text = 'Restart after apply'
$script:RestartAfterSettingsCheck.Checked = $true
$script:RestartAfterSettingsCheck.SetBounds(18, 634, 160, 24)
$settingsGroup.Controls.Add($script:RestartAfterSettingsCheck)

$loadSettingsButton = New-Button 'Load Current' 18 676 170 34
$loadSettingsButton.Add_Click({ Load-ServerSettingsFromUi })
$settingsGroup.Controls.Add($loadSettingsButton)
$applySettingsButton = New-Button 'Apply Settings' 210 676 170 34
$applySettingsButton.Font = [Drawing.Font]::new($applySettingsButton.Font, [Drawing.FontStyle]::Bold)
$applySettingsButton.Add_Click({ Start-ApplySettingsFromUi })
$settingsGroup.Controls.Add($applySettingsButton)

$settingsFileBrowserButton = New-Button 'File Browser' 18 718 170 34
$settingsFileBrowserButton.Add_Click({ Start-Worker -Action 'OpenFileBrowser' })
$settingsGroup.Controls.Add($settingsFileBrowserButton)
$settingsDirectorButton = New-Button 'Director' 210 718 170 34
$settingsDirectorButton.Add_Click({ Start-Worker -Action 'OpenDirector' })
$settingsGroup.Controls.Add($settingsDirectorButton)

$script:PasswordModeCombo.Add_SelectedIndexChanged({ Update-SettingsFields })
$script:JoinPasswordText.Add_TextChanged({
    if (-not [string]::IsNullOrWhiteSpace($script:JoinPasswordText.Text) -and $script:PasswordModeCombo.SelectedItem -eq 'Keep') {
        $script:PasswordModeCombo.SelectedItem = 'Set'
    }
})
$script:MiningMultiplierCheck.Add_CheckedChanged({ Update-SettingsFields })
$script:PvpResourceMultiplierCheck.Add_CheckedChanged({ Update-SettingsFields })
$script:VehicleDurabilityCheck.Add_CheckedChanged({ Update-SettingsFields })
$script:DeteriorationRateCheck.Add_CheckedChanged({ Update-SettingsFields })
$script:SandwormInvulnCheck.Add_CheckedChanged({ Update-SettingsFields })
$script:BuildingLimitsCheck.Add_CheckedChanged({ Update-SettingsFields })

$vmGroup = [System.Windows.Forms.GroupBox]::new()
$vmGroup.Text = 'VM'
$vmGroup.SetBounds(16, 18, 400, 110)
$actionsTab.Controls.Add($vmGroup)
$startVmButton = New-Button 'Start VM' 18 28 110 32
$startVmButton.Add_Click({ Start-Worker -Action 'StartVm' })
$vmGroup.Controls.Add($startVmButton)
$stopVmButton = New-Button 'Stop VM' 142 28 110 32
$stopVmButton.Add_Click({ Start-Worker -Action 'StopVm' })
$vmGroup.Controls.Add($stopVmButton)
$shellButton = New-Button 'Open Shell' 266 28 110 32
$shellButton.Add_Click({ Open-VmShell })
$vmGroup.Controls.Add($shellButton)

$bgGroup = [System.Windows.Forms.GroupBox]::new()
$bgGroup.Text = 'Battlegroup'
$bgGroup.SetBounds(16, 146, 400, 188)
$actionsTab.Controls.Add($bgGroup)
$statusButton = New-Button 'Status' 18 28 110 32
$statusButton.Add_Click({ Start-Worker -Action 'BattlegroupStatus' })
$bgGroup.Controls.Add($statusButton)
$startButton = New-Button 'Start' 142 28 110 32
$startButton.Add_Click({ Start-Worker -Action 'BattlegroupStart' })
$bgGroup.Controls.Add($startButton)
$restartButton = New-Button 'Restart' 266 28 110 32
$restartButton.Add_Click({ Start-Worker -Action 'BattlegroupRestart' })
$bgGroup.Controls.Add($restartButton)
$stopButton = New-Button 'Stop' 18 74 110 32
$stopButton.Add_Click({ Start-Worker -Action 'BattlegroupStop' })
$bgGroup.Controls.Add($stopButton)
$updateButton = New-Button 'Update' 142 74 110 32
$updateButton.Add_Click({ Start-Worker -Action 'BattlegroupUpdate' })
$bgGroup.Controls.Add($updateButton)
$backupButton = New-Button 'Local Backup' 266 74 110 32
$backupButton.Add_Click({ Start-Worker -Action 'LocalBackup' })
$bgGroup.Controls.Add($backupButton)
$logsButton = New-Button 'Export Logs' 18 120 110 32
$logsButton.Add_Click({ Start-Worker -Action 'ExportLogs' })
$bgGroup.Controls.Add($logsButton)
$fileBrowserButton = New-Button 'File Browser' 142 120 110 32
$fileBrowserButton.Add_Click({ Start-Worker -Action 'OpenFileBrowser' })
$bgGroup.Controls.Add($fileBrowserButton)
$directorButton = New-Button 'Director' 266 120 110 32
$directorButton.Add_Click({ Start-Worker -Action 'OpenDirector' })
$bgGroup.Controls.Add($directorButton)

$watchdogGroup = [System.Windows.Forms.GroupBox]::new()
$watchdogGroup.Text = 'Health Watchdog'
$watchdogGroup.SetBounds(16, 354, 400, 150)
$actionsTab.Controls.Add($watchdogGroup)
$healthButton = New-Button 'Check Health' 18 28 110 32
$healthButton.Add_Click({ Start-HealthCheckFromUi })
$watchdogGroup.Controls.Add($healthButton)
$repairButton = New-Button 'Run Repair' 142 28 110 32
$repairButton.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Run safe repair now? This can start the VM/world and remove failed one-shot schema pods.',
        'Auto repair',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-HealthCheckFromUi -RepairNow
    }
})
$watchdogGroup.Controls.Add($repairButton)
$script:WatchdogEnableCheck = [System.Windows.Forms.CheckBox]::new()
$script:WatchdogEnableCheck.Text = 'Enable watchdog'
$script:WatchdogEnableCheck.SetBounds(18, 74, 130, 24)
$script:WatchdogEnableCheck.Add_CheckedChanged({
    $script:WatchdogNextRun = [datetime]::MinValue
    if ($script:WatchdogEnableCheck.Checked) {
        Add-LogLine 'Health watchdog enabled.'
    } else {
        Add-LogLine 'Health watchdog disabled.'
    }
})
$watchdogGroup.Controls.Add($script:WatchdogEnableCheck)
$script:WatchdogAutoRepairCheck = [System.Windows.Forms.CheckBox]::new()
$script:WatchdogAutoRepairCheck.Text = 'Auto repair'
$script:WatchdogAutoRepairCheck.Checked = $true
$script:WatchdogAutoRepairCheck.SetBounds(160, 74, 100, 24)
$watchdogGroup.Controls.Add($script:WatchdogAutoRepairCheck)
$script:WatchdogKeepRunningCheck = [System.Windows.Forms.CheckBox]::new()
$script:WatchdogKeepRunningCheck.Text = 'Keep world running'
$script:WatchdogKeepRunningCheck.Checked = $true
$script:WatchdogKeepRunningCheck.SetBounds(18, 104, 150, 24)
$watchdogGroup.Controls.Add($script:WatchdogKeepRunningCheck)
$watchdogGroup.Controls.Add((New-Label 'Every' 268 78 40))
$script:WatchdogIntervalNumeric = New-NumberBox 310 74 30 600 60 30 0 66
$watchdogGroup.Controls.Add($script:WatchdogIntervalNumeric)
$script:WatchdogLastLabel = New-Label 'Last check: never' 180 108 190
$watchdogGroup.Controls.Add($script:WatchdogLastLabel)

$helperGroup = [System.Windows.Forms.GroupBox]::new()
$helperGroup.Text = 'Tools'
$helperGroup.SetBounds(16, 524, 400, 118)
$actionsTab.Controls.Add($helperGroup)
$officialButton = New-Button 'Official Menu' 18 30 110 32
$officialButton.Add_Click({
    if ($ServerRoot -and (Test-Path -LiteralPath (Join-Path $ServerRoot 'battlegroup.bat'))) {
        Start-Process -FilePath (Join-Path $ServerRoot 'battlegroup.bat') -WorkingDirectory $ServerRoot
    } else {
        [System.Windows.Forms.MessageBox]::Show('Steam server package not found. Install it through Steam Tools or set DUNE_SERVER_ROOT before launching DuneManager.', 'DuneManager') | Out-Null
    }
})
$helperGroup.Controls.Add($officialButton)
$logsFolderButton = New-Button 'Manager Logs' 142 30 110 32
$logsFolderButton.Add_Click({ Start-Process $LogsDir })
$helperGroup.Controls.Add($logsFolderButton)
$refreshListsButton = New-Button 'Refresh Lists' 266 30 110 32
$refreshListsButton.Add_Click({ Populate-Drives; Populate-Nics; Refresh-Status })
$helperGroup.Controls.Add($refreshListsButton)
$licenseButton = New-Button 'About Ace' 18 72 110 32
$licenseButton.Add_Click({ Show-LicenseMessage })
$helperGroup.Controls.Add($licenseButton)
$restoreBackupButton = New-Button 'Restore Backup' 142 72 110 32
$restoreBackupButton.Add_Click({ Start-RestoreBackupFromUi })
$helperGroup.Controls.Add($restoreBackupButton)
$backupsFolderButton = New-Button 'Backups' 266 72 110 32
$backupsFolderButton.Add_Click({ New-Item -ItemType Directory -Force -Path $BackupsDir | Out-Null; Start-Process $BackupsDir })
$helperGroup.Controls.Add($backupsFolderButton)

$rightPanel = [System.Windows.Forms.Panel]::new()
$rightPanel.Dock = 'Fill'
$split.Panel2.Controls.Add($rightPanel)

$script:LogBox = [System.Windows.Forms.TextBox]::new()
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = [Drawing.Font]::new('Consolas', 9)
$script:LogBox.Dock = 'Fill'
$rightPanel.Controls.Add($script:LogBox)

$bottomPanel = [System.Windows.Forms.Panel]::new()
$bottomPanel.Dock = 'Bottom'
$bottomPanel.Height = 38
$rightPanel.Controls.Add($bottomPanel)

$script:BusyLabel = New-Label 'Idle' 0 9 230
$bottomPanel.Controls.Add($script:BusyLabel)
$script:Progress = [System.Windows.Forms.ProgressBar]::new()
$script:Progress.SetBounds(240, 8, 250, 18)
$script:Progress.Anchor = 'Top,Left,Right'
$bottomPanel.Controls.Add($script:Progress)
$cancelTaskButton = [System.Windows.Forms.Button]::new()
$cancelTaskButton.Text = 'Cancel Task'
$cancelTaskButton.SetBounds(502, 5, 92, 26)
$cancelTaskButton.Anchor = 'Top,Right'
$cancelTaskButton.Add_Click({ Stop-CurrentTask })
$bottomPanel.Controls.Add($cancelTaskButton)
$signatureLabel = New-Label 'DuneManager by Ace' 604 9 150
$signatureLabel.Anchor = 'Top,Right'
$bottomPanel.Controls.Add($signatureLabel)

Populate-Drives
Populate-Nics
Update-StaticFields
Update-SettingsFields
Refresh-Status

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 1000
$timer.Add_Tick({
    Poll-WorkerLog
    Complete-WorkerIfExited
    Refresh-Status
    Invoke-WatchdogTimer
})
$timer.Start()

$autoLoadTimer = [System.Windows.Forms.Timer]::new()
$autoLoadTimer.Interval = 1200
$autoLoadTimer.Add_Tick({
    $autoLoadTimer.Stop()
    Start-SettingsAutoLoad
})
$autoLoadTimer.Start()

$script:Form.Add_FormClosing({
    param($sender, $eventArgs)

    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'A background task is still running. Close anyway?',
            'DuneManager',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }
    }
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        try { $script:CurrentProcess.Kill() } catch {}
    }
})

Add-LogLine 'DuneManager UI ready.'

if ($SmokeTest) {
    Write-Host 'GUI smoke OK'
    exit 0
}

if ($WorkerSmokeTest) {
    Start-Worker -Action 'BattlegroupStatus'
    while ($script:CurrentProcess) {
        Start-Sleep -Milliseconds 200
        Poll-WorkerLog
        Complete-WorkerIfExited
    }
    Write-Host 'Worker smoke OK'
    exit 0
}

[void][System.Windows.Forms.Application]::Run($script:Form)
