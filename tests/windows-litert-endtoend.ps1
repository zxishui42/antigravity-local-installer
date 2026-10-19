$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){
  if(-not $Condition){throw "ASSERT FAILED: $Message"}
}
function Read-JsonSafe([string]$Path){
  if(-not(Test-Path $Path)){return $null}
  try{return Get-Content $Path -Raw | ConvertFrom-Json}catch{return $null}
}

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$prepared=Join-Path $repoRoot '.buildsrc'
if(-not(Test-Path $prepared)){& (Join-Path $repoRoot 'build\prepare.ps1')}
if(-not(Test-Path (Join-Path $prepared '_internal\AntigravityLocal.exe'))){& (Join-Path $repoRoot 'build\build-app.ps1')}

$pkg=Join-Path $env:RUNNER_TEMP 'ag-litert-e2e-package'
Remove-Item $pkg -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item $prepared $pkg -Recurse -Force

$packPath=Join-Path $pkg '_internal\pack.json'
$config=Get-Content $packPath -Raw | ConvertFrom-Json
$profile=@($config.profiles | Where-Object { [string]$_.id -eq 'ci-windows-litert-gemma4-e2b-cpu' } | Select-Object -First 1)[0]
Assert-True ($null -ne $profile) 'LiteRT CI profile is missing.'
$profile.verified=$true
$profile.verification_status='temporary_ci_execution'
$config.profiles=@($profile)
$config.shared.download_stall_seconds=300
$config | ConvertTo-Json -Depth 12 | Set-Content $packPath -Encoding UTF8

$installRoot='D:\AntigravityLocal\ci-litert-gemma4-e2b'
Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityLocal-ci-litert-gemma4-e2b' -Recurse -Force -ErrorAction SilentlyContinue
$desktop=[Environment]::GetFolderPath('Desktop')
$shortcut=Join-Path $desktop 'Antigravity Installation Test.lnk'
Remove-Item $shortcut -Force -ErrorAction SilentlyContinue

$runRoot=Join-Path $env:RUNNER_TEMP 'ag-litert-e2e-run'
Remove-Item $runRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

$worker=Join-Path $pkg '_internal\worker.ps1'
Write-Host 'A) Run the production worker through the LiteRT route'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $worker -ScriptRoot (Join-Path $pkg '_internal') -RunRoot $runRoot -TargetDrive 'D:'
$code=$LASTEXITCODE
if(Test-Path (Join-Path $runRoot 'install.log')){Get-Content (Join-Path $runRoot 'install.log') | Select-Object -Last 80 | ForEach-Object { Write-Host $_ }}
Assert-True ($code -eq 0) "LiteRT worker returned exit code $code"

$status=Read-JsonSafe (Join-Path $runRoot 'status.json')
Assert-True ($status -and $status.state -eq 'success') 'LiteRT install did not finish successfully.'
$state=Read-JsonSafe (Join-Path $installRoot 'install-state.json')
Assert-True ($state -and $state.route -eq 'LiteRT') 'Installed state did not record the LiteRT route.'
Assert-True ($state.litert_backend -eq 'cpu') 'Installed state did not preserve the CI LiteRT backend.'
Assert-True (Test-Path ([string]$state.model_path)) 'LiteRT model file is missing after install.'
Assert-True (Test-Path (Join-Path $installRoot 'litert_agent.py')) 'Installed LiteRT agent is missing.'
Assert-True (Test-Path (Join-Path $installRoot 'AntigravityLocal.exe')) 'Installed test app is missing.'
Assert-True (Test-Path $shortcut) 'LiteRT installation test shortcut is missing.'

Write-Host 'B) Run the installed application through the same LiteRT model path'
$app=Join-Path $installRoot 'AntigravityLocal.exe'
$p=Start-Process -FilePath $app -ArgumentList '--self-test' -PassThru
if(-not $p.WaitForExit(900000)){try{$p.Kill()}catch{};throw 'Installed LiteRT app self-test timed out.'}
Assert-True ($p.ExitCode -eq 0) "Installed LiteRT app self-test returned exit code $($p.ExitCode)"
Write-Host 'WINDOWS LITERT PRODUCTION-PATH E2E PASSED'

Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AntigravityLocal-ci-litert-gemma4-e2b' -Recurse -Force -ErrorAction SilentlyContinue
