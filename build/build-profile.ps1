param(
    [Parameter(Mandatory=$true)][string]$ProfileId
)
$ErrorActionPreference='Stop'

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$catalogPath=Join-Path $repoRoot 'src\_internal\pack.json'
$catalog=Get-Content $catalogPath -Raw | ConvertFrom-Json
$profile=@($catalog.profiles | Where-Object { [string]$_.id -eq $ProfileId } | Select-Object -First 1)[0]

if($null -eq $profile){ throw "Unknown installer profile: $ProfileId" }
if(-not [bool]$profile.verified){ throw "Profile is not marked verified and cannot be released: $ProfileId" }
if(-not[string]::IsNullOrWhiteSpace([string]$profile.platform) -and [string]$profile.platform -ne 'windows'){ throw "This builder only produces Windows installers: $ProfileId" }
if($null -ne $profile.release -and -not[bool]$profile.release){ throw "Profile is not released: $ProfileId" }

& (Join-Path $PSScriptRoot 'prepare.ps1')

$prepared=Join-Path $repoRoot '.buildsrc'
$preparedPack=Join-Path $prepared '_internal\pack.json'
$releaseConfig=[ordered]@{
    schema_version=$catalog.schema_version
    shared=$catalog.shared
    profiles=@($profile)
}
$releaseConfig | ConvertTo-Json -Depth 12 | Set-Content $preparedPack -Encoding UTF8

& (Join-Path $PSScriptRoot 'build-app.ps1')

$profileDir=Join-Path $repoRoot 'dist\profiles'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
$outputName='profiles\'+$ProfileId+'.exe'
& (Join-Path $PSScriptRoot 'build-bootstrapper.ps1') -OutputName $outputName

$exe=Join-Path $repoRoot ('dist\profiles\'+$ProfileId+'.exe')
if(-not(Test-Path $exe)){ throw "Profile installer was not created: $ProfileId" }

$hash=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
$result=[ordered]@{
    id=[string]$profile.id
    title=[string]$profile.title
    os=[string]$profile.os
    route=[string]$profile.route
    model=[string]$profile.model
    model_label=[string]$profile.model_label
    installer_file=('profiles/'+$ProfileId+'.exe')
    sha256=$hash
    size_bytes=[long](Get-Item $exe).Length
    verified=[bool]$profile.verified
}
$result | ConvertTo-Json -Depth 8
