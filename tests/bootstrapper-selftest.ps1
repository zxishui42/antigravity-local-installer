$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe=Join-Path $repoRoot 'dist\AntigravityLocalSetup.exe'
if(-not(Test-Path $exe)){throw 'Single-file installer is missing.'}
$p=Start-Process -FilePath $exe -ArgumentList '--self-test' -Wait -PassThru
if($p.ExitCode -ne 0){throw "Single-file installer self-test failed with exit code $($p.ExitCode)"}
Write-Host 'SINGLE-FILE INSTALLER SELF-TEST PASSED'
