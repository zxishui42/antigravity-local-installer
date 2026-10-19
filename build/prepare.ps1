$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src=Join-Path $repoRoot 'src'
$stage=Join-Path $repoRoot '.buildsrc'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item $src $stage -Recurse -Force

$workerPath=Join-Path $stage '_internal\worker.ps1'
$worker=Get-Content $workerPath -Raw
$bad=([string][char]92)+([string][char]96)
$worker=$worker.Replace($bad,[string][char]96)
$worker=$worker.Replace('\\','\')
Set-Content $workerPath $worker -Encoding UTF8

if($worker.Contains($bad)){throw 'Backslash/backtick escape artifact remains after normalization.'}
if($worker.Contains('\\')){throw 'Double-backslash artifact remains after normalization.'}
Write-Host "Prepared Windows installer source at $stage"
