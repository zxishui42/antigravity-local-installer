$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$prepared=Join-Path $repoRoot '.buildsrc'
if(-not(Test-Path $prepared)){ & (Join-Path $PSScriptRoot 'prepare.ps1') }
$source=Join-Path $repoRoot 'build\app.cs'
$out=Join-Path $prepared '_internal\AntigravityLocal.exe'
$cscCandidates=@(
  "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
  "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc=$cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if(-not$csc){throw 'C# compiler for .NET Framework was not found.'}
& $csc /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll "/out:$out" $source
if($LASTEXITCODE -ne 0){throw "app compiler returned exit code $LASTEXITCODE"}
if(-not(Test-Path $out)){throw 'AntigravityLocal.exe was not created.'}
Write-Host "Built installed app: $out"
