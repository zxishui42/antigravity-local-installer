param(
  [string]$ProfileId = 'windows-litert-gemma4-26b'
)
$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){
  if(-not $Condition){ throw "ASSERT FAILED: $Message" }
}

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$config=Get-Content (Join-Path $repoRoot 'src\_internal\pack.json') -Raw | ConvertFrom-Json
$profile=@($config.profiles | Where-Object { [string]$_.id -eq $ProfileId } | Select-Object -First 1)[0]
if($null -eq $profile){ throw "Unknown profile: $ProfileId" }
Assert-True ([string]$profile.route -eq 'LiteRT') 'Profile is not a LiteRT profile.'

$ram=[Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)
$gpu=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name }) -join '; '
Write-Host "LITERT PREFLIGHT PROFILE: $ProfileId"
Write-Host "RUNNER RAM: $ram GB"
Write-Host "RUNNER GPU: $gpu"

$venv=Join-Path $env:RUNNER_TEMP 'ag-litert-preflight-venv'
Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue
python -m venv $venv
$py=Join-Path $venv 'Scripts\python.exe'
$pip=Join-Path $venv 'Scripts\pip.exe'

Write-Host 'A) Install exact Antigravity SDK + LiteRT-LM'
& $py -m pip install --disable-pip-version-check --no-input ("google-antigravity=="+([string]$config.shared.antigravity_version)) litert-lm
if($LASTEXITCODE -ne 0){ throw 'LiteRT dependency installation failed.' }

Write-Host 'B) Import the production classes'
& $py -c "from google.antigravity import Agent, LiteRTAgentConfig; print('litert antigravity import ok')"
if($LASTEXITCODE -ne 0){ throw 'LiteRTAgentConfig import failed.' }

Write-Host 'C) Confirm the LiteRT CLI is installed'
$cli=Join-Path $venv 'Scripts\litert-lm.exe'
if(-not(Test-Path $cli)){
  $cli=Join-Path $venv 'Scripts\litert-lm'
}
Assert-True (Test-Path $cli) 'litert-lm CLI was not installed.'
& $cli --help
if($LASTEXITCODE -ne 0){ throw 'litert-lm CLI could not start.' }

Write-Host 'D) Confirm LiteRTAgentConfig can be constructed on Windows'
$probe=Join-Path $env:RUNNER_TEMP 'litert-config-probe.py'
@"
from google.antigravity import LiteRTAgentConfig
config = LiteRTAgentConfig(model_path=r"C:\__antigravity_preflight__\model.litertlm")
print(type(config).__name__)
"@ | Set-Content $probe -Encoding UTF8
& $py $probe
if($LASTEXITCODE -ne 0){ throw 'LiteRTAgentConfig construction failed.' }

Write-Host ('Official model repo: '+[string]$profile.litert_hf_repo)
Write-Host ('Official checkpoint file: '+[string]$profile.litert_source_file)
Write-Host ('Recommended minimum VRAM from profile: '+[string]$profile.min_vram_gb+' GB')
Write-Host 'WINDOWS LITERT PREFLIGHT PASSED'
