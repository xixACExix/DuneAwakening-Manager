# Background automation worker for DuneManager GUI.

param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'InitialSetup',
        'StartVm',
        'StopVm',
        'BattlegroupStatus',
        'BattlegroupStart',
        'BattlegroupRestart',
        'BattlegroupStop',
        'BattlegroupUpdate',
        'BattlegroupBackup',
        'LocalBackup',
        'RestoreBackup',
        'ExportLogs',
        'OpenFileBrowser',
        'OpenDirector',
        'HealthCheck',
        'AutoRepair',
        'ApplySettings'
    )]
    [string]$Action,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

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
$OfficialScriptDir = if ($ServerRoot) { Join-Path $ServerRoot 'battlegroup-management' } else { $null }
$BootstrapSetup = if ($OfficialScriptDir) { Join-Path $OfficialScriptDir 'bootstrap\setup' } else { $null }
$VmName = 'dune-awakening'
$SshKey = Join-Path $env:LOCALAPPDATA 'DuneAwakeningServer\sshKey'
$SshKeyDir = Split-Path -Parent $SshKey
$RunDir = Join-Path $PSScriptRoot 'run'
$BackupsDir = Join-Path $PSScriptRoot 'backups'
New-Item -ItemType Directory -Force -Path $RunDir, $BackupsDir | Out-Null

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        throw 'This action needs Administrator access. Relaunch DuneManager through Start-DuneManager.bat.'
    }
}

function Assert-ServerPackage {
    if (-not $ServerRoot) {
        throw 'Could not find the Dune Awakening Self-Hosted Server Steam package. Install it through Steam Tools or set DUNE_SERVER_ROOT to its folder before launching DuneManager.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ServerRoot 'battlegroup-management\battlegroup.ps1'))) {
        throw "The detected folder is not a valid Dune self-hosted server package: $ServerRoot"
    }
}

function Get-DuneVm {
    try {
        Get-VM -Name $VmName -ErrorAction Stop
    } catch {
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
    }
}

function Resolve-DuneVm {
    param([string]$Destination)

    $vm = Get-DuneVm
    if ($vm) { return $vm }

    if (-not $Destination) { return $null }

    $resolvedDestination = $Destination
    if (Test-Path $Destination) {
        $resolvedDestination = (Resolve-Path -LiteralPath $Destination).Path
    }

    $matches = @(Get-VM -ErrorAction SilentlyContinue | Where-Object {
        $_.ConfigurationLocation -and
        (
            $_.ConfigurationLocation -like "$Destination*" -or
            $_.ConfigurationLocation -like "$resolvedDestination*"
        )
    })

    if ($matches.Count -eq 1) {
        Write-Step "Resolved imported VM by path: $($matches[0].Name)"
        return $matches[0]
    }
    if ($matches.Count -gt 1) {
        $names = ($matches | ForEach-Object { $_.Name }) -join ', '
        throw "Multiple VMs were found under ${Destination}: $names"
    }

    return $null
}

function Ensure-DuneVmName {
    param(
        [Parameter(Mandatory)]$Vm,
        [string]$Destination
    )

    if ($Vm.Name -eq $VmName) {
        return $Vm
    }

    Write-Step "Renaming imported VM '$($Vm.Name)' to '$VmName'..."
    Rename-VM -VM $Vm -NewName $VmName -ErrorAction Stop | Out-Null
    return (Resolve-DuneVm -Destination $Destination)
}

function Get-DuneVmIp {
    $vm = Get-DuneVm
    if (-not $vm -or $vm.State -ne 'Running') { return $null }

    Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1
}

function Wait-DuneVmIp {
    param([int]$TimeoutSeconds = 180)

    Write-Step "Waiting for VM IP address..."
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $ip = Get-DuneVmIp
        if ($ip) {
            Write-Step "VM IP address is $ip"
            return $ip
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    throw "VM did not get an IP address within $TimeoutSeconds seconds."
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [switch]$Tty,
        [int]$ConnectTimeoutSeconds = 10
    )

    if (-not (Test-Path $SshKey)) {
        throw "SSH key is missing: $SshKey"
    }

    $args = @(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'LogLevel=QUIET',
        '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
        '-o', 'BatchMode=yes',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=3',
        '-i', $SshKey,
        "dune@$Ip",
        $RemoteCommand
    )
    if ($Tty) { $args = @('-t') + $args }

    & ssh @args
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed with exit code $LASTEXITCODE."
    }
}

function Invoke-SshWithInput {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [Parameter(Mandatory)][string]$InputText,
        [int]$ConnectTimeoutSeconds = 30
    )

    if (-not (Test-Path $SshKey)) {
        throw "SSH key is missing: $SshKey"
    }

    $inputPath = Join-Path $env:TEMP ("dune-ssh-input-" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        Set-Content -LiteralPath $inputPath -Value $InputText -NoNewline -Encoding ASCII
        $remoteExit = $null
        Get-Content -LiteralPath $inputPath -Raw |
            & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -o "ConnectTimeout=$ConnectTimeoutSeconds" -o BatchMode=yes -o IdentitiesOnly=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -i $SshKey "dune@$Ip" "($RemoteCommand) 2>&1; rc=`$?; echo __DUNE_EXIT__:`$rc; exit `$rc" 2>&1 |
            ForEach-Object {
                $line = "$_"
                if ($line -match '__DUNE_EXIT__:(\d+)') {
                    $remoteExit = [int]$Matches[1]
                    return
                }
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Write-Step $line
                }
            }
        $sshExit = $LASTEXITCODE
        if ($sshExit -ne 0 -or ($null -ne $remoteExit -and $remoteExit -ne 0)) {
            throw "SSH command with input failed. ssh=$sshExit remote=$remoteExit"
        }
        return $null
    }
    finally {
        Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
    }
}

function Repair-BattlegroupAfterSetup {
    param([Parameter(Mandatory)][string]$Ip)

    Write-Step 'Checking battlegroup post-setup state...'
    $remoteScript = @'
set -e
ns=$(sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name | grep '^funcom-seabass-' | head -n1 || true)
if [ -z "$ns" ]; then
  echo "No battlegroup namespace exists yet."
  exit 0
fi

bg=${ns#funcom-seabass-}
echo "Detected battlegroup namespace: $ns"

if ! sudo kubectl get battlegroup "$bg" -n "$ns" >/dev/null 2>&1; then
  echo "Battlegroup resource is missing; reapplying generated world YAML."
  sudo kubectl apply -n "$ns" -f "/home/dune/.dune/$bg-fls-secret.yaml"
  sudo kubectl apply -n "$ns" -f "/home/dune/.dune/$bg-rmq-secret.yaml"
  sudo kubectl apply -n "$ns" -f "/home/dune/.dune/$bg.yaml"
fi

for i in $(seq 1 60); do
  if sudo kubectl get battlegroup "$bg" -n "$ns" >/dev/null 2>&1; then
    echo "Battlegroup resource exists."
    break
  fi
  echo "Waiting for battlegroup resource... ($i/60)"
  sleep 5
done

sudo kubectl get battlegroup "$bg" -n "$ns"

echo "Ensuring downloaded battlegroup image version is applied."
/home/dune/.dune/download/scripts/battlegroup.sh update-from-downloads

echo "Waiting for file browser pod before applying default user settings."
for i in $(seq 1 60); do
  fb_pod=$(sudo kubectl get pods -n "$ns" -l role=igw-filebrowser --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -n1 || true)
  if [ -n "$fb_pod" ]; then
    phase=$(sudo kubectl get pod "$fb_pod" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" = "Running" ]; then
      echo "File browser pod is running: $fb_pod"
      break
    fi
  fi
  echo "Waiting for file browser pod... ($i/60)"
  sleep 5
done

/home/dune/.dune/download/scripts/battlegroup.sh apply-default-usersettings || true
'@

    $remoteScriptLf = $remoteScript -replace "`r`n", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScriptLf))
    Invoke-Ssh -Ip $Ip -RemoteCommand "echo $encoded | base64 -d | bash" -ConnectTimeoutSeconds 30
}

function ConvertTo-Base64Utf8 {
    param([string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Assert-SafeIniValue {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if ($Value -match "['\|`"`r`n]") {
        throw "$Name cannot contain quotes, apostrophes, pipes, or new lines."
    }
}

function Convert-SettingNumber {
    param(
        [string]$Name,
        [string]$Value,
        [double]$Min,
        [double]$Max,
        [int]$Decimals = 3
    )

    $parsed = 0.0
    if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        throw "$Name is not a number: $Value"
    }
    if ($parsed -lt $Min -or $parsed -gt $Max) {
        throw "$Name must be between $Min and $Max."
    }
    $format = '0'
    if ($Decimals -gt 0) { $format = '0.' + ('#' * $Decimals) }
    return $parsed.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
}

function Convert-SettingInt {
    param(
        [string]$Name,
        [string]$Value,
        [int]$Min,
        [int]$Max
    )

    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed)) {
        throw "$Name is not a whole number: $Value"
    }
    if ($parsed -lt $Min -or $parsed -gt $Max) {
        throw "$Name must be between $Min and $Max."
    }
    return "$parsed"
}

function Test-SshKeyAuth {
    param([Parameter(Mandatory)][string]$Ip)

    if (-not (Test-Path $SshKey)) { return $false }
    & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=5 -o BatchMode=yes -i $SshKey "dune@$Ip" "true" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Add-SshNetAssembly {
    $dll = Join-Path $PSScriptRoot 'lib\SSH.NET-2020.0.2\lib\net40\Renci.SshNet.dll'
    if (-not (Test-Path $dll)) {
        Write-Step 'SSH.NET dependency is missing; downloading it from NuGet...'
        $packageDir = Join-Path $PSScriptRoot 'lib\SSH.NET-2020.0.2'
        $packagePath = Join-Path $packageDir 'ssh.net.2020.0.2.nupkg'
        New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

        try {
            Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/SSH.NET/2020.0.2' -OutFile $packagePath -UseBasicParsing -ErrorAction Stop
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $packageDir)
        } catch {
            throw "SSH.NET was not found at $dll and automatic download failed: $($_.Exception.Message)"
        }

        if (-not (Test-Path $dll)) {
            throw "SSH.NET download completed, but the expected DLL was not found at $dll."
        }
    }
    Add-Type -Path $dll -ErrorAction Stop
}

function Set-PrivateKeyAcl {
    param([Parameter(Mandatory)][string]$Path)

    takeown /f $Path 2>&1 | Out-Null
    icacls $Path /inheritance:r /grant:r "${env:USERNAME}:(R)" 2>&1 | Out-Null
}

function Install-SshKeyWithPassword {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Password
    )

    Write-Step 'Generating SSH key...'
    New-Item -ItemType Directory -Force -Path $SshKeyDir | Out-Null

    $tempStem = Join-Path $env:TEMP ("dune-manager-key-" + [guid]::NewGuid().ToString('N'))
    & ssh-keygen -t ed25519 -f $tempStem -N '""' -q -C "dune-manager@$env:COMPUTERNAME" | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tempStem) -or -not (Test-Path "$tempStem.pub")) {
        throw 'ssh-keygen failed.'
    }
    Set-PrivateKeyAcl -Path $tempStem

    try {
        Add-SshNetAssembly
        $publicKey = (Get-Content -Raw -LiteralPath "$tempStem.pub").Trim() + "`n"
        $b64PublicKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKey))

        Write-Step 'Installing SSH key on the VM with password authentication...'
        $connection = [Renci.SshNet.PasswordConnectionInfo]::new($Ip, 22, 'dune', $Password)
        $connection.Timeout = [TimeSpan]::FromSeconds(25)
        $client = [Renci.SshNet.SshClient]::new($connection)
        $client.Connect()

        $remoteScript = @"
set -e
mkdir -p "`$HOME/.ssh"
chmod 700 "`$HOME/.ssh"
echo $b64PublicKey | base64 -d > "`$HOME/.ssh/authorized_keys.new"
chmod 600 "`$HOME/.ssh/authorized_keys.new"
mv "`$HOME/.ssh/authorized_keys.new" "`$HOME/.ssh/authorized_keys"
echo ROTATE_OK
"@
        $cmd = $client.CreateCommand($remoteScript)
        $output = $cmd.Execute()
        if ($cmd.ExitStatus -ne 0 -or $output -notmatch 'ROTATE_OK') {
            throw "Could not install SSH key. $($cmd.Error)"
        }
        $client.Disconnect()
        $client.Dispose()

        if (Test-Path $SshKey) {
            takeown /f $SshKey 2>&1 | Out-Null
            icacls $SshKey /reset 2>&1 | Out-Null
            Remove-Item -LiteralPath $SshKey -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath "$SshKey.pub" -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $tempStem -Destination $SshKey -Force
        Move-Item -LiteralPath "$tempStem.pub" -Destination "$SshKey.pub" -Force
        Set-PrivateKeyAcl -Path $SshKey
        Write-Step "SSH key saved to $SshKey"

        Write-Step 'Verifying new SSH key...'
        $lastVerifyOutput = $null
        $verified = $false
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $verifyOutput = & ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=8 -o BatchMode=yes -o IdentitiesOnly=yes -i $SshKey "dune@$Ip" "true" 2>&1
            $lastVerifyOutput = ($verifyOutput | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                $verified = $true
                break
            }
            Write-Step "SSH key verification attempt $attempt failed; retrying..."
            if ($lastVerifyOutput) {
                Write-Step "SSH said: $lastVerifyOutput"
            }
            Start-Sleep -Seconds 2
        }

        if (-not $verified) {
            throw "The new SSH key was installed and saved, but did not authenticate. Last SSH output: $lastVerifyOutput"
        }
        Write-Step 'SSH key authentication works.'
    }
    finally {
        Remove-Item -LiteralPath $tempStem -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$tempStem.pub" -Force -ErrorAction SilentlyContinue
    }
}

function Set-VmPassword {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$NewPassword
    )

    if ([string]::IsNullOrWhiteSpace($NewPassword)) {
        Write-Step 'No new VM password was provided; skipping password change.'
        return
    }

    Write-Step "Changing the VM user's password..."
    $payload = "dune:$NewPassword`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $remoteCmd = "echo $b64 | base64 -d | sudo -n chpasswd >/tmp/dune-password-change.log 2>&1; rc=`$?; cat /tmp/dune-password-change.log; if [ `$rc -eq 0 ]; then echo PWOK; else exit `$rc; fi"
    $output = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i $SshKey "dune@$Ip" $remoteCmd 2>&1
    $outText = ($output | Out-String)
    if ($LASTEXITCODE -ne 0 -or ($outText -notmatch 'PWOK')) {
        throw "Failed to change VM password. Output: $($output | Out-String)"
    }
    foreach ($line in @($output)) {
        if ($line -and "$line" -notmatch 'PWOK') {
            Write-Step "$line"
        }
    }
    Write-Step 'VM password changed.'
}

function Remove-DuneDestination {
    param([Parameter(Mandatory)][string]$Destination)

    $resolvedParent = Split-Path -Parent $Destination
    $leaf = Split-Path -Leaf $Destination
    if ($leaf -ne 'DuneAwakeningServer' -or -not ($resolvedParent -match '^[A-Z]:\\?$')) {
        throw "Refusing to delete unexpected path: $Destination"
    }
    if (Test-Path $Destination) {
        Write-Step "Clearing existing destination folder: $Destination"
        $attempt = 0
        while ((Test-Path $Destination) -and $attempt -lt 5) {
            $attempt += 1
            try {
                Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction Stop
            } catch {
                if ($attempt -ge 5) { throw }
                Write-Step "Destination cleanup is still settling; retrying..."
                Start-Sleep -Seconds 2
            }
        }
    }
}

function Wait-ForVmRemoval {
    param(
        [string]$Destination,
        [int]$TimeoutSeconds = 30
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $vm = Resolve-DuneVm -Destination $Destination
        if (-not $vm) { return }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    throw "VM '$VmName' still appears to be registered after removal."
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-HyperVChildScript {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Lines
    )

    $scriptPath = Join-Path $RunDir ("hyperv-{0}-{1}.ps1" -f $Name, [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $scriptPath -Value $Lines -Encoding UTF8
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        foreach ($line in @($output)) {
            if (-not [string]::IsNullOrWhiteSpace("$line")) {
                Write-Step "$line"
            }
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = ($output | Out-String)
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DirectVmImport {
    param(
        [Parameter(Mandatory)][string]$SourceVmcx,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$VhdDestination
    )

    Write-Step 'Trying direct Import-VM fallback in isolated worker...'
    $result = Invoke-HyperVChildScript -Name 'direct-import' -Lines @(
        '$ErrorActionPreference = ''Continue''',
        ('$source = {0}' -f (Quote-PowerShellLiteral $SourceVmcx)),
        ('$destination = {0}' -f (Quote-PowerShellLiteral $Destination)),
        ('$vhdDestination = {0}' -f (Quote-PowerShellLiteral $VhdDestination)),
        'try {',
        '    $vm = Import-VM -Path $source -Copy -GenerateNewId -VirtualMachinePath $destination -VhdDestinationPath $vhdDestination -ErrorAction Continue',
        '    if ($vm) { $vm | Select-Object Name, Id, ConfigurationLocation | Format-List | Out-String | Write-Host }',
        '    exit 0',
        '} catch {',
        '    Write-Host ("IMPORT_EXCEPTION: " + $_.Exception.Message)',
        '    exit 1',
        '}'
    )

    Start-Sleep -Seconds 2
    $imported = Resolve-DuneVm -Destination $Destination
    if ($imported) {
        Write-Step "Hyper-V registered the VM after direct import: $($imported.Name)"
        return $imported
    }

    Write-Step "Direct import did not register a VM. Exit code was $($result.ExitCode)."
    $copiedVmcx = Get-ChildItem -LiteralPath (Join-Path $Destination 'Virtual Machines') -Filter '*.vmcx' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $copiedVmcx) {
        return $null
    }

    Write-Step "Trying to register copied VM: $($copiedVmcx.FullName)"
    $registerResult = Invoke-HyperVChildScript -Name 'register-import' -Lines @(
        '$ErrorActionPreference = ''Continue''',
        ('$copiedVmcx = {0}' -f (Quote-PowerShellLiteral $copiedVmcx.FullName)),
        'try {',
        '    $vm = Import-VM -Path $copiedVmcx -Register -ErrorAction Continue',
        '    if ($vm) { $vm | Select-Object Name, Id, ConfigurationLocation | Format-List | Out-String | Write-Host }',
        '    exit 0',
        '} catch {',
        '    Write-Host ("REGISTER_EXCEPTION: " + $_.Exception.Message)',
        '    exit 1',
        '}'
    )

    Start-Sleep -Seconds 2
    $imported = Resolve-DuneVm -Destination $Destination
    if ($imported) {
        Write-Step "Hyper-V registered the copied VM: $($imported.Name)"
        return $imported
    }

    Write-Step "Copied VM registration did not produce a registered VM. Exit code was $($registerResult.ExitCode)."
    return $null
}

function Invoke-StartVmIsolated {
    param([string]$Destination)

    Write-Step "Starting VM '$VmName' in isolated worker..."
    $result = Invoke-HyperVChildScript -Name 'start-vm' -Lines @(
        '$ErrorActionPreference = ''Continue''',
        ('$vmName = {0}' -f (Quote-PowerShellLiteral $VmName)),
        'try {',
        '    Start-VM -Name $vmName -ErrorAction Continue',
        '    Write-Host "START_VM_DONE"',
        '    exit 0',
        '} catch {',
        '    Write-Host ("START_VM_EXCEPTION: " + $_.Exception.Message)',
        '    exit 1',
        '}'
    )

    Start-Sleep -Seconds 2
    $vm = Resolve-DuneVm -Destination $Destination
    if ($vm -and $vm.State -eq 'Running') {
        Write-Step "VM is running after isolated start."
        return $vm
    }

    if ($result.ExitCode -ne 0) {
        Write-Step "Start-VM child worker reported exit code $($result.ExitCode)."
    }
    return $vm
}

function Ensure-VmImported {
    param([Parameter(Mandatory)]$Config)

    Assert-Admin
    Assert-ServerPackage

    $vmcx = Get-Item (Join-Path $ServerRoot 'Virtual Machines\*.vmcx') -ErrorAction Stop | Select-Object -First 1
    $drive = ($Config.InstallDrive | ForEach-Object { "$_".TrimEnd('\') })
    if ($drive -notmatch '^[A-Z]:$') {
        throw "Invalid install drive: $drive"
    }
    $destination = Join-Path "$drive\" 'DuneAwakeningServer'

    $existingVm = Get-DuneVm
    if (-not $existingVm) {
        $existingVm = Resolve-DuneVm -Destination $destination
        if ($existingVm) {
            $existingVm = Ensure-DuneVmName -Vm $existingVm -Destination $destination
        }
    }

    if ($existingVm -and $Config.ReplaceExistingVm) {
        Write-Step "Removing existing VM '$VmName'..."
        if ($existingVm.State -eq 'Running') {
            Stop-VM -VM $existingVm -TurnOff -Force -ErrorAction Stop
        }
        Remove-VM -VM $existingVm -Force -ErrorAction Stop
        Wait-ForVmRemoval -Destination $destination
        $existingVm = $null
    }

    if (-not $existingVm) {
        Remove-DuneDestination -Destination $destination
        $vhdDestination = Join-Path $destination 'Virtual Hard Disks'
        New-Item -ItemType Directory -Force -Path $destination, $vhdDestination | Out-Null

        Write-Step 'Checking packaged VM compatibility...'
        try {
            $compatibility = Compare-VM -Path $vmcx.FullName -Copy -VirtualMachinePath $destination -VhdDestinationPath $vhdDestination -ErrorAction Stop
            if ($compatibility.Incompatibilities.Count -gt 0) {
                foreach ($issue in $compatibility.Incompatibilities) {
                    Write-Step "Compatibility warning: $($issue.Message)"
                }
                if (-not $Config.ContinueOnCompatibilityWarnings) {
                    throw 'Compatibility warnings were detected and continue-on-warning is disabled.'
                }
            }
    
            Write-Step "Importing VM to $destination..."
            $imported = Import-VM -CompatibilityReport $compatibility -ErrorAction Stop
        } catch {
            Write-Step "Compare-VM path failed: $($_.Exception.Message)"
            $imported = Invoke-DirectVmImport -SourceVmcx $vmcx.FullName -Destination $destination -VhdDestination $vhdDestination
        }
        if (-not $imported) {
            $imported = Resolve-DuneVm -Destination $destination
        }
        if (-not $imported) {
            throw "VM import appeared to finish, but no imported VM was found under $destination."
        }
        $imported = Ensure-DuneVmName -Vm $imported -Destination $destination
        Write-Step 'VM imported.'
    } else {
        Write-Step "VM '$VmName' already exists; import skipped."
    }

    Configure-VmHardware -Config $Config -Destination $destination
}

function Configure-VmHardware {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Destination
    )

    Assert-Admin

    $vm = Resolve-DuneVm -Destination $Destination
    if (-not $vm) { throw "VM '$VmName' was not found for hardware configuration." }
    $vm = Ensure-DuneVmName -Vm $vm -Destination $Destination

    if ($vm -and $vm.State -eq 'Running') {
        Write-Step "Stopping VM '$VmName' before hardware changes..."
        Stop-VM -VM $vm -Force -ErrorAction Stop | Out-Null
        $vm = Get-VM -Name $VmName -ErrorAction Stop
    }

    $switchName = 'Default Switch'
    if ($Config.UseExternalSwitch) {
        Write-Step 'Preparing external Hyper-V switch...'
        $physicalNics = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual' })
        if ($physicalNics.Count -eq 0) {
            throw 'No active physical network adapter was found for an external switch.'
        }

        $selectedNic = $null
        if ($Config.NetworkAdapterName) {
            $selectedNic = $physicalNics | Where-Object { $_.Name -eq $Config.NetworkAdapterName } | Select-Object -First 1
        }
        if (-not $selectedNic) {
            $selectedNic = $physicalNics | Sort-Object { if ($_.Name -match 'ethernet') { 0 } else { 1 } }, Name | Select-Object -First 1
        }

        $boundSwitch = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue |
            Where-Object { $_.NetAdapterInterfaceDescription -eq $selectedNic.InterfaceDescription } |
            Select-Object -First 1

        if ($boundSwitch) {
            $switchName = $boundSwitch.Name
            Write-Step "Using existing external switch '$switchName'."
        } else {
            $switchName = 'DuneAwakeningServerSwitch'
            if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
                $switchName = "DuneAwakeningServerSwitch-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
            }
            Write-Step "Creating external switch '$switchName' on '$($selectedNic.Name)'..."
            New-VMSwitch -Name $switchName -NetAdapterName $selectedNic.Name -AllowManagementOS $true -ErrorAction Stop | Out-Null
        }
    } else {
        Write-Step "Using Hyper-V '$switchName'."
    }

    Write-Step "Connecting VM network adapter to '$switchName'..."
    $adapters = @(Get-VMNetworkAdapter -VM $vm -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) {
        Write-Step 'No VM network adapter was found; adding one.'
        Add-VMNetworkAdapter -VMName $VmName -Name 'Network Adapter' -SwitchName $switchName -ErrorAction Stop
    } else {
        foreach ($adapter in $adapters) {
            Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -SwitchName $switchName -ErrorAction Stop | Out-Null
        }
    }
    Write-Step "VM network connected to '$switchName'."

    Write-Step 'Locating VM hard disk...'
    $vhdx = $null
    try {
        $vhdx = Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop | Select-Object -First 1
    } catch {
        Write-Step "Hyper-V did not return the VM hard disk object yet: $($_.Exception.Message)"
    }

    $vhdxPath = $null
    if ($vhdx -and (Test-Path $vhdx.Path)) {
        $vhdxPath = $vhdx.Path
    } elseif ($Destination) {
        $fallbackVhdx = Get-ChildItem -LiteralPath (Join-Path $Destination 'Virtual Hard Disks') -Filter '*.vhdx' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($fallbackVhdx) {
            $vhdxPath = $fallbackVhdx.FullName
            Write-Step "Using copied VHDX path: $vhdxPath"
        }
    }

    if ($vhdxPath -and (Test-Path $vhdxPath)) {
        Write-Step 'Resizing virtual disk to 100GB...'
        Resize-VHD -Path $vhdxPath -SizeBytes 100GB -ErrorAction Stop
        if ($vhdx) {
            try {
                Set-VMFirmware -VMName $VmName -FirstBootDevice $vhdx -ErrorAction Stop
            } catch {
                Write-Step "Could not set first boot device automatically: $($_.Exception.Message)"
            }
        }
    } else {
        Write-Step 'No VM hard disk was found to resize.'
    }

    $memoryGB = [int]$Config.MemoryGB
    if ($memoryGB -lt 1) { $memoryGB = 20 }
    Write-Step "Setting VM memory to ${memoryGB}GB..."
    try {
        Set-VMMemory -VM $vm -StartupBytes ([int64]$memoryGB * 1GB) -ErrorAction Stop
    } catch {
        Write-Step "Direct memory configuration failed: $($_.Exception.Message)"
        Write-Step 'Trying memory configuration by VM name...'
        Set-VMMemory -VMName $VmName -StartupBytes ([int64]$memoryGB * 1GB) -ErrorAction Stop
    }
}

function Start-DuneVm {
    param([string]$Destination)

    Assert-Admin

    $vm = Resolve-DuneVm -Destination $Destination
    if (-not $vm) { throw "VM '$VmName' does not exist." }
    if ($vm.State -ne 'Running') {
        try {
            Write-Step "Starting VM '$VmName'..."
            Start-VM -VM $vm -ErrorAction Stop | Out-Null
        } catch {
            Write-Step "Direct Start-VM failed: $($_.Exception.Message)"
            $vm = Invoke-StartVmIsolated -Destination $Destination
            if (-not $vm -or $vm.State -ne 'Running') {
                throw "Start-VM failed and the VM is not running."
            }
        }
    } else {
        Write-Step "VM '$VmName' is already running."
    }
    Wait-DuneVmIp | Out-Null
}

function Stop-DuneVm {
    Assert-Admin

    $vm = Get-DuneVm
    if (-not $vm) { throw "VM '$VmName' does not exist." }
    if ($vm.State -eq 'Running') {
        Write-Step "Stopping VM '$VmName'..."
        Stop-VM -Name $VmName -Force -ErrorAction Stop | Out-Null
        Write-Step 'VM stopped.'
    } else {
        Write-Step "VM is already $($vm.State)."
    }
}

function Apply-StaticIp {
    param(
        [Parameter(Mandatory)][string]$CurrentIp,
        [Parameter(Mandatory)]$Config
    )

    if ($Config.IpMode -ne 'Static') { return $CurrentIp }

    $staticIp = "$($Config.StaticIp)".Trim()
    $staticCidr = "$($Config.StaticCidr)".Trim()
    $staticGateway = "$($Config.StaticGateway)".Trim()
    $staticDns = "$($Config.StaticDns)".Trim()
    if ($staticCidr -notmatch '^/\d+$') { $staticCidr = '/24' }
    if (-not $staticDns) { $staticDns = '1.1.1.1' }

    if ($staticIp -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Invalid static IP: $staticIp" }
    if ($staticGateway -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Invalid static gateway: $staticGateway" }

    Write-Step "Applying static VM IP $staticIp..."
    $interfacesContent = "auto lo`niface lo inet loopback`n`nauto eth0`niface eth0 inet static`n    address $staticIp$staticCidr`n    gateway $staticGateway`n"
    $b64Interfaces = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($interfacesContent))
    $b64Resolv = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("nameserver $staticDns`n"))

    $applyScript = @"
#!/bin/sh
set -e
echo $b64Interfaces | base64 -d | sudo -n tee /etc/network/interfaces > /dev/null
echo $b64Resolv | base64 -d | sudo -n tee /etc/resolv.conf > /dev/null
echo APPLY_OK
nohup sudo -n sh -c 'sleep 2; rc-service networking restart' </dev/null >/dev/null 2>&1 &
"@
    $applyScript = $applyScript -replace "`r`n", "`n"
    $b64Apply = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($applyScript))
    Invoke-Ssh -Ip $CurrentIp -RemoteCommand "echo $b64Apply | base64 -d | sh"

    Write-Step "Waiting for VM to return on $staticIp..."
    Start-Sleep -Seconds 5
    $elapsed = 0
    while ($elapsed -lt 90) {
        & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=3 -i $SshKey "dune@$staticIp" "true" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Step "Static IP is active: $staticIp"
            return $staticIp
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    throw "VM did not become reachable on $staticIp."
}

function Detect-PublicIpFromVm {
    param([Parameter(Mandatory)][string]$Ip)

    try {
        $raw = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=8 -i $SshKey "dune@$Ip" "wget -qO- --timeout=5 'https://api.ipify.org' 2>/dev/null" 2>$null
        $out = ($raw | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $out -match '^\d+\.\d+\.\d+\.\d+$') { return $out }
    } catch {
        return $null
    }
    return $null
}

function Write-PlayerIpSetting {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)]$Config
    )

    $publicIp = Detect-PublicIpFromVm -Ip $Ip
    $playerIp = switch ($Config.PlayerIpMode) {
        'Manual' { "$($Config.ManualPlayerIp)".Trim() }
        'Public' { if ($publicIp) { $publicIp } else { $Ip } }
        default { $Ip }
    }
    if (-not $playerIp) { $playerIp = $Ip }

    Write-Step "Writing player connection IP: $playerIp"
    Invoke-Ssh -Ip $Ip -RemoteCommand "printf '\n\n\n$playerIp\n' > /home/dune/.dune/settings.conf"
}

function Upload-Bootstrap {
    param([Parameter(Mandatory)][string]$Ip)

    Assert-ServerPackage

    if (-not (Test-Path $BootstrapSetup)) {
        throw "Bootstrap file not found: $BootstrapSetup"
    }

    Write-Step 'Uploading bootstrap setup script...'
    $setupText = (Get-Content -Raw -LiteralPath $BootstrapSetup) -replace "`r`n", "`n"
    $b64Setup = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($setupText))

    $uploadScript = @"
#!/bin/sh
set -e
echo $b64Setup | base64 -d | sudo -n tee /home/dune/.dune/bin/setup > /dev/null
sudo -n chmod +x /home/dune/.dune/bin/setup
echo UPLOAD_OK
"@
    $uploadScript = $uploadScript -replace "`r`n", "`n"
    $b64Upload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uploadScript))
    Invoke-Ssh -Ip $Ip -RemoteCommand "echo $b64Upload | base64 -d | sh"
}

function Run-FirstTimeSetup {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)]$Config
    )

    $worldName = "$($Config.WorldName)".Trim()
    if (-not $worldName) { $worldName = 'Dune Server' }
    $region = "$($Config.Region)".Trim()
    if (-not $region) { $region = '3' }
    $serverToken = "$($Config.ServerToken)".Trim()
    if (-not $serverToken) {
        throw 'Server token is required for first-time battlegroup setup.'
    }

    Write-Step 'Running first-time battlegroup setup inside the VM. This can take a while...'
    $setupInput = "$worldName`n$region`n$serverToken`n"
    Invoke-SshWithInput -Ip $Ip -RemoteCommand '/home/dune/.dune/bin/setup' -InputText $setupInput -ConnectTimeoutSeconds 30 | Out-Null

    Repair-BattlegroupAfterSetup -Ip $Ip

    if ([int]$Config.MemoryGB -lt 20 -and $Config.EnableSwapWhenLowMemory) {
        Write-Step 'Enabling experimental swap because memory is below 20GB...'
        Invoke-Ssh -Ip $Ip -RemoteCommand "echo yes | /home/dune/.dune/bin/battlegroup enable-experimental-swap" -ConnectTimeoutSeconds 30
    }

    if ($Config.StartBattlegroupAfterSetup) {
        Write-Step 'Starting battlegroup...'
        Invoke-Ssh -Ip $Ip -RemoteCommand '/home/dune/.dune/bin/battlegroup start' -ConnectTimeoutSeconds 30
    }
}

function Invoke-InitialSetup {
    if (-not $ConfigPath) { throw 'InitialSetup requires ConfigPath.' }
    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json

    Write-Step 'Starting automated Dune Awakening setup.'
    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    Write-Step ("Admin session: {0}" -f ($(if (Test-IsAdmin) { 'yes' } else { 'no' })))
    Write-Step ("Hyper-V service: {0}" -f ($(if ($vmms) { "$($vmms.Status) / $($vmms.StartType)" } else { 'missing' })))
    Ensure-VmImported -Config $config
    $setupDestination = Join-Path "$($config.InstallDrive.TrimEnd('\'))\" 'DuneAwakeningServer'
    Start-DuneVm -Destination $setupDestination
    $ip = Wait-DuneVmIp

    if (Test-SshKeyAuth -Ip $ip) {
        Write-Step 'Existing SSH key works.'
    } else {
        Install-SshKeyWithPassword -Ip $ip -Password "$($config.CurrentVmPassword)"
    }

    if (-not (Test-SshKeyAuth -Ip $ip)) {
        throw 'SSH key authentication still does not work after setup.'
    }

    Set-VmPassword -Ip $ip -NewPassword "$($config.NewVmPassword)"
    $ip = Apply-StaticIp -CurrentIp $ip -Config $config
    Write-PlayerIpSetting -Ip $ip -Config $config
    Upload-Bootstrap -Ip $ip
    Run-FirstTimeSetup -Ip $ip -Config $config

    Write-Step 'Automated setup finished.'
}

function Invoke-Battlegroup {
    param([Parameter(Mandatory)][string]$Command)

    $ip = Get-DuneVmIp
    if (-not $ip) { throw 'VM is not running or has no IP address.' }
    Invoke-Ssh -Ip $ip -RemoteCommand "/home/dune/.dune/bin/battlegroup $Command" -ConnectTimeoutSeconds 30
}

function Get-BackupNameFromArchive {
    param([Parameter(Mandatory)][string]$ArchivePath)

    $name = [IO.Path]::GetFileName($ArchivePath)
    if ($name.ToLowerInvariant().EndsWith('.tar.gz')) {
        return $name.Substring(0, $name.Length - 7)
    }
    if ($name.ToLowerInvariant().EndsWith('.tgz')) {
        return $name.Substring(0, $name.Length - 4)
    }
    return [IO.Path]::GetFileNameWithoutExtension($ArchivePath)
}

function Assert-BackupName {
    param([Parameter(Mandatory)][string]$BackupName)

    if ($BackupName -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Backup name contains unsupported characters: $BackupName"
    }
}

function Invoke-SshDownloadArchive {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$RemoteScript,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path $SshKey)) {
        throw "SSH key is missing: $SshKey"
    }

    $stderrPath = Join-Path $env:TEMP ("dune-backup-stderr-" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        $remoteScriptLf = $RemoteScript -replace "`r`n", "`n"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScriptLf))
        $remoteCommand = "printf '%s' '$encoded' | base64 -d | bash"
        $proc = Start-Process -FilePath 'ssh' -ArgumentList @(
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'LogLevel=ERROR',
            '-o', 'ConnectTimeout=30',
            '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes',
            '-o', 'ServerAliveInterval=10',
            '-o', 'ServerAliveCountMax=3',
            '-i', "`"$SshKey`"",
            "dune@$Ip",
            $remoteCommand
        ) -RedirectStandardOutput $DestinationPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru

        $errorText = ''
        if (Test-Path -LiteralPath $stderrPath) {
            $errorText = (Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue).Trim()
        }

        if ($proc.ExitCode -ne 0) {
            if ($errorText) {
                throw "Failed to download backup archive: $errorText"
            }
            throw "Failed to download backup archive. ssh exit code: $($proc.ExitCode)"
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Backup-ServerLocal {
    $ip = Get-DuneVmIp
    if (-not $ip) { throw 'VM is not running or has no IP address.' }
    if (-not (Test-SshKeyAuth -Ip $ip)) {
        throw 'SSH key authentication failed. Run first-time setup or rotate the SSH key first.'
    }

    New-Item -ItemType Directory -Force -Path $BackupsDir | Out-Null
    $backupName = "dunemanager-$(Get-Date -Format 'yyyyMMdd-HHmmss').backup"
    Assert-BackupName -BackupName $backupName

    $localDir = Join-Path $BackupsDir $backupName
    New-Item -ItemType Directory -Force -Path $localDir | Out-Null
    $archivePath = Join-Path $localDir "$backupName.tar.gz"
    $metadataPath = Join-Path $localDir 'metadata.json'

    Write-Step "Creating database backup inside the VM: $backupName"
    Invoke-Ssh -Ip $ip -RemoteCommand "/home/dune/.dune/bin/battlegroup backup '$backupName'" -ConnectTimeoutSeconds 30

    Write-Step 'Downloading database and manager-edited settings to local backup folder...'
    $remoteScript = @'
set -e
backup_name='__BACKUP_NAME__'
ns=$(sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^funcom-seabass-' | head -n1 || true)
if [ -z "$ns" ]; then
  echo "No battlegroup namespace was found." >&2
  exit 2
fi

bg=${ns#funcom-seabass-}
backup_path="/funcom/artifacts/database-dumps/$bg/$backup_name"
if ! sudo test -f "$backup_path"; then
  echo "The backup file was not created: $backup_path" >&2
  exit 3
fi

paths="funcom/artifacts/database-dumps/$bg/$backup_name"
add_if_file() {
  if sudo test -f "$1"; then
    rel="${1#/}"
    paths="$paths $rel"
  fi
}

add_if_file "/funcom/artifacts/database-dumps/$bg/$backup_name.yaml"
add_if_file "/home/dune/.dune/download/scripts/setup/config/UserEngine.ini"
add_if_file "/home/dune/.dune/download/scripts/setup/config/UserGame.ini"

sudo tar -czf - -C / $paths
'@
    $remoteScript = $remoteScript.Replace('__BACKUP_NAME__', $backupName)
    Invoke-SshDownloadArchive -Ip $ip -RemoteScript $remoteScript -DestinationPath $archivePath

    if (-not (Test-Path -LiteralPath $archivePath) -or (Get-Item -LiteralPath $archivePath).Length -lt 1KB) {
        throw 'The local backup archive was not created correctly.'
    }

    [pscustomobject]@{
        CreatedAt = (Get-Date).ToString('o')
        VmIp = $ip
        BackupName = $backupName
        Archive = $archivePath
        Includes = @(
            'database dump',
            'battlegroup YAML when present',
            'UserEngine.ini',
            'UserGame.ini'
        )
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

    Write-Step "Local backup saved: $archivePath"
    Write-Step 'This backup is outside the VM, so it can be restored after a reinstall.'
}

function Restore-ServerLocal {
    if (-not $ConfigPath) { throw 'RestoreBackup requires ConfigPath.' }
    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    $archivePath = "$($config.BackupArchive)"
    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        throw 'No backup archive was selected.'
    }
    if (-not (Test-Path -LiteralPath $archivePath)) {
        throw "Backup archive does not exist: $archivePath"
    }

    $archivePath = (Resolve-Path -LiteralPath $archivePath).Path
    $backupName = Get-BackupNameFromArchive -ArchivePath $archivePath
    Assert-BackupName -BackupName $backupName

    $ip = Get-DuneVmIp
    if (-not $ip) { throw 'VM is not running or has no IP address.' }
    if (-not (Test-SshKeyAuth -Ip $ip)) {
        throw 'SSH key authentication failed. Run first-time setup or rotate the SSH key first.'
    }

    Write-Step "Uploading local backup archive: $archivePath"
    $scpOutput = & scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes -o IdentitiesOnly=yes -i $SshKey $archivePath "dune@${ip}:/tmp/dunemanager-restore.tar.gz" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload backup archive: $($scpOutput -join "`n")"
    }

    Write-Step 'Restoring backup inside the VM. This can take several minutes...'
    $remoteScript = @'
set -e
backup_name='__BACKUP_NAME__'
archive='/tmp/dunemanager-restore.tar.gz'
work='/tmp/dunemanager-restore'

rm -rf "$work"
mkdir -p "$work"
tar -xzf "$archive" -C "$work"

ns=$(sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^funcom-seabass-' | head -n1 || true)
if [ -z "$ns" ]; then
  echo "No battlegroup namespace exists. Run first-time setup before restoring."
  exit 2
fi

bg=${ns#funcom-seabass-}
source_backup=$(find "$work" -type f -name "$backup_name" | head -n1 || true)
if [ -z "$source_backup" ]; then
  echo "Backup database file was not found in the archive: $backup_name"
  exit 3
fi

sudo mkdir -p "/funcom/artifacts/database-dumps/$bg"
sudo cp "$source_backup" "/funcom/artifacts/database-dumps/$bg/$backup_name"
source_yaml=$(find "$work" -type f -name "$backup_name.yaml" | head -n1 || true)
if [ -n "$source_yaml" ]; then
  sudo cp "$source_yaml" "/funcom/artifacts/database-dumps/$bg/$backup_name.yaml"
fi
echo "Database backup staged for battlegroup: $bg"

config_dir='/home/dune/.dune/download/scripts/setup/config'
mkdir -p "$config_dir"
for file in UserEngine.ini UserGame.ini; do
  source_config="$work/home/dune/.dune/download/scripts/setup/config/$file"
  if [ -f "$source_config" ]; then
    cp "$source_config" "$config_dir/$file"
    sudo chown dune:dune "$config_dir/$file" 2>/dev/null || true
    echo "Restored $file"
  fi
done

echo "Stopping battlegroup before database import."
set +e
/home/dune/.dune/bin/battlegroup stop
stop_rc=$?
set -e
if [ "$stop_rc" -ne 0 ]; then
  echo "Stop returned exit code $stop_rc; continuing with import."
fi
sleep 10

echo "Importing database backup. This overwrites the current battlegroup database."
printf 'yes\n' | /home/dune/.dune/bin/battlegroup import "$backup_name"

echo "Applying restored default user settings."
/home/dune/.dune/download/scripts/battlegroup.sh apply-default-usersettings 2>&1 || true

echo "Starting battlegroup after restore."
/home/dune/.dune/bin/battlegroup start
echo "Restore completed."
'@
    $remoteScript = $remoteScript.Replace('__BACKUP_NAME__', $backupName)
    Invoke-SshWithInput -Ip $ip -RemoteCommand 'bash -s' -InputText ($remoteScript -replace "`r`n", "`n") -ConnectTimeoutSeconds 30 | Out-Null
    Write-Step 'Local backup restore finished.'
}

function Export-Logs {
    $ip = Get-DuneVmIp
    if (-not $ip) { throw 'VM is not running or has no IP address.' }

    Invoke-Battlegroup -Command 'logs-export'

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $localDir = Join-Path $env:USERPROFILE "Documents\DuneBattlegroupLogs\Battlegroup_$timestamp"
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null

    Write-Step 'Downloading log bundle...'
    $tarPath = Join-Path $env:TEMP "dune-bg-logs-$timestamp.tar.gz"
    $proc = Start-Process -FilePath 'ssh' -ArgumentList @(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'LogLevel=QUIET',
        '-i', "`"$SshKey`"",
        "dune@$ip",
        'tar -czf - -C /tmp/dune-bg-logs .'
    ) -RedirectStandardOutput $tarPath -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw 'Failed to download log files.'
    }
    tar -xzf $tarPath -C $localDir
    Remove-Item -LiteralPath $tarPath -ErrorAction SilentlyContinue
    Write-Step "Logs saved to $localDir"
}

function Open-FileBrowser {
    $ip = Get-DuneVmIp
    if (-not $ip) { throw 'VM is not running or has no IP address.' }
    Start-Process "http://${ip}:18888/"
    Write-Step "Opened file browser: http://${ip}:18888/"
}

function Open-Director {
    $ip = Get-DuneVmIp
    if (-not $ip) { throw 'VM is not running or has no IP address.' }
    $port = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i $SshKey "dune@$ip" "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}'" 2>&1
    if ($port -notmatch '^\d+$') {
        throw 'Could not determine Director port. Is the battlegroup running?'
    }
    Start-Process "http://${ip}:$($port.Trim())/"
    Write-Step "Opened Director: http://${ip}:$($port.Trim())/"
}

function Invoke-DuneHealth {
    param(
        [bool]$AutoRepair = $false,
        [bool]$KeepRunning = $false
    )

    $vm = Get-DuneVm
    if (-not $vm) {
        throw "VM '$VmName' was not found."
    }

    if ($vm.State -ne 'Running') {
        Write-Step "VM '$VmName' is $($vm.State)."
        if ($KeepRunning -or $AutoRepair) {
            Write-Step 'Starting VM because keep-running repair is enabled.'
            Start-DuneVm
        } else {
            Write-Step 'Health warning: VM is not running.'
            return
        }
    }

    $ip = Get-DuneVmIp
    if (-not $ip) {
        throw 'VM is running but has no IP address.'
    }

    if (-not (Test-SshKeyAuth -Ip $ip)) {
        throw 'SSH key authentication failed. Run first-time setup or rotate the SSH key first.'
    }

    $autoRepairFlag = if ($AutoRepair) { '1' } else { '0' }
    $keepRunningFlag = if ($KeepRunning) { '1' } else { '0' }
    $remoteScript = @'
set +e
auto_repair='__AUTO_REPAIR__'
keep_running='__KEEP_RUNNING__'

ns=$(sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^funcom-seabass-' | head -n1 || true)
if [ -z "$ns" ]; then
  echo "HEALTH_WARN: No battlegroup namespace exists yet."
  exit 0
fi

bg=${ns#funcom-seabass-}
echo "Battlegroup: $bg"
echo "Namespace: $ns"
echo "--- Status ---"
/home/dune/.dune/bin/battlegroup status 2>&1 || true

stopflag=$(sudo kubectl get battlegroup "$bg" -n "$ns" -o jsonpath='{.spec.stop}' 2>/dev/null || true)
phase=$(sudo kubectl get battlegroup "$bg" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
dbphase=$(sudo kubectl get databasedeployment "$bg-db-dbdepl" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
schema=$(sudo kubectl get databasedeployment "$bg-db-dbdepl" -n "$ns" -o jsonpath='{.status.schema}' 2>/dev/null || true)
total_games=$(sudo kubectl get serverstats -n "$ns" --no-headers 2>/dev/null | awk 'NF {n++} END {print n+0}')
ready_games=$(sudo kubectl get serverstats -n "$ns" --no-headers 2>/dev/null | awk '$4=="true" {n++} END {print n+0}')
failed_db_pods=$(sudo kubectl get pods -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null | awk '$1 ~ /db-dbdepl-util/ && ($2=="Failed" || $2=="Error") {print $1}')
bad_pods=$(sudo kubectl get pods -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,REASON:.status.containerStatuses[*].state.waiting.reason 2>/dev/null | awk '$2=="Failed" || $2=="Error" || $3 ~ /CrashLoopBackOff|ImagePullBackOff|ErrImagePull/ {print $1":"$2":"$3}')

echo "Health details: world=$phase stop=$stopflag database=$dbphase schema=${schema:-none} games=$ready_games/$total_games"
if [ -n "$bad_pods" ]; then
  echo "Problem pods:"
  echo "$bad_pods"
fi

repair_count=0
if [ "$auto_repair" = "1" ]; then
  if [ -n "$failed_db_pods" ]; then
    for pod in $failed_db_pods; do
      echo "Repair: deleting failed database schema pod $pod"
      sudo kubectl delete pod "$pod" -n "$ns" --wait=false >/dev/null 2>&1 || true
      repair_count=$((repair_count+1))
    done
  fi

  if [ "$keep_running" = "1" ] && [ "$stopflag" = "true" ]; then
    echo "Repair: battlegroup is stopped; requesting start."
    sudo kubectl patch battlegroup "$bg" -n "$ns" --type=merge -p '{"spec":{"stop":false}}' >/dev/null 2>&1 || true
    repair_count=$((repair_count+1))
  elif [ "$keep_running" = "1" ] && [ "$phase" = "Stopped" ]; then
    echo "Repair: world reports stopped; requesting start."
    /home/dune/.dune/bin/battlegroup start 2>&1 || true
    repair_count=$((repair_count+1))
  fi

  if [ "$repair_count" -gt 0 ]; then
    echo "Repair actions queued: $repair_count"
    sleep 10
    echo "--- Status after repair ---"
    /home/dune/.dune/bin/battlegroup status 2>&1 || true
  else
    echo "Repair: no safe automatic repair was needed."
  fi
fi

if [ "$phase" = "Running" ] && [ "$total_games" -gt 0 ] && [ "$ready_games" -eq "$total_games" ]; then
  echo "HEALTH_OK: World is running and all game servers are ready."
else
  echo "HEALTH_WARN: World is not fully ready yet."
fi
'@

    $remoteScript = $remoteScript.Replace('__AUTO_REPAIR__', $autoRepairFlag).Replace('__KEEP_RUNNING__', $keepRunningFlag)
    Write-Step ("Running health check. Auto repair: {0}; keep running: {1}" -f $AutoRepair, $KeepRunning)
    Invoke-SshWithInput -Ip $ip -RemoteCommand 'bash -s' -InputText ($remoteScript -replace "`r`n", "`n") -ConnectTimeoutSeconds 30 | Out-Null
}

function Invoke-HealthCheck {
    $autoRepair = $false
    $keepRunning = $false
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        $autoRepair = [bool]$config.AutoRepair
        $keepRunning = [bool]$config.KeepRunning
    }
    Invoke-DuneHealth -AutoRepair:$autoRepair -KeepRunning:$keepRunning
}

function Invoke-AutoRepair {
    Invoke-DuneHealth -AutoRepair:$true -KeepRunning:$true
}

function Apply-ServerSettings {
    if (-not $ConfigPath) { throw 'ApplySettings requires ConfigPath.' }
    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json

    $ip = Get-DuneVmIp
    if (-not $ip) { throw 'VM is not running or has no IP address.' }
    if (-not (Test-SshKeyAuth -Ip $ip)) {
        throw 'SSH key authentication failed. Run first-time setup or rotate the SSH key first.'
    }

    $worldTitle = "$($config.WorldTitle)".Trim()
    $displayName = "$($config.ServerDisplayName)".Trim()
    $joinPassword = "$($config.JoinPassword)".Trim()
    $passwordMode = "$($config.PasswordMode)".Trim()
    $pvpMode = "$($config.PvpMode)".Trim()
    $securityZoneMode = "$($config.SecurityZoneMode)".Trim()
    $setMiningMultiplier = [bool]$config.SetMiningMultiplier
    $miningMultiplier = "$($config.MiningMultiplier)".Trim()
    $setPvpResourceMultiplier = [bool]$config.SetPvpResourceMultiplier
    $pvpResourceMultiplier = "$($config.PvpResourceMultiplier)".Trim()
    $setVehicleDurabilityMultiplier = [bool]$config.SetVehicleDurabilityMultiplier
    $vehicleDurabilityMultiplier = "$($config.VehicleDurabilityMultiplier)".Trim()
    $setDeteriorationRate = [bool]$config.SetDeteriorationRate
    $deteriorationRate = "$($config.DeteriorationRate)".Trim()
    $sandstormMode = "$($config.SandstormMode)".Trim()
    $sandstormTreasureMode = "$($config.SandstormTreasureMode)".Trim()
    $coriolisMode = "$($config.CoriolisMode)".Trim()
    $sandwormMode = "$($config.SandwormMode)".Trim()
    $sandwormVehicleCollisionMode = "$($config.SandwormVehicleCollisionMode)".Trim()
    $sandwormDangerZonesMode = "$($config.SandwormDangerZonesMode)".Trim()
    $setSandwormInvulnerability = [bool]$config.SetSandwormInvulnerability
    $sandwormExitInvulnerabilitySeconds = "$($config.SandwormExitInvulnerabilitySeconds)".Trim()
    $sandwormRestartInvulnerabilitySeconds = "$($config.SandwormRestartInvulnerabilitySeconds)".Trim()
    $buildingRestrictionMode = "$($config.BuildingRestrictionMode)".Trim()
    $setBuildingLimits = [bool]$config.SetBuildingLimits
    $landclaimSegments = "$($config.LandclaimSegments)".Trim()
    $blueprintExtensions = "$($config.BlueprintExtensions)".Trim()
    $baseBackupExtensions = "$($config.BaseBackupExtensions)".Trim()
    $restartAfterApply = [bool]$config.RestartAfterApply

    if ($worldTitle -match "[`r`n]") {
        throw 'World title cannot contain new lines.'
    }
    Assert-SafeIniValue -Name 'Server display name' -Value $displayName
    Assert-SafeIniValue -Name 'Join password' -Value $joinPassword

    if ($passwordMode -eq 'Set' -and [string]::IsNullOrWhiteSpace($joinPassword)) {
        throw 'Enter a join password or choose Clear/Keep.'
    }

    if ($setMiningMultiplier) {
        $miningMultiplier = Convert-SettingNumber -Name 'Mining multiplier' -Value $miningMultiplier -Min 0 -Max 10
    }
    if ($setPvpResourceMultiplier) {
        $pvpResourceMultiplier = Convert-SettingNumber -Name 'PvP resource multiplier' -Value $pvpResourceMultiplier -Min 0 -Max 10
    }
    if ($setVehicleDurabilityMultiplier) {
        $vehicleDurabilityMultiplier = Convert-SettingNumber -Name 'Vehicle durability damage multiplier' -Value $vehicleDurabilityMultiplier -Min 0 -Max 10
    }
    if ($setDeteriorationRate) {
        $deteriorationRate = Convert-SettingNumber -Name 'Item deterioration rate' -Value $deteriorationRate -Min 0 -Max 10
    }
    if ($setSandwormInvulnerability) {
        $sandwormExitInvulnerabilitySeconds = Convert-SettingNumber -Name 'Sandworm exit invulnerability seconds' -Value $sandwormExitInvulnerabilitySeconds -Min 0 -Max 99999 -Decimals 0
        $sandwormRestartInvulnerabilitySeconds = Convert-SettingNumber -Name 'Sandworm restart invulnerability seconds' -Value $sandwormRestartInvulnerabilitySeconds -Min 0 -Max 99999 -Decimals 0
    }
    if ($setBuildingLimits) {
        $landclaimSegments = Convert-SettingInt -Name 'Land claim segments' -Value $landclaimSegments -Min 0 -Max 999
        $blueprintExtensions = Convert-SettingInt -Name 'Building blueprint extensions' -Value $blueprintExtensions -Min 0 -Max 999
        $baseBackupExtensions = Convert-SettingInt -Name 'Base backup extensions' -Value $baseBackupExtensions -Min 0 -Max 999
    }

    $applyTitle = if ($worldTitle) { '1' } else { '0' }
    $applyDisplayName = if ($displayName) { '1' } else { '0' }
    $applyPassword = if ($passwordMode -eq 'Set') { '1' } else { '0' }
    $clearPassword = if ($passwordMode -eq 'Clear') { '1' } else { '0' }
    $applyPvp = if ($pvpMode -in @('On', 'Off')) { '1' } else { '0' }
    $pvpValue = if ($pvpMode -eq 'On') { 'True' } else { 'False' }
    $applySecurityZones = if ($securityZoneMode -in @('On', 'Off')) { '1' } else { '0' }
    $securityZoneValue = if ($securityZoneMode -eq 'On') { 'True' } else { 'False' }
    $applyMining = if ($setMiningMultiplier) { '1' } else { '0' }
    $applyPvpResource = if ($setPvpResourceMultiplier) { '1' } else { '0' }
    $applyVehicleDurability = if ($setVehicleDurabilityMultiplier) { '1' } else { '0' }
    $applyDeterioration = if ($setDeteriorationRate) { '1' } else { '0' }
    $applySandstorm = if ($sandstormMode -in @('On', 'Off')) { '1' } else { '0' }
    $sandstormValue = if ($sandstormMode -eq 'On') { '1' } else { '0' }
    $applySandstormTreasure = if ($sandstormTreasureMode -in @('On', 'Off')) { '1' } else { '0' }
    $sandstormTreasureValue = if ($sandstormTreasureMode -eq 'On') { '1' } else { '0' }
    $applyCoriolis = if ($coriolisMode -in @('On', 'Off')) { '1' } else { '0' }
    $coriolisValue = if ($coriolisMode -eq 'On') { 'True' } else { 'False' }
    $applySandworm = if ($sandwormMode -in @('On', 'Off')) { '1' } else { '0' }
    $sandwormValue = if ($sandwormMode -eq 'On') { '1' } else { '0' }
    $applySandwormVehicleCollision = if ($sandwormVehicleCollisionMode -in @('On', 'Off')) { '1' } else { '0' }
    $sandwormVehicleCollisionValue = if ($sandwormVehicleCollisionMode -eq 'On') { 'true' } else { 'false' }
    $applySandwormDangerZones = if ($sandwormDangerZonesMode -in @('On', 'Off')) { '1' } else { '0' }
    $sandwormDangerZonesValue = if ($sandwormDangerZonesMode -eq 'On') { 'true' } else { 'false' }
    $applySandwormInvulnerability = if ($setSandwormInvulnerability) { '1' } else { '0' }
    $applyBuildingRestrictions = if ($buildingRestrictionMode -in @('On', 'Off')) { '1' } else { '0' }
    $buildingRestrictionsValue = if ($buildingRestrictionMode -eq 'On') { 'True' } else { 'False' }
    $applyBuildingLimits = if ($setBuildingLimits) { '1' } else { '0' }
    $restartFlag = if ($restartAfterApply) { '1' } else { '0' }
    $titlePatchB64 = ''
    if ($applyTitle -eq '1') {
        $titlePatchJson = @{ spec = @{ title = $worldTitle } } | ConvertTo-Json -Compress
        $titlePatchB64 = ConvertTo-Base64Utf8 $titlePatchJson
    }

    $remoteScript = @"
set -e

engine='/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
game='/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
stamp=`$(date +%Y%m%d-%H%M%S)

decode() {
  printf '%s' "`$1" | base64 -d
}

set_ini_key() {
  file="`$1"
  section="`$2"
  key="`$3"
  line="`$4"
  tmp=`$(mktemp)
  awk -v section="`$section" -v key="`$key" -v newline="`$line" '
    function clean_key(s) {
      sub(/=.*/, "", s)
      gsub(/^[ \t;]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN { in_section=0; done=0; header="[" section "]" }
    `$0 == header {
      if (in_section && !done) { print newline; done=1 }
      in_section=1
      print
      next
    }
    /^\[/ {
      if (in_section && !done) { print newline; done=1 }
      in_section=0
      print
      next
    }
    in_section && clean_key(`$0) == key {
      if (!done) { print newline; done=1 }
      next
    }
    { print }
    END {
      if (!done) {
        if (!in_section) { print ""; print header }
        print newline
      }
    }
  ' "`$file" > "`$tmp"
  sudo tee "`$file" < "`$tmp" >/dev/null
  rm -f "`$tmp"
}

comment_ini_key() {
  file="`$1"
  section="`$2"
  key="`$3"
  tmp=`$(mktemp)
  awk -v section="`$section" -v key="`$key" '
    function clean_key(s) {
      sub(/=.*/, "", s)
      gsub(/^[ \t;]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN { in_section=0; done=0; header="[" section "]" }
    `$0 == header { in_section=1; print; next }
    /^\[/ { in_section=0; print; next }
    in_section && clean_key(`$0) == key {
      if (!done) { print ";" key "="; done=1 }
      next
    }
    { print }
  ' "`$file" > "`$tmp"
  sudo tee "`$file" < "`$tmp" >/dev/null
  rm -f "`$tmp"
}

sudo cp -a "`$engine" "`$engine.dunemanager-backup-`$stamp"
sudo cp -a "`$game" "`$game.dunemanager-backup-`$stamp"
echo "Backed up UserEngine.ini and UserGame.ini."

if [ "$applyTitle" = "1" ]; then
  ns=`$(sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name | grep '^funcom-seabass-' | head -n1 || true)
  if [ -z "`$ns" ]; then
    echo "No battlegroup namespace found; skipped world title."
  else
    bg=`${ns#funcom-seabass-}
    echo "$titlePatchB64" | base64 -d > /tmp/dunemanager-title-patch.json
    patch=`$(cat /tmp/dunemanager-title-patch.json)
    sudo kubectl patch battlegroup "`$bg" -n "`$ns" --type=merge -p "`$patch" >/dev/null
    rm -f /tmp/dunemanager-title-patch.json
    echo "World title updated."
  fi
fi

if [ "$applyDisplayName" = "1" ]; then
  display_name=`$(decode "$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($displayName)))")
  set_ini_key "`$engine" "ConsoleVariables" "Bgd.ServerDisplayName" "Bgd.ServerDisplayName=\"`$display_name\""
  echo "Server display name updated."
fi

if [ "$applyPassword" = "1" ]; then
  join_password=`$(decode "$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($joinPassword)))")
  set_ini_key "`$engine" "ConsoleVariables" "Bgd.ServerLoginPassword" "Bgd.ServerLoginPassword=\"`$join_password\""
  echo "Join password updated."
elif [ "$clearPassword" = "1" ]; then
  comment_ini_key "`$engine" "ConsoleVariables" "Bgd.ServerLoginPassword"
  echo "Join password cleared."
fi

if [ "$applyPvp" = "1" ]; then
  set_ini_key "`$game" "/Script/DuneSandbox.PvpPveSettings" "m_bShouldForceEnablePvpOnAllPartitions" "m_bShouldForceEnablePvpOnAllPartitions=$pvpValue"
  echo "PvP-all setting updated."
fi

if [ "$applySecurityZones" = "1" ]; then
  set_ini_key "`$game" "/Script/DuneSandbox.SecurityZonesSubsystem" "m_bAreSecurityZonesEnabled" "m_bAreSecurityZonesEnabled=$securityZoneValue"
  echo "Security-zone setting updated."
fi

if [ "$applyMining" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "Dune.GlobalMiningOutputMultiplier" "Dune.GlobalMiningOutputMultiplier=$miningMultiplier"
  set_ini_key "`$engine" "ConsoleVariables" "Dune.GlobalVehicleMiningOutputMultiplier" "Dune.GlobalVehicleMiningOutputMultiplier=$miningMultiplier"
  echo "Mining multipliers updated."
fi

if [ "$applyPvpResource" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "SecurityZones.PvpResourceMultiplier" "SecurityZones.PvpResourceMultiplier=$pvpResourceMultiplier"
  echo "PvP resource multiplier updated."
fi

if [ "$applyVehicleDurability" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "dw.VehicleDurabilityDamageMultiplier" "dw.VehicleDurabilityDamageMultiplier=$vehicleDurabilityMultiplier"
  echo "Vehicle durability damage multiplier updated."
fi

if [ "$applyDeterioration" = "1" ]; then
  set_ini_key "`$game" "/DeteriorationSystem.ItemDeteriorationConstants" "UpdateRateInSeconds" "UpdateRateInSeconds=$deteriorationRate"
  echo "Item deterioration rate updated."
fi

if [ "$applySandstorm" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "Sandstorm.Enabled" "Sandstorm.Enabled=$sandstormValue"
  echo "Sandstorm setting updated."
fi

if [ "$applySandstormTreasure" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "Sandstorm.Treasure.Enabled" "Sandstorm.Treasure.Enabled=$sandstormTreasureValue"
  echo "Sandstorm treasure setting updated."
fi

if [ "$applyCoriolis" = "1" ]; then
  set_ini_key "`$game" "/Script/DuneSandbox.SandStormConfig" "m_bCoriolisAutoSpawnEnabled" "m_bCoriolisAutoSpawnEnabled=$coriolisValue"
  echo "Coriolis storm setting updated."
fi

if [ "$applySandworm" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "sandworm.dune.Enabled" "sandworm.dune.Enabled=$sandwormValue"
  echo "Sandworm setting updated."
fi

if [ "$applySandwormVehicleCollision" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "Vehicle.SandwormCollisionInteraction" "Vehicle.SandwormCollisionInteraction=$sandwormVehicleCollisionValue"
  echo "Sandworm vehicle collision setting updated."
fi

if [ "$applySandwormDangerZones" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "Sandworm.SandwormDangerZonesEnabled" "Sandworm.SandwormDangerZonesEnabled=$sandwormDangerZonesValue"
  echo "Sandworm danger zones setting updated."
fi

if [ "$applySandwormInvulnerability" = "1" ]; then
  set_ini_key "`$engine" "ConsoleVariables" "Vehicle.SandwormInvulnerabilitySecondsOnExit" "Vehicle.SandwormInvulnerabilitySecondsOnExit=$sandwormExitInvulnerabilitySeconds"
  set_ini_key "`$engine" "ConsoleVariables" "Vehicle.SandwormInvulnerabilitySecondsOnServerRestart" "Vehicle.SandwormInvulnerabilitySecondsOnServerRestart=$sandwormRestartInvulnerabilitySeconds"
  echo "Sandworm invulnerability timers updated."
fi

if [ "$applyBuildingRestrictions" = "1" ]; then
  set_ini_key "`$game" "/Script/DuneSandbox.BuildingSettings" "m_bBuildingRestrictionLimitsEnabled" "m_bBuildingRestrictionLimitsEnabled=$buildingRestrictionsValue"
  echo "Building restriction setting updated."
fi

if [ "$applyBuildingLimits" = "1" ]; then
  set_ini_key "`$game" "/Script/DuneSandbox.BuildingSettings" "m_MaxNumLandclaimSegments" "m_MaxNumLandclaimSegments=$landclaimSegments"
  set_ini_key "`$game" "/Script/DuneSandbox.BuildingSettings" "m_BuildingBlueprintMaxExtensions" "m_BuildingBlueprintMaxExtensions=$blueprintExtensions"
  set_ini_key "`$game" "/Script/DuneSandbox.BuildingSettings" "m_BaseBackupMaxExtensions" "m_BaseBackupMaxExtensions=$baseBackupExtensions"
  echo "Building and land-claim limits updated."
fi

echo "Applying settings to the battlegroup."
settings_applied=0
for attempt in 1 2 3; do
  set +e
  /home/dune/.dune/download/scripts/battlegroup.sh apply-default-usersettings
  apply_rc=`$?
  set -e
  if [ "`$apply_rc" -eq 0 ]; then
    settings_applied=1
    echo "Default user settings applied."
    break
  fi
  echo "Default user settings apply failed with exit code `$apply_rc."
  if [ "`$attempt" -lt 3 ]; then
    echo "Waiting before retry `$attempt/3..."
    sleep 10
  fi
done

if [ "`$settings_applied" -ne 1 ]; then
  echo "Warning: settings were written, but Kubernetes could not copy them into the running pods right now."
  echo "Use Apply Settings again, or restart the battlegroup once the pods settle."
fi

if [ "$restartFlag" = "1" ]; then
  echo "Restarting battlegroup so game servers pick up the changes."
  set +e
  /home/dune/.dune/bin/battlegroup restart
  restart_rc=`$?
  set -e
  if [ "`$restart_rc" -ne 0 ]; then
    echo "Warning: restart command failed with exit code `$restart_rc. Try the Restart button after the pods settle."
  fi
else
  echo "Settings applied. Restart the battlegroup later if live servers do not pick them up."
fi

exit 0
"@

    Write-Step 'Applying server settings through SSH...'
    $remoteRunner = 'if command -v timeout >/dev/null 2>&1; then timeout 900 bash -s; else bash -s; fi'
    Invoke-SshWithInput -Ip $ip -RemoteCommand $remoteRunner -InputText ($remoteScript -replace "`r`n", "`n") -ConnectTimeoutSeconds 30 | Out-Null
    Write-Step 'Server settings action finished.'
}

try {
    switch ($Action) {
        'InitialSetup' { Invoke-InitialSetup }
        'StartVm' { Start-DuneVm }
        'StopVm' { Stop-DuneVm }
        'BattlegroupStatus' { Invoke-Battlegroup -Command 'status' }
        'BattlegroupStart' { Invoke-Battlegroup -Command 'start' }
        'BattlegroupRestart' { Invoke-Battlegroup -Command 'restart' }
        'BattlegroupStop' { Invoke-Battlegroup -Command 'stop' }
        'BattlegroupUpdate' { Invoke-Battlegroup -Command 'update' }
        'BattlegroupBackup' { Invoke-Battlegroup -Command 'backup' }
        'LocalBackup' { Backup-ServerLocal }
        'RestoreBackup' { Restore-ServerLocal }
        'ExportLogs' { Export-Logs }
        'OpenFileBrowser' { Open-FileBrowser }
        'OpenDirector' { Open-Director }
        'HealthCheck' { Invoke-HealthCheck }
        'AutoRepair' { Invoke-AutoRepair }
        'ApplySettings' { Apply-ServerSettings }
    }
    exit 0
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($ConfigPath -and (Test-Path $ConfigPath) -and ((Split-Path -Parent $ConfigPath) -eq (Join-Path $PSScriptRoot 'run'))) {
        Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
    }
}
