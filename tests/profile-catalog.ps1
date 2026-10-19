$ErrorActionPreference='Stop'

function Assert-True([bool]$Condition,[string]$Message){ if(-not $Condition){ throw "ASSERT FAILED: $Message" } }

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$catalog=Get-Content (Join-Path $repoRoot 'src\_internal\pack.json') -Raw | ConvertFrom-Json
$profiles=@($catalog.profiles)
Assert-True ($profiles.Count -gt 0) 'No installer profiles exist.'

$ids=@{}
$folders=@{}
foreach($p in $profiles){
    foreach($field in @('id','install_folder','title','os','route','model','model_label')){
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$p.$field)) ("Profile "+[string]$p.id+" is missing "+$field)
    }
    if([string]$p.route -eq 'Ollama'){
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$p.registry_manifest_url)) ("Ollama profile is missing registry_manifest_url: "+[string]$p.id)
    } elseif([string]$p.route -eq 'LiteRT'){
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$p.litert_hf_repo)) ("LiteRT profile is missing litert_hf_repo: "+[string]$p.id)
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$p.litert_source_file)) ("LiteRT profile is missing litert_source_file: "+[string]$p.id)
    } else {
        throw ("Unsupported profile route: "+[string]$p.route)
    }
    Assert-True (-not $ids.ContainsKey([string]$p.id)) ("Duplicate profile id: "+[string]$p.id)
    Assert-True (-not $folders.ContainsKey([string]$p.install_folder)) ("Duplicate install folder: "+[string]$p.install_folder)
    if([bool]$p.verified){
        Assert-True ($null -ne $p.min_ram_gb -and [double]$p.min_ram_gb -gt 0) ("Verified profile has no RAM floor: "+[string]$p.id)
        Assert-True ($null -ne $p.validation_evidence) ("Verified profile has no validation evidence: "+[string]$p.id)
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$p.verification_status)) ("Verified profile has no verification status: "+[string]$p.id)
    }
    $ids[[string]$p.id]=$true
    $folders[[string]$p.install_folder]=$true
}

$routing=Get-Content (Join-Path $repoRoot 'catalog\package-routing.json') -Raw | ConvertFrom-Json
foreach($rule in @($routing.rules)){
    Assert-True ($ids.ContainsKey([string]$rule.profile_id)) ("Routing rule points to missing profile: "+[string]$rule.profile_id)
    $target=@($profiles | Where-Object { [string]$_.id -eq [string]$rule.profile_id } | Select-Object -First 1)[0]
    Assert-True ($null -ne $target -and [bool]$target.verified) ("Routing rule points to an unverified profile: "+[string]$rule.profile_id)
}

& (Join-Path $repoRoot 'build\generate-site-routing.ps1')
$out=Get-Content (Join-Path $repoRoot 'dist\site-installer-routing.json') -Raw | ConvertFrom-Json
Assert-True ([int]$out.configuration_count -gt 100) 'Routing generator did not expand the website configuration space.'
Assert-True ([int]$out.installer_available_count -gt 0) 'No website configuration maps to a verified installer.'

$cpu16=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'cpu-only' -and [int]$_.memory_gb -eq 16 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $cpu16 -and $cpu16.profile_id -eq 'windows-ollama-gemma4-e4b-qat') 'Windows CPU-only 16 GB did not route to validated E4B profile.'

$cpu32=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'cpu-only' -and [int]$_.memory_gb -eq 32 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $cpu32 -and $cpu32.profile_id -eq 'windows-ollama-gemma4-12b-qat') 'Windows CPU-only 32 GB did not route to validated 12B profile.'

$cpu8=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'cpu-only' -and [int]$_.memory_gb -eq 8 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $cpu8 -and $cpu8.status -eq 'no_verified_installer') 'Windows CPU-only 8 GB must stay unverified.'

$gpu24=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'nvidia' -and [int]$_.vram_gb -eq 24 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $gpu24 -and $gpu24.status -eq 'no_verified_installer') '24 GB automatic GPU config should remain reserved until LiteRT is verified.'

Write-Host ("PROFILE / ROUTING CATALOG PASSED: "+$out.configuration_count+" configurations, "+$out.installer_available_count+" installer-ready.")
