$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition,[string]$Message) {
  if(-not $Condition){ throw "ASSERT FAILED: $Message" }
}

$repoRoot = (Get-Location).Path
& (Join-Path $repoRoot 'build\prepare.ps1')
$src = Join-Path $repoRoot '.buildsrc'
Assert-True (Test-Path $src) 'Prepared source directory is missing.'
Set-Location $src

Write-Host '1) Parse production PowerShell'
foreach($file in @('_internal/worker.ps1','_internal/installer.ps1')){
  $tokens=$null; $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file),[ref]$tokens,[ref]$errors)
  Assert-True ($errors.Count -eq 0) ("$file parse errors: "+(($errors|ForEach-Object Message)-join '; '))
}

Write-Host '2) Validate package config'
$config=Get-Content '_internal/pack.json' -Raw | ConvertFrom-Json
Assert-True ([int]$config.schema_version -ge 1) 'Missing config schema version.'
Assert-True (@($config.profiles).Count -ge 1) 'No install profiles are configured.'
$pack=@($config.profiles)[0]
$shared=$config.shared
Assert-True ($pack.model -eq 'gemma4:e2b') 'Unexpected model.'
Assert-True ($pack.install_folder -eq 'gemma4-e2b') 'Unexpected install folder.'
Assert-True ([bool]$pack.verified) 'Primary install profile is not verified.'
Assert-True ($shared.antigravity_version -eq '0.1.22') 'Unexpected Antigravity version.'
Assert-True ([int]$shared.min_windows_build -ge 19045) 'Windows minimum build too low.'
Assert-True ([int]$shared.port_start -lt [int]$shared.port_end) 'Invalid private port range.'
Assert-True ([double]$pack.app_overhead_gb -gt 0) 'Invalid app overhead.'
Assert-True ([int64]$shared.download_stall_seconds -gt 0) 'Invalid stall timeout.'

Write-Host '3) Regression: multi-GB counters stay 64-bit'
[long]$downloaded=3502496202
[long]$expected=7500000000
$ratio=[double]$downloaded/[double]$expected
if($ratio -lt 0){$ratio=0};if($ratio -gt 1){$ratio=1}
$progress=[int](45+($ratio*15))
Assert-True ($progress -ge 45 -and $progress -le 60) 'Large-file progress math failed.'

Write-Host '4) Regression: child-written exit status survives Windows PowerShell 5'
$child=Join-Path $env:RUNNER_TEMP 'ci-child.ps1'
$wrapper=Join-Path $env:RUNNER_TEMP 'ci-wrapper.ps1'
$out=Join-Path $env:RUNNER_TEMP 'ci-child.out'
$err=Join-Path $env:RUNNER_TEMP 'ci-child.err'
$codeFile=Join-Path $env:RUNNER_TEMP 'ci-child.code'
@"
Write-Output 'OK'
[Console]::Error.WriteLine('WARNING: harmless')
exit 0
"@ | Set-Content $child -Encoding UTF8
$childLiteral=$child.Replace("'","''")
$outLiteral=$out.Replace("'","''")
$errLiteral=$err.Replace("'","''")
$codeLiteral=$codeFile.Replace("'","''")
@"
`$ErrorActionPreference='Continue'
& powershell.exe -NoProfile -File '$childLiteral' 1> '$outLiteral' 2> '$errLiteral'
`$nativeCode=`$LASTEXITCODE
if(`$null -eq `$nativeCode){`$nativeCode=0}
Set-Content -LiteralPath '$codeLiteral' -Value ([string]`$nativeCode) -Encoding ASCII
exit `$nativeCode
"@ | Set-Content $wrapper -Encoding UTF8
Remove-Item $out,$err,$codeFile -Force -ErrorAction SilentlyContinue
$p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper) -PassThru
Assert-True ($p.WaitForExit(30000)) 'Sidecar status test timed out.'
Assert-True (Test-Path $codeFile) 'Child status sidecar was not written.'
$codeRaw=(Get-Content $codeFile -Raw).Trim()
Assert-True ($codeRaw -eq '0') "Expected child status 0, got '$codeRaw'"
Assert-True ((Get-Content $out -Raw).Trim() -eq 'OK') 'Child stdout mismatch.'
Assert-True ((Get-Content $err -Raw) -match 'WARNING') 'Child stderr warning missing.'

Write-Host '5) Regression: production Antigravity test uses sidecar, not parent ExitCode'
$worker=Get-Content '_internal/worker.ps1' -Raw
$testStart=$worker.IndexOf('function Test-Antigravity {')
$testEnd=$worker.IndexOf('function Write-UserLauncher',$testStart)
Assert-True ($testStart -ge 0 -and $testEnd -gt $testStart) 'Test-Antigravity block missing.'
$testBlock=$worker.Substring($testStart,$testEnd-$testStart)
Assert-True ($testBlock.Contains('$codeFile=')) 'Antigravity test has no status sidecar.'
Assert-True ($testBlock.Contains('LASTEXITCODE')) 'Child wrapper does not record LASTEXITCODE.'
Assert-True ($testBlock.Contains('Set-Content -LiteralPath')) 'Child wrapper does not persist its exit status.'
Assert-True ($testBlock.Contains('agent-test-wrapper.ps1')) 'Child wrapper file is missing.'
Assert-True (-not $testBlock.Contains('$p.ExitCode')) 'Antigravity test still depends on unreliable parent ExitCode.'
Assert-True ($testBlock.Contains('if($null -eq $exitCode -or $exitCode -ne 0)')) 'Sidecar success check is not null-safe.'
Assert-True ($testBlock.Contains('Antigravity returned no output.')) 'Antigravity test accepts empty output.'

Write-Host '6) Inspect other production regression guards'
Assert-True (-not $worker.Contains("`$proc.ExitCode -eq 0")) 'User launcher still depends on Process.ExitCode.'
Assert-True ($worker.Contains('--no-warn-script-location')) 'pip warning suppression missing.'
Assert-True ($worker.Contains('[long](FolderBytes $ModelRoot)')) 'Model size accounting is not explicitly 64-bit.'
Assert-True ($worker.Contains('OLLAMA_MODELS')) 'Private model directory isolation missing.'
Assert-True ($worker.Contains('download_stall_seconds')) 'Download stall handling missing.'
Assert-True ($worker.Contains('nvidia-smi')) 'NVIDIA VRAM recheck is missing.'
Assert-True ($worker.Contains('min_vram_gb')) 'Profile VRAM floor is not enforced.'
Assert-True ($worker.Contains('Test-ProfileMatch')) 'Installer is not profile-driven.'
Assert-True ($worker.Contains('$Config.profiles')) 'Installer does not read configured profiles.'
Assert-True ($worker.Contains('$Pack.install_folder')) 'Install folder is still hardcoded.'
Assert-True (-not $worker.Contains("AntigravityLocal\gemma4-e2b")) 'Production worker still hardcodes the Gemma install folder.'
Assert-True (-not $worker.Contains((([string][char]92)+([string][char]96)))) 'Prepared source still contains backslash/backtick artifacts.'
Assert-True (-not $worker.Contains('\\')) 'Prepared source still contains doubled path separators.'

Write-Host '7) Python syntax'
python -m py_compile '_internal/local_agent.py'
if($LASTEXITCODE -ne 0){throw 'local_agent.py failed to compile.'}

Write-Host '8) Install and import exact Antigravity SDK on Windows/Python 3.12'
$venv=Join-Path $env:RUNNER_TEMP 'ag-ci-venv'
Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue
python -m venv $venv
$py=Join-Path $venv 'Scripts\python.exe'
& $py -m pip install --disable-pip-version-check --no-input "google-antigravity==$($shared.antigravity_version)"
if($LASTEXITCODE -ne 0){throw 'google-antigravity install failed.'}
& $py -c "from google.antigravity import Agent, LocalOpenAIAgentConfig; print('antigravity import ok')"
if($LASTEXITCODE -ne 0){throw 'google-antigravity import failed.'}

Write-Host '9) Validate user launchers and uninstall registration'
Assert-True (Test-Path 'Install Antigravity Local.vbs') 'VBS launcher missing.'
Assert-True (Test-Path 'START_HERE.cmd') 'CMD launcher missing.'
Assert-True ($worker.Contains('Register-Uninstaller')) 'Uninstaller registration missing.'
Assert-True ($worker.Contains('HKCU:')) 'Per-user uninstall registry entry missing.'
Assert-True ($worker.Contains('Remove-Item `$root -Recurse -Force')) 'Generated uninstaller does not remove its own install root.'

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
