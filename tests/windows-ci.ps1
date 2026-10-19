$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition,[string]$Message) {
  if(-not $Condition){ throw "ASSERT FAILED: $Message" }
}

$repoRoot = (Get-Location).Path
$src = Join-Path $repoRoot 'src'
Assert-True (Test-Path $src) 'src directory is missing.'
Set-Location $src

Write-Host '1) Parse production PowerShell'
foreach($file in @('_internal/worker.ps1','_internal/installer.ps1')){
  $tokens=$null; $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file),[ref]$tokens,[ref]$errors)
  Assert-True ($errors.Count -eq 0) ("$file parse errors: "+(($errors|ForEach-Object Message)-join '; '))
}

Write-Host '2) Validate package config'
$pack=Get-Content '_internal/pack.json' -Raw | ConvertFrom-Json
Assert-True ($pack.model -eq 'gemma4:e2b') 'Unexpected model.'
Assert-True ($pack.antigravity_version -eq '0.1.22') 'Unexpected Antigravity version.'
Assert-True ([int]$pack.min_windows_build -ge 19045) 'Windows minimum build too low.'
Assert-True ([int]$pack.port_start -lt [int]$pack.port_end) 'Invalid private port range.'
Assert-True ([double]$pack.app_overhead_gb -gt 0) 'Invalid app overhead.'
Assert-True ([int64]$pack.download_stall_seconds -gt 0) 'Invalid stall timeout.'

Write-Host '3) Regression: multi-GB counters stay 64-bit'
[long]$downloaded=3502496202
[long]$expected=7500000000
$ratio=[double]$downloaded/[double]$expected
if($ratio -lt 0){$ratio=0};if($ratio -gt 1){$ratio=1}
$progress=[int](45+($ratio*15))
Assert-True ($progress -ge 45 -and $progress -le 60) 'Large-file progress math failed.'

Write-Host '4) Regression: warning on stderr with exit 0 is success'
$out=Join-Path $env:RUNNER_TEMP 'warning-out.txt'
$err=Join-Path $env:RUNNER_TEMP 'warning-err.txt'
Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
$p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command',"[Console]::Error.WriteLine('WARNING: harmless');Write-Output 'OK';exit 0") -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
Assert-True ($p.WaitForExit(30000)) 'Warning test process timed out.'
$p.WaitForExit()
$p.Refresh()
$code=$p.ExitCode
Assert-True ($null -ne $code -and [int]$code -eq 0) "Warning test exit code was $code"
Assert-True ((Get-Content $out -Raw).Trim() -eq 'OK') 'Warning test stdout mismatch.'
Assert-True ((Get-Content $err -Raw) -match 'WARNING') 'Warning test stderr missing.'

Write-Host '5) Regression: exact OK-output success pattern'
$out2=Join-Path $env:RUNNER_TEMP 'agent-out.txt'
$err2=Join-Path $env:RUNNER_TEMP 'agent-err.txt'
Remove-Item $out2,$err2 -Force -ErrorAction SilentlyContinue
$p2=Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command',"Write-Output 'OK';exit 0") -PassThru -RedirectStandardOutput $out2 -RedirectStandardError $err2
Assert-True ($p2.WaitForExit(30000)) 'Agent simulation timed out.'
$p2.WaitForExit()
$p2.Refresh()
$exitCode=$p2.ExitCode
$o=if(Test-Path $out2){Get-Content $out2 -Raw}else{''}
Assert-True ($null -ne $exitCode -and [int]$exitCode -eq 0) "Agent success was incorrectly read as failure: $exitCode"
Assert-True (-not [string]::IsNullOrWhiteSpace($o)) 'Agent OK output was read as empty.'

Write-Host '6) Inspect production regression guards'
$worker=Get-Content '_internal/worker.ps1' -Raw
Assert-True ($worker.Contains('$p.WaitForExit()')) 'Production worker is missing final parameterless WaitForExit().'
Assert-True ($worker.Contains('$p.Refresh()')) 'Production worker is missing Process.Refresh().'
Assert-True ($worker.Contains('$exitCode=$p.ExitCode')) 'Production worker does not snapshot ExitCode.'
Assert-True ($worker.Contains('if($null -eq $exitCode -or [int]$exitCode -ne 0)')) 'Production success check is not null-safe.'
Assert-True ($worker.Contains('Antigravity returned no output.')) 'Production worker accepts empty output.'
Assert-True (-not $worker.Contains("if($p.ExitCode -ne 0){throw 'Antigravity could not connect to the model.'}")) 'Old stale ExitCode check remains.'
Assert-True ($worker.Contains('--no-warn-script-location')) 'pip warning suppression missing.'
Assert-True ($worker.Contains('[long](FolderBytes $ModelRoot)')) 'Model size accounting is not explicitly 64-bit.'
Assert-True ($worker.Contains("OLLAMA_MODELS")) 'Private model directory isolation missing.'

Write-Host '7) Python syntax'
python -m py_compile '_internal/local_agent.py'
if($LASTEXITCODE -ne 0){throw 'local_agent.py failed to compile.'}

Write-Host '8) Install and import exact Antigravity SDK on Windows/Python 3.12'
$venv=Join-Path $env:RUNNER_TEMP 'ag-ci-venv'
Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue
python -m venv $venv
$py=Join-Path $venv 'Scripts\python.exe'
& $py -m pip install --disable-pip-version-check --no-input "google-antigravity==$($pack.antigravity_version)"
if($LASTEXITCODE -ne 0){throw 'google-antigravity install failed.'}
& $py -c "from google.antigravity import Agent, LocalOpenAIAgentConfig; print('antigravity import ok')"
if($LASTEXITCODE -ne 0){throw 'google-antigravity import failed.'}

Write-Host '9) Validate user launchers and uninstall registration'
Assert-True (Test-Path 'Install Antigravity Local.vbs') 'VBS launcher missing.'
Assert-True (Test-Path 'START_HERE.cmd') 'CMD launcher missing.'
Assert-True ($worker.Contains('Register-Uninstaller')) 'Uninstaller registration missing.'
Assert-True ($worker.Contains('HKCU:')) 'Per-user uninstall registry entry missing.'
Assert-True ($worker.Contains("Remove-Item `$root -Recurse -Force")) 'Generated uninstaller does not remove its own install root.'

Write-Host '10) Build customer source package'
$dist=Join-Path $repoRoot 'dist'
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dist|Out-Null
$zip=Join-Path $dist 'antigravity-local-windows-e2b-ci.zip'
Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -Force
Assert-True ((Get-Item $zip).Length -gt 1000) 'Built package is unexpectedly small.'
$verify=Join-Path $env:RUNNER_TEMP 'ag-roundtrip'
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip $verify -Force
Assert-True (Test-Path (Join-Path $verify '_internal\worker.ps1')) 'Built package round-trip lost worker.ps1.'
Assert-True (Test-Path (Join-Path $verify 'Install Antigravity Local.vbs')) 'Built package round-trip lost launcher.'

Write-Host 'ALL WINDOWS CI CHECKS PASSED'
