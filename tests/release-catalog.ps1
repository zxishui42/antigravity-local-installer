$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){
  if(-not $Condition){ throw "ASSERT FAILED: $Message" }
}

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$packPath=Join-Path $repoRoot 'src\_internal\pack.json'
$catalogPath=Join-Path $repoRoot 'dist\installer-catalog.json'
$routingPath=Join-Path $repoRoot 'dist\site-installer-routing.json'

Assert-True (Test-Path $catalogPath) 'installer-catalog.json is missing.'
Assert-True (Test-Path $routingPath) 'site-installer-routing.json is missing.'

$pack=Get-Content $packPath -Raw | ConvertFrom-Json
$catalog=Get-Content $catalogPath -Raw | ConvertFrom-Json
$routing=Get-Content $routingPath -Raw | ConvertFrom-Json

$released=@($pack.profiles | Where-Object { [bool]$_.verified -and ($null -eq $_.release -or [bool]$_.release) })
$items=@($catalog.installers)

Assert-True ($items.Count -eq $released.Count) ("Release catalog count mismatch. Expected "+$released.Count+", got "+$items.Count+".")

$catalogById=@{}
$files=@{}
foreach($item in $items){
  $id=[string]$item.id
  Assert-True (-not[string]::IsNullOrWhiteSpace($id)) 'Release catalog contains an empty profile id.'
  Assert-True (-not $catalogById.ContainsKey($id)) ("Duplicate release profile id: "+$id)
  $catalogById[$id]=$item

  $rel=[string]$item.installer_file
  Assert-True (-not[string]::IsNullOrWhiteSpace($rel)) ("Installer file is missing for "+$id)
  Assert-True (-not $files.ContainsKey($rel)) ("Two profiles point to the same installer file: "+$rel)
  $files[$rel]=$true

  $exe=Join-Path $repoRoot ('dist\'+$rel.Replace('/','\'))
  Assert-True (Test-Path $exe) ("Built installer is missing: "+$rel)
  $actual=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert-True ($actual -eq ([string]$item.sha256).ToLowerInvariant()) ("SHA256 mismatch for "+$id)
}

foreach($profile in $released){
  Assert-True ($catalogById.ContainsKey([string]$profile.id)) ("Verified release profile is missing from catalog: "+[string]$profile.id)
}

$available=@($routing.configurations | Where-Object { $_.status -eq 'installer_available' })
Assert-True ($available.Count -gt 0) 'No website configuration is installer_available.'

foreach($row in $available){
  $id=[string]$row.profile_id
  Assert-True ($catalogById.ContainsKey($id)) ("Website route points to a package that was not built: "+$id)
  Assert-True ([string]$row.installer_file -eq [string]$catalogById[$id].installer_file) ("Website installer filename does not match release catalog for "+$id)
}

$nonRelease=@($routing.configurations | Where-Object { $_.status -ne 'installer_available' })
foreach($row in $nonRelease){
  Assert-True ([string]::IsNullOrWhiteSpace([string]$row.installer_file)) ("Non-released website route exposes an installer file: "+[string]$row.status+" / "+[string]$row.profile_id)
}

foreach($item in $items){
  $count=@($available | Where-Object { [string]$_.profile_id -eq [string]$item.id }).Count
  Assert-True ($count -gt 0) ("Built release profile is not used by any website configuration: "+[string]$item.id)
  Write-Host ("PACKAGE "+[string]$item.id+" -> "+$count+" website configurations")
}

Write-Host ("RELEASE CATALOG PASSED: "+$items.Count+" installer package(s), "+$available.Count+" website configurations.")
