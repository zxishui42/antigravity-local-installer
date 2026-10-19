param(
  [Parameter(Mandatory=$true)][string]$ProfileId
)
$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){
  if(-not $Condition){ throw "ASSERT FAILED: $Message" }
}

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$config=Get-Content (Join-Path $repoRoot 'src\_internal\pack.json') -Raw | ConvertFrom-Json
$profile=@($config.profiles | Where-Object { [string]$_.id -eq $ProfileId } | Select-Object -First 1)[0]
if($null -eq $profile){ throw "Unknown profile: $ProfileId" }

$model=[string]$profile.model
Assert-True (-not[string]::IsNullOrWhiteSpace($model)) 'Candidate model id is empty.'
Assert-True (-not[string]::IsNullOrWhiteSpace([string]$profile.registry_manifest_url)) 'Candidate registry manifest URL is empty.'

$ram=[Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)
$gpu=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name }) -join '; '
Write-Host "VALIDATING PROFILE: $ProfileId"
Write-Host "MODEL: $model"
Write-Host "RUNNER RAM: $ram GB"
Write-Host "RUNNER GPU: $gpu"

Write-Host 'A) Confirm the exact Ollama manifest exists'
$headers=@{Accept='application/vnd.docker.distribution.manifest.v2+json'}
$manifest=Invoke-RestMethod -Uri ([string]$profile.registry_manifest_url) -Headers $headers -TimeoutSec 30
$manifestBytes=0L
if($manifest.config.size){$manifestBytes += [long]$manifest.config.size}
foreach($layer in @($manifest.layers)){if($layer.size){$manifestBytes += [long]$layer.size}}
Assert-True ($manifestBytes -gt 1000000) 'Manifest returned no substantial model size.'
Write-Host ("Registry payload bytes: "+$manifestBytes)

Write-Host 'B) Prepare exact Antigravity SDK'
$venv=Join-Path $env:RUNNER_TEMP ('ag-profile-'+$ProfileId+'-venv')
Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue
python -m venv $venv
$py=Join-Path $venv 'Scripts\python.exe'
& $py -m pip install --disable-pip-version-check --no-input ("google-antigravity="+([string]$config.shared.antigravity_version))
if($LASTEXITCODE -ne 0){ throw 'Antigravity SDK installation failed.' }
& $py -c "from google.antigravity import Agent, LocalOpenAIAgentConfig; print('antigravity import ok')"
if($LASTEXITCODE -ne 0){ throw 'Antigravity SDK import failed.' }

Write-Host 'C) Install or find Ollama'
$ollama=(Get-Command ollama -ErrorAction SilentlyContinue).Source
if(-not $ollama){
  $installScript=Join-Path $env:RUNNER_TEMP ('ollama-install-'+$ProfileId+'.ps1')
  Invoke-WebRequest -UseBasicParsing -Uri 'https://ollama.com/install.ps1' -OutFile $installScript -TimeoutSec 120
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
  if($LASTEXITCODE -ne 0){ throw "Ollama installer returned $LASTEXITCODE" }
  $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')
  $ollama=(Get-Command ollama -ErrorAction SilentlyContinue).Source
}
if(-not $ollama){
  $candidate=Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
  if(Test-Path $candidate){$ollama=$candidate}
}
Assert-True ([bool]$ollama) 'ollama.exe was not found.'

Write-Host 'D) Start isolated Ollama and pull the real candidate model'
$port=11520
$hostValue="127.0.0.1:$port"
$api="http://$hostValue"
$modelRoot=Join-Path $env:RUNNER_TEMP ('ag-profile-models-'+$ProfileId)
Remove-Item $modelRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $modelRoot | Out-Null

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

try {
  $ready=$false
  for($i=0;$i -lt 60;$i++){
    Start-Sleep 1
    try{$v=Invoke-RestMethod -Uri "$api/api/version" -TimeoutSec 2;if($v.version){$ready=$true;break}}catch{}
  }
  Assert-True $ready 'Isolated Ollama server did not become ready.'

  $oldHost=$env:OLLAMA_HOST
  $oldModels=$env:OLLAMA_MODELS
  $env:OLLAMA_HOST=$hostValue
  $env:OLLAMA_MODELS=$modelRoot
  try{
    & $ollama pull $model
    if($LASTEXITCODE -ne 0){ throw "ollama pull returned $LASTEXITCODE" }
  } finally {
    $env:OLLAMA_HOST=$oldHost
    $env:OLLAMA_MODELS=$oldModels
  }

  $tags=Invoke-RestMethod -Uri "$api/api/tags" -TimeoutSec 15
  $found=@($tags.models | Where-Object { $_.name -eq $model -or $_.model -eq $model }).Count -gt 0
  Assert-True $found 'Pulled model is not visible in the isolated Ollama model list.'

  Write-Host 'E) Run the same Antigravity-to-Ollama path used by the product'
  $template=Get-Content (Join-Path $repoRoot 'src\_internal\local_agent.py') -Raw
  $agent=$template.Replace('__MODEL__',$model).Replace('__BASE_URL__',"$api/v1")
  $agentPath=Join-Path $env:RUNNER_TEMP ('profile-agent-'+$ProfileId+'.py')
  Set-Content $agentPath $agent -Encoding UTF8

  $oldPrompt=$env:ANTIGRAVITY_LOCAL_PROMPT
  $env:ANTIGRAVITY_LOCAL_PROMPT='Reply with only: OK'
  $oldPreference=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $output=& $py $agentPath 2>&1
    $code=$LASTEXITCODE
  } finally {
    $ErrorActionPreference=$oldPreference
    $env:ANTIGRAVITY_LOCAL_PROMPT=$oldPrompt
  }

  Write-Host "Agent exit code: $code"
  Write-Host "Agent output: $output"
  Assert-True ($code -eq 0) "Antigravity/Ollama candidate call failed with exit code $code"
  Assert-True (-not[string]::IsNullOrWhiteSpace(($output|Out-String))) 'Candidate model returned no output.'

  $ps=Invoke-RestMethod -Uri "$api/api/ps" -TimeoutSec 15
  $loaded=@($ps.models | Where-Object { $_.name -like ($model+'*') -or $_.model -like ($model+'*') } | Select-Object -First 1)
  if($loaded.Count -gt 0){
    Write-Host ("Loaded size: "+[string]$loaded[0].size)
    Write-Host ("Loaded VRAM bytes: "+[string]$loaded[0].size_vram)
  }

  $bytes=(Get-ChildItem $modelRoot -Recurse -File | Measure-Object Length -Sum).Sum
  Write-Host "Private model bytes: $bytes"
  Write-Host "PROFILE MODEL INTEGRATION PASSED: $ProfileId"
} finally {
  try{if($server -and -not $server.HasExited){$server.Kill();$server.WaitForExit(10000)|Out-Null}}catch{}
  Remove-Item $modelRoot -Recurse -Force -ErrorAction SilentlyContinue
}
