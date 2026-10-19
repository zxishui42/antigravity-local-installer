$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){
  if(-not $Condition){throw "ASSERT FAILED: $Message"}
}

$repoRoot=(Get-Location).Path
$src=Join-Path $repoRoot '.buildsrc'
if(-not(Test-Path $src)){& (Join-Path $repoRoot 'build\prepare.ps1')}
$pack=Get-Content (Join-Path $src '_internal\pack.json') -Raw|ConvertFrom-Json
$venv=Join-Path $env:RUNNER_TEMP 'ag-ci-venv'
$py=Join-Path $venv 'Scripts\python.exe'
Assert-True (Test-Path $py) 'Regression job did not leave the Antigravity test venv.'

Write-Host 'A) Install/find Ollama using the same public installer route used by production'
$ollama=(Get-Command ollama -ErrorAction SilentlyContinue).Source
if(-not $ollama){
  $installScript=Join-Path $env:RUNNER_TEMP 'ollama-install.ps1'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://ollama.com/install.ps1' -OutFile $installScript -TimeoutSec 120
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
  if($LASTEXITCODE -ne 0){throw "Ollama installer returned $LASTEXITCODE"}
  $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')
  $ollama=(Get-Command ollama -ErrorAction SilentlyContinue).Source
}
if(-not $ollama){
  $candidate=Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
  if(Test-Path $candidate){$ollama=$candidate}
}
Assert-True ([bool]$ollama) 'ollama.exe could not be found after installation.'
& $ollama --version

Write-Host 'B) Start isolated Ollama server'
$port=11435
$hostValue="127.0.0.1:$port"
$api="http://$hostValue"
$modelRoot=Join-Path $env:RUNNER_TEMP 'ag-ci-models'
Remove-Item $modelRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $modelRoot|Out-Null
$psi=New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName=$ollama
$psi.Arguments='serve'
$psi.UseShellExecute=$false
$psi.CreateNoWindow=$true
$psi.EnvironmentVariables['OLLAMA_HOST']=$hostValue
$psi.EnvironmentVariables['OLLAMA_MODELS']=$modelRoot
$server=New-Object System.Diagnostics.Process
$server.StartInfo=$psi
[void]$server.Start()
try{
  $ready=$false
  for($i=0;$i -lt 45;$i++){
    Start-Sleep 1
    try{$v=Invoke-RestMethod -Uri "$api/api/version" -TimeoutSec 2;if($v.version){$ready=$true;break}}catch{}
  }
  Assert-True $ready 'Isolated Ollama server did not become ready.'

  Write-Host 'C) Pull a tiny real model into the isolated model directory'
  $ciModel='qwen3:0.6b'
  $oldHost=$env:OLLAMA_HOST
  $oldModels=$env:OLLAMA_MODELS
  $env:OLLAMA_HOST=$hostValue
  $env:OLLAMA_MODELS=$modelRoot
  try{
    & $ollama pull $ciModel
    if($LASTEXITCODE -ne 0){throw "ollama pull returned $LASTEXITCODE"}
  }finally{
    $env:OLLAMA_HOST=$oldHost
    $env:OLLAMA_MODELS=$oldModels
  }
  $tags=Invoke-RestMethod -Uri "$api/api/tags" -TimeoutSec 10
  Assert-True (@($tags.models).Count -gt 0) 'Private Ollama model list is empty after pull.'

  Write-Host 'D) Generate the same Antigravity agent file shape used by production'
  $template=Get-Content (Join-Path $src '_internal\local_agent.py') -Raw
  $agent=$template.Replace('__MODEL__',$ciModel).Replace('__BASE_URL__',"$api/v1")
  $agentPath=Join-Path $env:RUNNER_TEMP 'ci-local-agent.py'
  Set-Content $agentPath $agent -Encoding UTF8

  Write-Host 'E) Real Antigravity -> Ollama -> model call'
  $oldPrompt=$env:ANTIGRAVITY_LOCAL_PROMPT
  $env:ANTIGRAVITY_LOCAL_PROMPT='Reply with only: OK'
  $oldPreference=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $output=& $py $agentPath 2>&1
    $code=$LASTEXITCODE
  }finally{
    $ErrorActionPreference=$oldPreference
    $env:ANTIGRAVITY_LOCAL_PROMPT=$oldPrompt
  }
  Write-Host "Agent exit code: $code"
  Write-Host "Agent output: $output"
  Assert-True ($code -eq 0) "Real Antigravity/Ollama call failed with exit code $code"
  Assert-True (-not [string]::IsNullOrWhiteSpace(($output|Out-String))) 'Real Antigravity/Ollama call returned no output.'

  Write-Host 'F) Confirm model files stayed in the isolated test directory'
  $bytes=(Get-ChildItem $modelRoot -Recurse -File|Measure-Object Length -Sum).Sum
  Assert-True ([int64]$bytes -gt 1000000) 'Isolated model directory contains no substantial model data.'
  Write-Host "Private model bytes: $bytes"

  Write-Host 'REAL WINDOWS OLLAMA/ANTIGRAVITY INTEGRATION PASSED'
} finally {
  try{if($server -and -not $server.HasExited){$server.Kill();$server.WaitForExit(10000)|Out-Null}}catch{}
}
