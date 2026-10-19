$ErrorActionPreference='Stop'

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$catalogPath=Join-Path $repoRoot 'src\_internal\pack.json'
$catalog=Get-Content $catalogPath -Raw | ConvertFrom-Json
$profiles=@($catalog.profiles | Where-Object { [bool]$_.verified -and ($null -eq $_.release -or [bool]$_.release) -and ([string]::IsNullOrWhiteSpace([string]$_.platform) -or [string]$_.platform -eq 'windows') })

if($profiles.Count -eq 0){ throw 'No verified installer profiles are available to build.' }

$profileDir=Join-Path $repoRoot 'dist\profiles'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
Get-ChildItem $profileDir -Filter '*.exe' -ErrorAction SilentlyContinue | Remove-Item -Force

$items=@()
foreach($profile in $profiles){
    Write-Host ("Building verified installer profile: "+[string]$profile.id)
    $json=& (Join-Path $PSScriptRoot 'build-profile.ps1') -ProfileId ([string]$profile.id)
    $result=$json | ConvertFrom-Json
    $exe=Join-Path $repoRoot ('dist\'+([string]$result.installer_file).Replace('/','\'))
    if(-not(Test-Path $exe)){throw ('Built profile installer is missing: '+[string]$profile.id)}
    $self=Start-Process -FilePath $exe -ArgumentList '--self-test' -Wait -PassThru
    if($self.ExitCode -ne 0){throw ('Profile installer self-test failed: '+[string]$profile.id+' exit '+[string]$self.ExitCode)}
    $items += $result
}

$release=[ordered]@{
    schema_version=1
    generated_utc=(Get-Date).ToUniversalTime().ToString('o')
    verified_profile_count=$items.Count
    installers=$items
}
$out=Join-Path $repoRoot 'dist\installer-catalog.json'
$release | ConvertTo-Json -Depth 12 | Set-Content $out -Encoding UTF8
Write-Host ("Built "+$items.Count+" verified installer package(s).")
Write-Host ("Release catalog: "+$out)
