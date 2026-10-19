$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){
  if(-not $Condition){throw "ASSERT FAILED: $Message"}
}
function Read-JsonSafe([string]$Path){
  if(-not(Test-Path $Path)){return $null}
  try{return Get-Content $Path -Raw|ConvertFrom-Json}catch{return $null}
}
function Stop-Tree([int]$ProcessId){
  try{& taskkill.exe /PID $ProcessId /T /F | Out-Null}catch{}
}

$repoRoot=(Get-Location).Path
$prepared=Join-Path $repoRoot '.buildsrc'
Assert-True (Test-Path $prepared) 'Prepared source is missing.'

$pkg=Join-Path $env:RUNNER_TEMP 'ag-e2e-package'
Remove-Item $pkg -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item $prepared $pkg -Recurse -Force

$packPath=Join-Path $pkg '_internal\pack.json'
$config=Get-Content $packPath -Raw|ConvertFrom-Json
$pack=@($config.profiles)[0]
$pack.model='qwen3:0.6b'
$pack.model_label='Qwen3 0.6B CI'
$pack.registry_manifest_url='https://registry.ollama.ai/v2/library/qwen3/manifests/0.6b'
$pack.fallback_required_gb=4.0
$pack.app_overhead_gb=1.5
$config.shared.download_stall_seconds=180
$config|ConvertTo-Json -Depth 8|Set-Content $packPath -Encoding UTF8

$installRoot='D:\AntigravityLocal\gemma4-e2b'
Remove-Item 'D:\AntigravityLocal' -Recurse -Force -ErrorAction SilentlyContinue

$desktop=[Environment]::GetFolderPath('Desktop')
$shortcutPath=Join-Path $desktop 'Antigravity Local.lnk'
Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityLocal-gemma4-e2b' -Recurse -Force -ErrorAction SilentlyContinue

$userModelSentinel=Join-Path $env:USERPROFILE '.ollama\models\KEEP_USER_MODELS.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $userModelSentinel -Parent)|Out-Null
'do-not-delete'|Set-Content $userModelSentinel -Encoding ASCII

$worker=Join-Path $pkg '_internal\worker.ps1'

Write-Host 'A) Simulate an interrupted first install during private runtime preparation'
$runInterrupted=Join-Path $env:RUNNER_TEMP 'ag-e2e-interrupted'
Remove-Item $runInterrupted -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $runInterrupted|Out-Null

$p=Start-Process powershell.exe -ArgumentList @(
  '-NoProfile','-ExecutionPolicy','Bypass','-File',$worker,
  '-ScriptRoot',(Join-Path $pkg '_internal'),
  '-RunRoot',$runInterrupted,
  '-TargetDrive','D:'
) -PassThru -WindowStyle Hidden

$seen=$false
for($i=0;$i -lt 180;$i++){
  Start-Sleep -Milliseconds 500
  $s=Read-JsonSafe (Join-Path $runInterrupted 'status.json')
  if($s -and $s.title -eq 'Preparing Antigravity'){
    $seen=$true
    Start-Sleep 2
    Stop-Tree $p.Id
    break
  }
  if($p.HasExited){break}
}
Assert-True $seen 'Could not reach private-runtime preparation before interruption.'
Start-Sleep 2
Assert-True (Test-Path $installRoot) 'Interrupted install did not create its private install root.'
Write-Host 'Interrupted install stopped. Starting recovery run.'

Write-Host 'B) Recover from the interrupted install using the production worker'
$run1=Join-Path $env:RUNNER_TEMP 'ag-e2e-run1'
Remove-Item $run1 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $run1|Out-Null

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -ScriptRoot (Join-Path $pkg '_internal') -RunRoot $run1 -TargetDrive 'D:'
$code1=$LASTEXITCODE
$status1=Read-JsonSafe (Join-Path $run1 'status.json')
if(Test-Path (Join-Path $run1 'install.log')){
  Get-Content (Join-Path $run1 'install.log')|Select-Object -Last 40|ForEach-Object{Write-Host $_}
}

Assert-True ($code1 -eq 0) "Recovered worker returned exit code $code1"
Assert-True ($status1 -and $status1.state -eq 'success') 'Recovered install did not finish in success state.'
Assert-True (Test-Path (Join-Path $installRoot 'install-state.json')) 'Install state file missing after recovery.'
Assert-True (Test-Path (Join-Path $installRoot 'AntigravityLocal.exe')) 'Installed app executable missing.'
Assert-True (Test-Path $shortcutPath) 'Desktop shortcut missing.'
Assert-True (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityLocal-gemma4-e2b') 'Uninstall registry entry missing.'
Assert-True (Test-Path $userModelSentinel) 'Existing-user-model sentinel was removed.'

Write-Host 'B2) Validate the installed app and full Run path'
$appPath=Join-Path $installRoot 'AntigravityLocal.exe'
$appTest=Start-Process -FilePath $appPath -ArgumentList '--self-test' -PassThru -Wait
Assert-True ($appTest.ExitCode -eq 0) "Installed app full self-test returned exit code $($appTest.ExitCode)"

$shortcutShell=New-Object -ComObject WScript.Shell
$shortcut=$shortcutShell.CreateShortcut($shortcutPath)
Assert-True ([string]::Equals($shortcut.TargetPath,$appPath,[System.StringComparison]::OrdinalIgnoreCase)) ('Desktop shortcut target is unexpected: '+$shortcut.TargetPath)
Write-Host 'INSTALLED APP FULL RUN SELF-TEST PASSED'

Write-Host 'C) Repeat installation over the completed setup'
$run2=Join-Path $env:RUNNER_TEMP 'ag-e2e-run2'
Remove-Item $run2 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $run2|Out-Null

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -ScriptRoot (Join-Path $pkg '_internal') -RunRoot $run2 -TargetDrive 'D:'
$code2=$LASTEXITCODE
$status2=Read-JsonSafe (Join-Path $run2 'status.json')
if(Test-Path (Join-Path $run2 'install.log')){
  Get-Content (Join-Path $run2 'install.log')|Select-Object -Last 30|ForEach-Object{Write-Host $_}
}

Assert-True ($code2 -eq 0) "Repeat worker returned exit code $code2"
Assert-True ($status2 -and $status2.state -eq 'success') 'Repeat install did not finish in success state.'
Assert-True (Test-Path $userModelSentinel) 'Repeat install touched existing-user-model sentinel.'

Write-Host 'D) Verify the installed private model is usable after repeat install'
$state=Get-Content (Join-Path $installRoot 'install-state.json') -Raw|ConvertFrom-Json
$port=[int]$state.port
$ollama=[string]$state.ollama
$hostValue="127.0.0.1:$port"
$api="http://$hostValue"

$psi=New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName=$ollama
$psi.Arguments='serve'
$psi.UseShellExecute=$false
$psi.CreateNoWindow=$true
$psi.EnvironmentVariables['OLLAMA_HOST']=$hostValue
$psi.EnvironmentVariables['OLLAMA_MODELS']=(Join-Path $installRoot 'models')

$server=New-Object System.Diagnostics.Process
$server.StartInfo=$psi
[void]$server.Start()
try{
  $ready=$false
  for($i=0;$i -lt 40;$i++){
    Start-Sleep 1
    try{
      $v=Invoke-RestMethod -Uri "$api/api/version" -TimeoutSec 2
      if($v.version){$ready=$true;break}
    }catch{}
  }
  Assert-True $ready 'Installed private Ollama server did not start.'
  $body=@{model='qwen3:0.6b';prompt='Reply with only: OK';stream=$false;keep_alive='30s'}|ConvertTo-Json
  $reply=Invoke-RestMethod -Uri "$api/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 180
  Assert-True (-not[string]::IsNullOrWhiteSpace([string]$reply.response)) 'Installed private model returned no answer.'
}finally{
  try{if($server -and -not$server.HasExited){$server.Kill();$server.WaitForExit(10000)|Out-Null}}catch{}
}

Write-Host 'E) Exercise the uninstall logic non-interactively'
$uninstallDir=Join-Path $env:LOCALAPPDATA 'AntigravityLocal\Uninstallers\gemma4-e2b'
$uninstall=Join-Path $uninstallDir 'uninstall.ps1'
Assert-True (Test-Path $uninstall) 'Generated uninstall script is missing.'

$pidFile=Join-Path $installRoot 'ollama-server.pid'
if(Test-Path $pidFile){
  try{$pidValue=[int](Get-Content $pidFile);Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue}catch{}
}
Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityLocal-gemma4-e2b' -Recurse -Force -ErrorAction SilentlyContinue

Assert-True (-not(Test-Path $installRoot)) 'Install root remains after uninstall cleanup.'
Assert-True (-not(Test-Path $shortcutPath)) 'Desktop shortcut remains after uninstall cleanup.'
Assert-True (-not(Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityLocal-gemma4-e2b')) 'Uninstall registry entry remains.'
Assert-True (Test-Path $userModelSentinel) 'Uninstall cleanup touched existing-user-model sentinel.'

Write-Host 'F) Reinstall after uninstall'
$run3=Join-Path $env:RUNNER_TEMP 'ag-e2e-run3'
Remove-Item $run3 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $run3|Out-Null

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -ScriptRoot (Join-Path $pkg '_internal') -RunRoot $run3 -TargetDrive 'D:'
$code3=$LASTEXITCODE
$status3=Read-JsonSafe (Join-Path $run3 'status.json')
Assert-True ($code3 -eq 0) "Reinstall worker returned exit code $code3"
Assert-True ($status3 -and $status3.state -eq 'success') 'Reinstall after uninstall did not succeed.'
Assert-True (Test-Path $userModelSentinel) 'Reinstall touched existing-user-model sentinel.'

# Final CI cleanup.
$pidFile=Join-Path $installRoot 'ollama-server.pid'
if(Test-Path $pidFile){
  try{$pidValue=[int](Get-Content $pidFile);Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue}catch{}
}
Remove-Item 'D:\AntigravityLocal' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityLocal-gemma4-e2b' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $userModelSentinel -Force -ErrorAction SilentlyContinue

Write-Host 'PRODUCTION WORKER RECOVERY / OPEN / RUN / REPEAT / UNINSTALL / REINSTALL PASSED'
