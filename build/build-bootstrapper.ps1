param(
    [string]$OutputName = 'AntigravityLocalSetup.exe'
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$prepared=Join-Path $repoRoot '.buildsrc'
if(-not(Test-Path $prepared)){ & (Join-Path $PSScriptRoot 'prepare.ps1') }
$dist=Join-Path $repoRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$exe=Join-Path $dist $OutputName
Remove-Item $exe -Force -ErrorAction SilentlyContinue
$cscCandidates=@(
  "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
  "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc=$cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if(-not$csc){throw 'C# compiler for .NET Framework was not found on this Windows runner.'}
$source=Join-Path $repoRoot 'build\bootstrapper.cs'
$installer=Join-Path $prepared '_internal\installer.ps1'
$worker=Join-Path $prepared '_internal\worker.ps1'
$agent=Join-Path $prepared '_internal\local_agent.py'
$litertAgent=Join-Path $prepared '_internal\litert_agent.py'
$pack=Join-Path $prepared '_internal\pack.json'
$app=Join-Path $prepared '_internal\AntigravityLocal.exe'
foreach($p in @($source,$installer,$worker,$agent,$litertAgent,$pack,$app)){ if(-not(Test-Path $p)){throw "Required bootstrapper input is missing: $p"} }
& $csc /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll "/resource:$installer,Payload.Installer" "/resource:$worker,Payload.Worker" "/resource:$agent,Payload.Agent" "/resource:$litertAgent,Payload.LiteRTAgent" "/resource:$pack,Payload.Pack" "/resource:$app,Payload.App" "/out:$exe" $source
if($LASTEXITCODE -ne 0){throw "csc.exe returned exit code $LASTEXITCODE"}
if(-not(Test-Path $exe)){throw ("Installer was not created: "+$OutputName)}
if((Get-Item $exe).Length -lt 10000){throw 'AntigravityLocalSetup.exe is unexpectedly small.'}
Write-Host "Built single-file installer: $exe"
