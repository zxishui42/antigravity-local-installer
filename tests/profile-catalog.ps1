$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){ if(-not $Condition){ throw "ASSERT FAILED: $Message" } }

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$catalog=Get-Content (Join-Path $repoRoot 'src\_internal\pack.json') -Raw | ConvertFrom-Json
$profiles=@($catalog.profiles)
Assert-True ($profiles.Count -gt 0) 'No installer profiles exist.'

$ids=@{}
$folders=@{}
foreach($p in $profiles){
    foreach($field in @('id','install_folder','title','os','route','model','model_label','registry_manifest_url')){
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$p.$field)) ("Profile "+[string]$p.id+" is missing "+$field)
    }
    Assert-True (-not $ids.ContainsKey([string]$p.id)) ("Duplicate profile id: "+[string]$p.id)
    Assert-True (-not $folders.ContainsKey([string]$p.install_folder)) ("Duplicate install folder: "+[string]$p.install_folder)
    $ids[[string]$p.id]=$true
    $folders[[string]$p.install_folder]=$true
}

$routing=Get-Content (Join-Path $repoRoot 'catalog\package-routing.json') -Raw | ConvertFrom-Json
foreach($rule in @($routing.rules)){
    Assert-True ($ids.ContainsKey([string]$rule.profile_id)) ("Routing rule points to missing profile: "+[string]$rule.profile_id)
}

& (Join-Path $repoRoot 'build\generate-site-routing.ps1')
$out=Get-Content (Join-Path $repoRoot 'dist\site-installer-routing.json') -Raw | ConvertFrom-Json
Assert-True ([int]$out.configuration_count -gt 100) 'Routing generator did not expand the website configuration space.'
Assert-True ([int]$out.installer_available_count -gt 0) 'No website configuration maps to a verified installer.'
Write-Host ("PROFILE / ROUTING CATALOG PASSED: "+$out.configuration_count+" configurations, "+$out.installer_available_count+" installer-ready.")
