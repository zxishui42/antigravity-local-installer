param(
    [Parameter(Mandatory=$true)][string]$ScriptRoot,
    [Parameter(Mandatory=$true)][string]$RunRoot,
    [Parameter(Mandatory=$true)][string]$TargetDrive
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Config=Get-Content (Join-Path $ScriptRoot 'pack.json') -Raw | ConvertFrom-Json
$StatusFile=Join-Path $RunRoot 'status.json'
$LogFile=Join-Path $RunRoot 'install.log'
$DetectedRamGb=[Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,0)
$DetectedGpuNames=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
$DetectedNvidiaVramGb=$null
try {
    $nvsmi=(Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue).Source
    if(-not $nvsmi){
        $nvsmi=Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
        if(-not(Test-Path $nvsmi)){$nvsmi=$null}
    }
    if($nvsmi){
        $raw=(& $nvsmi '--query-gpu=memory.total' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1)
        if($raw){
            $mb=[double](([string]$raw).Trim())
            $DetectedNvidiaVramGb=[Math]::Round(($mb/1024),1)
        }
    }
} catch {
    $DetectedNvidiaVramGb=$null
}

function Test-ProfileMatch($Profile){
    if($null -ne $Profile.verified -and -not [bool]$Profile.verified){return $false}
    if($null -ne $Profile.min_ram_gb -and $DetectedRamGb -lt [double]$Profile.min_ram_gb){return $false}
    if($null -ne $Profile.min_vram_gb){
        if($null -eq $DetectedNvidiaVramGb -or [double]$DetectedNvidiaVramGb -lt [double]$Profile.min_vram_gb){return $false}
    }
    $vendor=[string]$Profile.gpu_vendor
    if($vendor -and $vendor.ToLowerInvariant() -ne 'any'){
        if($vendor.ToLowerInvariant() -eq 'cpu-only'){
            $accelerated=@($DetectedGpuNames | Where-Object { $_ -match 'NVIDIA|GeForce|RTX|GTX|AMD|Radeon|Intel.*Arc' })
            if($accelerated.Count -gt 0){return $false}
        } else {
            $pattern=switch($vendor.ToLowerInvariant()){
                'amd' {'AMD|Radeon'}
                'nvidia' {'NVIDIA|GeForce|RTX|GTX'}
                'intel' {'Intel.*Arc'}
                default {[Regex]::Escape($vendor)}
            }
            if(-not(@($DetectedGpuNames | Where-Object { $_ -match $pattern }).Count)){return $false}
        }
    }
    return $true
}

$Profile=@($Config.profiles | Where-Object { Test-ProfileMatch $_ } | Sort-Object @{Expression={[int]$_.priority};Descending=$true} | Select-Object -First 1)[0]
if($null -eq $Profile){
    $gpuText=if($DetectedGpuNames.Count -gt 0){$DetectedGpuNames -join ', '}else{'No graphics adapter name was detected.'}
    $obj=[ordered]@{
        state='error'
        title='No tested setup matches this PC yet'
        message='This installer does not have a verified one-click setup for this computer yet.'
        details=("Detected memory: $DetectedRamGb GB. "+$gpuText)
        progress=0
        time=(Get-Date).ToString('o')
    }
    ($obj|ConvertTo-Json -Compress)|Set-Content $StatusFile -Encoding UTF8
    exit 1
}

$merged=[ordered]@{}
foreach($p in $Config.shared.PSObject.Properties){$merged[$p.Name]=$p.Value}
foreach($p in $Profile.PSObject.Properties){$merged[$p.Name]=$p.Value}
$Pack=[pscustomobject]$merged

$DriveRoot=$TargetDrive.TrimEnd('\') + '\'
$InstallRoot=Join-Path $DriveRoot ('AntigravityLocal\'+[string]$Pack.install_folder)
$ModelRoot=Join-Path $InstallRoot 'models'
$RuntimeRoot=Join-Path $InstallRoot 'runtime'
$PythonRoot=Join-Path $RuntimeRoot 'python'
$PythonExe=Join-Path $PythonRoot 'python.exe'
$StateFile=Join-Path $InstallRoot 'install-state.json'
$PidFile=Join-Path $InstallRoot 'ollama-server.pid'
$PortFile=Join-Path $InstallRoot 'ollama-port.txt'
$PrivatePort=$null
$OllamaHost=$null
$ApiBase=$null

function Log([string]$Text){$stamp=Get-Date -Format 'yyyy-MM-dd HH:mm:ss';Add-Content -Path $LogFile -Value "[$stamp] $Text" -Encoding UTF8}
function Status([string]$Title,[string]$Message,[string]$Details,[int]$Progress=-1,[string]$State='running'){$obj=[ordered]@{state=$State;title=$Title;message=$Message;details=$Details;progress=$Progress;time=(Get-Date).ToString('o')};$tmp=$StatusFile+'.tmp';($obj|ConvertTo-Json -Compress)|Set-Content $tmp -Encoding UTF8;Move-Item -Force $tmp $StatusFile;Log "$Title | $Message | $Details"}
function Fail([string]$Message,[string]$Details){Status 'Installation stopped' $Message $Details 0 'error';exit 1}
function Find-Ollama { $cmd=Get-Command ollama -ErrorAction SilentlyContinue;if($cmd){return $cmd.Source};$c=@((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),(Join-Path $env:ProgramFiles 'Ollama\ollama.exe'));foreach($p in $c){if($p -and (Test-Path $p)){return $p}};return $null }
function FolderBytes([string]$Path){if(-not(Test-Path $Path)){return 0L};try{$sum=(Get-ChildItem $Path -File -Recurse -ErrorAction SilentlyContinue|Measure-Object Length -Sum).Sum;if($null -eq $sum){return 0L};return [long]$sum}catch{return 0L}}
function Format-Bytes([long]$Bytes){if($Bytes -lt 0L){$Bytes=0L};if($Bytes -lt 1GB){return ([Math]::Round(([double]$Bytes/1MB),0).ToString()+' MB')};return ([Math]::Round(([double]$Bytes/1GB),2).ToString()+' GB')}
function Test-PortFree([int]$Port){$listener=$null;try{$listener=New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback),$Port;$listener.Start();return $true}catch{return $false}finally{if($listener){try{$listener.Stop()}catch{}}}}
function Choose-PrivatePort {for($p=[int]$Pack.port_start;$p -le [int]$Pack.port_end;$p++){if(Test-PortFree $p){return $p}};throw 'No private local port is available.'}
function Set-PrivateEndpoint([int]$Port){$script:PrivatePort=$Port;$script:OllamaHost="127.0.0.1:$Port";$script:ApiBase="http://$script:OllamaHost";New-Item -ItemType Directory -Force -Path $InstallRoot|Out-Null;$Port|Set-Content $PortFile -Encoding ASCII}
function Test-PrivateApi { if(-not $ApiBase){return $false};try{$r=Invoke-RestMethod -Uri "$ApiBase/api/version" -TimeoutSec 3;return ($null -ne $r.version)}catch{return $false} }
function Start-PrivateOllama([string]$Exe){
    if(Test-PrivateApi){return}
    New-Item -ItemType Directory -Force -Path $ModelRoot|Out-Null
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$Exe;$psi.Arguments='serve';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.EnvironmentVariables['OLLAMA_HOST']=$OllamaHost
    $psi.EnvironmentVariables['OLLAMA_MODELS']=$ModelRoot
    $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
    $p.Id|Set-Content $PidFile -Encoding ASCII
    for($i=0;$i -lt 30;$i++){Start-Sleep 1;if(Test-PrivateApi){return}}
    try{$p.Kill()}catch{};Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    throw 'The local model service did not start.'
}
function Stop-PrivateOllama {if(Test-Path $PidFile){try{$pidValue=[int](Get-Content $PidFile -ErrorAction Stop);Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue}catch{};Remove-Item $PidFile -Force -ErrorAction SilentlyContinue}}
function PrivateModelExists {try{$tags=Invoke-RestMethod -Uri "$ApiBase/api/tags" -TimeoutSec 8;foreach($m in @($tags.models)){if($m.name -eq $Pack.model -or $m.model -eq $Pack.model){return $true}}}catch{};return $false}
function Get-ManifestBytes { $headers=@{Accept='application/vnd.docker.distribution.manifest.v2+json'};$manifest=Invoke-RestMethod -Uri $Pack.registry_manifest_url -Headers $headers -TimeoutSec 25;$bytes=0L;if($manifest.config.size){$bytes += [long]$manifest.config.size};foreach($layer in @($manifest.layers)){if($layer.size){$bytes += [long]$layer.size}};return [long]$bytes }
function Download-File([string]$Url,[string]$Destination,[string]$Label){for($attempt=1;$attempt -le 2;$attempt++){try{Status $Label 'Downloading a required component.' 'No action is needed.' 28;Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -TimeoutSec 180;return}catch{Log "$Label attempt $attempt failed: $($_.Exception.Message)";if($attempt -lt 2){Start-Sleep 3}}};throw "$Label could not be downloaded."}
function Invoke-NativeLogged([string]$FilePath,[string[]]$ArgList){
    $oldPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $FilePath @ArgList 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value ([string]$_) -Encoding UTF8 }
        $code=$LASTEXITCODE
        if($null -eq $code){$code=0}
        return [int]$code
    } finally {
        $ErrorActionPreference=$oldPreference
    }
}
function Ensure-PythonSiteEnabled {
    $pth=Get-ChildItem $PythonRoot -Filter 'python*._pth' -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $pth){throw 'Portable Python path file was not found.'}
    $lines=Get-Content $pth.FullName
    $changed=$false
    $new=@()
    foreach($line in $lines){
        if($line.Trim() -eq '#import site'){$new += 'import site';$changed=$true}else{$new += $line}
    }
    if($changed){$new | Set-Content $pth.FullName -Encoding ASCII}
}
function Pull-Model([string]$Ollama,[long]$ExpectedBytes){
    for($attempt=1;$attempt -le 2;$attempt++){
        Status 'Downloading the model' 'Downloading the model to the drive you selected.' 'No action is needed.' 45
        $psi=New-Object System.Diagnostics.ProcessStartInfo;$psi.FileName=$Ollama;$psi.Arguments="pull $($Pack.model)";$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$false;$psi.RedirectStandardError=$false;$psi.EnvironmentVariables['OLLAMA_HOST']=$OllamaHost;$psi.EnvironmentVariables['OLLAMA_MODELS']=$ModelRoot
        $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
        $last=[long](FolderBytes $ModelRoot);$lastChange=Get-Date
        while(-not $p.HasExited){
            Start-Sleep 2
            $now=[long](FolderBytes $ModelRoot);if($now -ne $last){$last=$now;$lastChange=Get-Date}
            $shown=Format-Bytes $now;$progressValue=45
            if($ExpectedBytes -gt 0L){$ratio=[double]$now/[double]$ExpectedBytes;if($ratio -lt 0){$ratio=0};if($ratio -gt 1){$ratio=1};$progressValue=[int](45+($ratio*15))}
            Status 'Downloading the model' "Downloaded about $shown so far." "Saving to $DriveRoot" $progressValue
            if(((Get-Date)-$lastChange).TotalSeconds -gt [int]$Pack.download_stall_seconds){try{$p.Kill()}catch{};try{$p.WaitForExit(5000)|Out-Null}catch{};Log "Download stalled for $($Pack.download_stall_seconds) seconds.";break}
        }
        if($p.HasExited -and $p.ExitCode -eq 0){return}
        if($attempt -lt 2){Status 'Retrying the download' 'The first download attempt stopped responding.' 'Retrying automatically. No action is needed.' 45;Start-Sleep 3}
    }
    throw 'The model download did not finish after two attempts.'
}
function Ensure-PortablePython {
    Status 'Preparing Antigravity' 'Setting up the private runtime.' "Saving to $DriveRoot" 30
    $needsPython=$true
    if(Test-Path $PythonExe){
        $code=Invoke-NativeLogged $PythonExe @('--version')
        if($code -eq 0){$needsPython=$false}else{Log 'Existing private Python is incomplete. Rebuilding it.';Remove-Item $PythonRoot -Recurse -Force -ErrorAction SilentlyContinue}
    }
    if($needsPython){
        New-Item -ItemType Directory -Force -Path $PythonRoot|Out-Null
        $zip=Join-Path $RunRoot 'python.zip'
        Download-File $Pack.python_embed_url $zip 'Preparing Antigravity'
        try{Expand-Archive $zip $PythonRoot -Force}catch{Remove-Item $PythonRoot -Recurse -Force -ErrorAction SilentlyContinue;throw 'The private Python archive could not be unpacked.'}
    }
    Ensure-PythonSiteEnabled
    $pipCode=Invoke-NativeLogged $PythonExe @('-m','pip','--version')
    if($pipCode -ne 0){
        $getpip=Join-Path $RunRoot 'get-pip.py'
        Download-File 'https://bootstrap.pypa.io/get-pip.py' $getpip 'Preparing Antigravity'
        $pipInstallCode=Invoke-NativeLogged $PythonExe @($getpip,'--disable-pip-version-check')
        if($pipInstallCode -ne 0){throw 'The private Python runtime could not install pip.'}
        $pipCode=Invoke-NativeLogged $PythonExe @('-m','pip','--version')
        if($pipCode -ne 0){throw 'pip was installed but could not be started.'}
    }
}
function Install-Antigravity {
    Status 'Preparing Antigravity' 'Installing Antigravity in the private runtime.' 'No system Python settings are changed.' 38
    $package="google-antigravity==$($Pack.antigravity_version)"
    $code=Invoke-NativeLogged $PythonExe @('-m','pip','install','--disable-pip-version-check','--no-input','--no-warn-script-location',$package)
    if($code -ne 0){throw 'The Antigravity SDK could not be installed.'}
    $verifyFile=Join-Path $RunRoot 'verify_sdk.py'
    @'
from google.antigravity import Agent, LocalOpenAIAgentConfig
print("antigravity import ok")
'@ | Set-Content $verifyFile -Encoding UTF8
    $verify=Invoke-NativeLogged $PythonExe @($verifyFile)
    if($verify -ne 0){throw 'The Antigravity SDK was installed but could not be imported.'}
}
function Write-AgentFile { $template=Get-Content (Join-Path $ScriptRoot 'local_agent.py') -Raw;$content=$template.Replace('__MODEL__',[string]$Pack.model).Replace('__BASE_URL__',"http://$OllamaHost/v1");Set-Content (Join-Path $InstallRoot 'local_agent.py') $content -Encoding UTF8 }
function Test-Model {Status 'Testing the setup' 'Starting the model and checking that it answers.' 'No action is needed.' 84;$body=@{model=$Pack.model;prompt='Reply with only: OK';stream=$false;keep_alive='5m'}|ConvertTo-Json;$result=Invoke-RestMethod -Uri "$ApiBase/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 240;if(-not$result.response){throw 'The model did not return a response.'};$ps=Invoke-RestMethod -Uri "$ApiBase/api/ps" -TimeoutSec 10;$m=$ps.models|Where-Object{$_.name -like ($Pack.model+'*') -or $_.model -like ($Pack.model+'*')}|Select-Object -First 1;$v=0L;if($m){try{$v=[long]$m.size_vram}catch{}};return $v}
function Test-Antigravity {
    Status 'Testing Antigravity' 'Checking the connection to the local model.' 'No action is needed.' 92
    $outFile=Join-Path $RunRoot 'agent-test.out'
    $errFile=Join-Path $RunRoot 'agent-test.err'
    $codeFile=Join-Path $RunRoot 'agent-test.code'
    $wrapperFile=Join-Path $RunRoot 'agent-test-wrapper.ps1'
    Remove-Item $outFile,$errFile,$codeFile,$wrapperFile -Force -ErrorAction SilentlyContinue

    $pythonLiteral=$PythonExe.Replace("'","''")
    $agentLiteral=(Join-Path $InstallRoot 'local_agent.py').Replace("'","''")
    $outLiteral=$outFile.Replace("'","''")
    $errLiteral=$errFile.Replace("'","''")
    $codeLiteral=$codeFile.Replace("'","''")
    @"
`$ErrorActionPreference='Continue'
& '$pythonLiteral' '$agentLiteral' 1> '$outLiteral' 2> '$errLiteral'
`$nativeCode=`$LASTEXITCODE
if(`$null -eq `$nativeCode){`$nativeCode=0}
Set-Content -LiteralPath '$codeLiteral' -Value ([string]`$nativeCode) -Encoding ASCII
exit `$nativeCode
"@ | Set-Content $wrapperFile -Encoding UTF8

    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$wrapperFile) -WindowStyle Hidden -PassThru
    if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};throw 'Antigravity connection test timed out.'}

    $o=if(Test-Path $outFile){Get-Content $outFile -Raw}else{''}
    $e=if(Test-Path $errFile){Get-Content $errFile -Raw}else{''}
    $exitCode=$null
    if(Test-Path $codeFile){
        $rawCode=(Get-Content $codeFile -Raw).Trim()
        if($rawCode -match '^-?\d+$'){$exitCode=[int]$rawCode}
    }
    Log "Antigravity output: $o"
    if($e){Log "Antigravity stderr: $e"}
    Log "Antigravity child exit code: $exitCode"
    if($null -eq $exitCode -or $exitCode -ne 0){throw 'Antigravity could not connect to the model.'}
    if([string]::IsNullOrWhiteSpace($o)){throw 'Antigravity returned no output.'}
}
function Write-UserLauncher([string]$OllamaExe){
    $appSource=Join-Path $ScriptRoot 'AntigravityLocal.exe'
    if(-not(Test-Path $appSource)){throw 'The installed app executable is missing from this package.'}

    $appPath=Join-Path $InstallRoot 'AntigravityLocal.exe'
    Copy-Item -LiteralPath $appSource -Destination $appPath -Force

    $shell=New-Object -ComObject WScript.Shell
    $desktop=[Environment]::GetFolderPath('Desktop')
    $shortcut=$shell.CreateShortcut((Join-Path $desktop 'Antigravity Installation Test.lnk'))
    $shortcut.TargetPath=$appPath
    $shortcut.WorkingDirectory=$InstallRoot
    $shortcut.Save()
}

function Register-Uninstaller {
    $uninstallDir=Join-Path $env:LOCALAPPDATA ('AntigravityLocal\Uninstallers\'+[string]$Pack.install_folder);New-Item -ItemType Directory -Force -Path $uninstallDir|Out-Null
    $uninstallKeyName='AntigravityLocal-'+[string]$Pack.install_folder
    $uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$uninstallKeyName
$un=@"
param()
Add-Type -AssemblyName System.Windows.Forms
\`$root='$($InstallRoot.Replace("'","''"))'
\`$desktop=[Environment]::GetFolderPath('Desktop')
\`$a=[System.Windows.Forms.MessageBox]::Show('Remove Antigravity Local and its private model files?','Uninstall Antigravity Local','YesNo','Question');if(\`$a -ne 'Yes'){exit}
\`$pidFile=Join-Path \`$root 'ollama-server.pid';if(Test-Path \`$pidFile){try{\`$pidValue=[int](Get-Content \`$pidFile);Stop-Process -Id \`$pidValue -Force -ErrorAction SilentlyContinue}catch{}}
Remove-Item (Join-Path `$desktop 'Antigravity Installation Test.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path `$desktop 'Antigravity Local.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item \`$root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item '$($uninstallKey.Replace("'","''"))' -Recurse -Force -ErrorAction SilentlyContinue
[System.Windows.Forms.MessageBox]::Show('Antigravity Local was removed.','Uninstall Antigravity Local')|Out-Null
"@
    $unPath=Join-Path $uninstallDir 'uninstall.ps1';Set-Content $unPath $un -Encoding UTF8
    $key=$uninstallKey
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayName' -Value ('Antigravity Local - '+[string]$Pack.model_label) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'Publisher' -Value 'Antigravity Local Models' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayVersion' -Value ([string]$Pack.version) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'InstallLocation' -Value $InstallRoot -PropertyType String -Force | Out-Null
    $uninstallCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $unPath + '"'
    New-ItemProperty -Path $key -Name 'UninstallString' -Value $uninstallCommand -PropertyType String -Force | Out-Null
}

try {
    Status 'Checking this PC' 'Checking Windows, memory, storage, and network.' ("Selected tested setup: "+[string]$Pack.model_label+" via "+[string]$Pack.route+".") 8
    if(-not[Environment]::Is64BitOperatingSystem){Fail 'This package needs 64-bit Windows.' 'Choose a compatible package.'}
    $os=Get-CimInstance Win32_OperatingSystem;if([int]$os.BuildNumber -lt [int]$Pack.min_windows_build){Fail 'This Windows version is too old for the current local runtime.' "Windows build $($Pack.min_windows_build) or newer is required."}
    $ram=$DetectedRamGb;if($ram -lt [int]$Pack.min_ram_gb){Fail 'This PC does not have enough memory.' "Detected: $ram GB. Required: at least $($Pack.min_ram_gb) GB."}
    $driveName=$TargetDrive.TrimEnd(':');$drive=Get-PSDrive -Name $driveName -ErrorAction Stop
    $manifestBytes=0L;try{$manifestBytes=Get-ManifestBytes}catch{$manifestBytes=[long](([double]$Pack.fallback_required_gb-[double]$Pack.app_overhead_gb)*1GB)}
    $totalTargetBytes=[long]($manifestBytes+([double]$Pack.app_overhead_gb*1GB));$existingBytes=[long](FolderBytes $InstallRoot);$additionalBytes=[long]($totalTargetBytes-$existingBytes);if($additionalBytes -lt 512MB){$additionalBytes=512MB}
    $needed=[Math]::Round(([double]$additionalBytes/1GB),1);$free=[Math]::Round(([double]$drive.Free/1GB),1);Status 'Checking storage' "About $needed GB more is needed on $TargetDrive." "$free GB is free on the selected drive." 12;if([double]$free -lt [double]$needed){Fail 'There is not enough space on the selected drive.' "$TargetDrive has $free GB free. This attempt needs about $needed GB more. Choose another drive or free some space."}
    try{Get-ManifestBytes|Out-Null;Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Pack.python_embed_url -TimeoutSec 20|Out-Null;Invoke-WebRequest -UseBasicParsing -Method Head -Uri 'https://pypi.org/simple/google-antigravity/' -TimeoutSec 20|Out-Null}catch{Fail 'A required download server could not be reached.' 'Check the internet connection, VPN, or proxy, then try again.'}
    New-Item -ItemType Directory -Force -Path $InstallRoot|Out-Null
    $ollama=Find-Ollama
    if(-not$ollama){Status 'Installing Ollama' 'Installing the local model runtime.' 'The large model files will still be saved to the drive you selected.' 20;$installScript=Join-Path $RunRoot 'ollama-install.ps1';Download-File 'https://ollama.com/install.ps1' $installScript 'Installing Ollama';$ollamaInstallCode=Invoke-NativeLogged 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$installScript);if($ollamaInstallCode -ne 0){throw 'Ollama could not be installed.'};Start-Sleep 2;$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$ollama=Find-Ollama;if(-not$ollama){throw 'Ollama was installed but ollama.exe was not found.'}}else{Status 'Checking Ollama' 'Using the Ollama program already on this PC.' 'Its existing models are left alone.' 20}
    Log ('Ollama executable: '+$ollama)
    Ensure-PortablePython;Install-Antigravity
    Set-PrivateEndpoint (Choose-PrivatePort);Start-PrivateOllama $ollama
    if(-not(PrivateModelExists)){Pull-Model $ollama $manifestBytes}else{Status 'Model found' 'The model is already present in this private setup.' 'No download is needed.' 60}
    Write-AgentFile;$vram=Test-Model;Test-Antigravity;Write-UserLauncher $ollama;Register-Uninstaller
    $state=[ordered]@{pack=$Pack.id;profile=$Pack.id;model=$Pack.model;model_label=$Pack.model_label;installed=(Get-Date).ToString('o');install_root=$InstallRoot;model_root=$ModelRoot;ollama=$ollama;port=$PrivatePort;size_vram=$vram};$state|ConvertTo-Json|Set-Content $StateFile -Encoding UTF8
    Stop-PrivateOllama
    $accel=if($vram -gt 0){'GPU acceleration was detected.'}else{'The setup works. GPU acceleration was not detected in this test, so it may run more slowly.'}
    Status 'Installation complete' 'The local setup is ready.' ("Installed setup: "+[string]$Pack.model_label+". "+$accel+" Files are stored on "+$TargetDrive+". Use the Installation Test shortcut to verify it again later.") 100 'success'
} catch {
    Log ('ERROR: '+$_.Exception.ToString());Stop-PrivateOllama;Fail 'The installation could not continue.' 'No manual commands are required. Click Copy details to send the technical log to support.'
}
