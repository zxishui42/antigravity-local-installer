$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$zip = Join-Path (Get-Location) 'installer-source.zip'
Assert-True (Test-Path $zip) 'installer-source.zip is missing.'

$work = Join-Path $env:RUNNER_TEMP 'ag-installer-src'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $zip -DestinationPath $work -Force

$workerFile = Get-ChildItem $work -Recurse -File -Filter 'worker.ps1' |
    Where-Object { $_.FullName -match '[\\/]_internal[\\/]worker\.ps1$' } |
    Select-Object -First 1
Assert-True ($null -ne $workerFile) 'worker.ps1 was not found after extracting the source bundle.'
$src = Split-Path (Split-Path $workerFile.FullName -Parent) -Parent
Set-Location $src

Write-Host "Testing source at: $src"

Write-Host '1) Parse PowerShell source files'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '_internal/worker.ps1'), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('worker.ps1 parse errors: ' + (($errors | ForEach-Object Message) -join '; '))

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '_internal/installer.ps1'), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('installer.ps1 parse errors: ' + (($errors | ForEach-Object Message) -join '; '))

Write-Host '2) Validate package config'
$pack = Get-Content '_internal/pack.json' -Raw | ConvertFrom-Json
Assert-True ($pack.model -eq 'gemma4:e2b') 'Unexpected model id.'
Assert-True ([int]$pack.min_windows_build -ge 19045) 'Windows build floor unexpectedly low.'
Assert-True ([int]$pack.port_start -lt [int]$pack.port_end) 'Private port range is invalid.'
Assert-True ([double]$pack.app_overhead_gb -gt 0) 'App overhead must be positive.'

Write-Host '3) Regression: 64-bit download accounting'
[long]$downloaded = 3502496202
[long]$expected = 7500000000
$ratio = [double]$downloaded / [double]$expected
Assert-True ($ratio -gt 0 -and $ratio -lt 1) '64-bit byte ratio failed.'
$clamped = [Math]::Min(1.0,[Math]::Max(0.0,$ratio))
$progress = [int](45 + ($clamped*15))
Assert-True ($progress -ge 45 -and $progress -le 60) 'Progress calculation is invalid.'

Write-Host '4) Regression: harmless stderr warning must not count as failure'
$stdout = Join-Path $env:RUNNER_TEMP 'native-out.txt'
$stderr = Join-Path $env:RUNNER_TEMP 'native-err.txt'
Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-Command',"[Console]::Error.WriteLine('WARNING: harmless'); Write-Output 'OK'; exit 0") -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$p.Refresh()
Assert-True ($p.ExitCode -eq 0) 'Warning-only native process was treated as failure.'
Assert-True ((Get-Content $stderr -Raw) -match 'WARNING') 'Expected warning was not captured.'

Write-Host '5) Regression: redirected Start-Process must expose exit code after wait/refresh'
$stdout2 = Join-Path $env:RUNNER_TEMP 'exit-out.txt'
$stderr2 = Join-Path $env:RUNNER_TEMP 'exit-err.txt'
Remove-Item $stdout2,$stderr2 -Force -ErrorAction SilentlyContinue
$p2 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-Command',"Write-Output 'OK'; exit 0") -PassThru -RedirectStandardOutput $stdout2 -RedirectStandardError $stderr2
Assert-True ($p2.WaitForExit(30000)) 'Child process did not exit.'
$p2.Refresh()
$exitCode = $p2.ExitCode
Assert-True ($null -ne $exitCode) 'ExitCode remained null after Refresh().'
Assert-True ([int]$exitCode -eq 0) "Expected exit code 0, got $exitCode"
Assert-True ((Get-Content $stdout2 -Raw).Trim() -eq 'OK') 'Expected child output was not captured.'

Write-Host '6) Verify production worker contains exit-code regression fix'
$worker = Get-Content '_internal/worker.ps1' -Raw
Assert-True ($worker.Contains('$p.Refresh()')) 'worker.ps1 does not refresh the Antigravity test process.'
Assert-True ($worker.Contains('$exitCode=$p.ExitCode')) 'worker.ps1 does not snapshot the Antigravity test exit code.'
Assert-True ($worker.Contains('if($null -eq $exitCode -or [int]$exitCode -ne 0)')) 'worker.ps1 Antigravity success check is not null-safe.'
Assert-True ($worker.Contains('Antigravity returned no output.')) 'worker.ps1 does not reject empty Antigravity output.'

Write-Host '7) Regression: no old known-bad patterns'
Assert-True (-not $worker.Contains('if($p.ExitCode -ne 0){throw ''Antigravity could not connect to the model.''}')) 'Old stale ExitCode check is still present.'
Assert-True (-not $worker.Contains('[Math]::Max(0,')) 'Potential Int32 Math.Max regression detected.'
Assert-True ($worker.Contains('--no-warn-script-location')) 'pip warning suppression is missing.'

Write-Host '8) Python syntax check'
python -m py_compile '_internal/local_agent.py'
if ($LASTEXITCODE -ne 0) { throw 'local_agent.py did not compile.' }

Write-Host '9) Install/import exact Antigravity SDK in clean Python 3.12 venv'
$venv = Join-Path $env:RUNNER_TEMP 'ag-ci-venv'
Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue
python -m venv $venv
$py = Join-Path $venv 'Scripts\python.exe'
& $py -m pip install --disable-pip-version-check --no-input "google-antigravity==$($pack.antigravity_version)"
if ($LASTEXITCODE -ne 0) { throw 'google-antigravity install failed.' }
& $py -c "from google.antigravity import Agent, LocalOpenAIAgentConfig; print('antigravity import ok')"
if ($LASTEXITCODE -ne 0) { throw 'google-antigravity import failed.' }

Write-Host '10) Validate launcher files'
Assert-True (Test-Path 'Install Antigravity Local.vbs') 'VBS launcher missing.'
Assert-True (Test-Path 'START_HERE.cmd') 'CMD fallback launcher missing.'

Write-Host '11) Validate bundle can be re-packed cleanly'
$roundtrip = Join-Path $env:RUNNER_TEMP 'installer-roundtrip.zip'
Remove-Item $roundtrip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path * -DestinationPath $roundtrip -Force
Assert-True ((Get-Item $roundtrip).Length -gt 1000) 'Round-trip archive is unexpectedly small.'

Write-Host 'ALL WINDOWS CI CHECKS PASSED'
