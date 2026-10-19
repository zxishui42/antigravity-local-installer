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
    $platformKey=if([string]::IsNullOrWhiteSpace([string]$p.platform)){'windows'}else{[string]$p.platform}
    $folderKey=$platformKey+'|'+[string]$p.install_folder
    Assert-True (-not $folders.ContainsKey($folderKey)) ("Duplicate install folder on "+$platformKey+": "+[string]$p.install_folder)
    if([bool]$p.verified){
        $hasRamFloor=($null -ne $p.min_ram_gb -and [double]$p.min_ram_gb -gt 0)
        $hasVramFloor=($null -ne $p.min_vram_gb -and [double]$p.min_vram_gb -gt 0)
        Assert-True ($hasRamFloor -or $hasVramFloor) ("Verified profile has no hardware memory floor: "+[string]$p.id)
        Assert-True ($null -ne $p.validation_evidence) ("Verified profile has no validation evidence: "+[string]$p.id)
        Assert-True (-not[string]::IsNullOrWhiteSpace([string]$p.verification_status)) ("Verified profile has no verification status: "+[string]$p.id)
    }
    $ids[[string]$p.id]=$true
    $folders[$folderKey]=$true
}

$routing=Get-Content (Join-Path $repoRoot 'catalog\package-routing.json') -Raw | ConvertFrom-Json
foreach($rule in @($routing.rules)){
    $status=[string]$rule.status
    $profileId=[string]$rule.profile_id
    $target=$null

    if(-not[string]::IsNullOrWhiteSpace($profileId)){
        Assert-True ($ids.ContainsKey($profileId)) ("Routing rule points to missing profile: "+$profileId)
        $target=@($profiles | Where-Object { [string]$_.id -eq $profileId } | Select-Object -First 1)[0]
    } else {
        Assert-True ($status -eq 'unsupported_route' -or $status -eq 'pending_product_definition') ("Profile-less routing rule has an invalid status: "+[string]$rule.id)
    }

    if($status -eq 'installer_available'){
        Assert-True ($null -ne $target -and [bool]$target.verified -and ($null -eq $target.release -or [bool]$target.release)) ("Released routing rule points to a non-released profile: "+$profileId)
    }
    if($status -eq 'pending_validation'){
        Assert-True ($null -ne $target -and -not [bool]$target.verified) ("Pending validation rule should point to an unverified profile: "+$profileId)
    }
}

& (Join-Path $repoRoot 'build\generate-site-routing.ps1')
$out=Get-Content (Join-Path $repoRoot 'dist\site-installer-routing.json') -Raw | ConvertFrom-Json
Assert-True ([int]$out.configuration_count -gt 100) 'Routing generator did not expand the website configuration space.'
Assert-True ([int]$out.installer_available_count -gt 0) 'No website configuration maps to a verified installer.'

$cpu16=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'cpu-only' -and [int]$_.memory_gb -eq 16 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $cpu16 -and $cpu16.profile_id -eq 'windows-ollama-gemma4-e4b-qat') 'Windows CPU-only 16 GB did not route to validated E4B profile.'

$cpu32=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'cpu-only' -and [int]$_.memory_gb -eq 32 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $cpu32 -and $cpu32.profile_id -eq 'windows-ollama-gemma4-12b-qat') 'Windows CPU-only 32 GB did not route to validated 12B profile.'

$gpu24=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'nvidia' -and [int]$_.vram_gb -eq 24 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $gpu24 -and $gpu24.status -eq 'pending_validation' -and $gpu24.profile_id -eq 'windows-litert-gemma4-26b') '24 GB automatic NVIDIA config should be tracked as pending LiteRT validation.'

$mac16=@($out.configurations | Where-Object { $_.os -eq 'macos' -and $_.graphics -eq 'apple-silicon' -and [int]$_.memory_gb -eq 16 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $mac16 -and $mac16.status -eq 'pending_validation' -and $mac16.profile_id -eq 'macos-ollama-gemma4-e2b') 'macOS Apple Silicon 16 GB Automatic should map to the pending Ollama profile.'

$mac24=@($out.configurations | Where-Object { $_.os -eq 'macos' -and $_.graphics -eq 'apple-silicon' -and [int]$_.memory_gb -eq 24 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $mac24 -and $mac24.status -eq 'pending_validation' -and $mac24.profile_id -eq 'macos-litert-gemma4-26b') 'macOS Apple Silicon 24 GB Automatic should map to the pending LiteRT profile.'

$linuxNvidia24=@($out.configurations | Where-Object { $_.os -eq 'linux' -and $_.graphics -eq 'nvidia' -and [int]$_.vram_gb -eq 24 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $linuxNvidia24 -and $linuxNvidia24.status -eq 'pending_validation' -and $linuxNvidia24.profile_id -eq 'linux-litert-gemma4-26b') 'Linux NVIDIA 24 GB Automatic should map to the pending LiteRT profile.'

$linuxAmdLiteRT=@($out.configurations | Where-Object { $_.os -eq 'linux' -and $_.graphics -eq 'amd' -and $_.runtime -eq 'litert' } | Select-Object -First 1)[0]
Assert-True ($null -ne $linuxAmdLiteRT -and $linuxAmdLiteRT.status -eq 'unsupported_route') 'Linux AMD LiteRT should be classified unsupported.'

$gpu16LiteRT=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'nvidia' -and [int]$_.vram_gb -eq 16 -and $_.runtime -eq 'litert' } | Select-Object -First 1)[0]
Assert-True ($null -ne $gpu16LiteRT -and $gpu16LiteRT.status -eq 'unsupported_route') 'NVIDIA below 24 GB with explicit LiteRT should be marked unsupported.'

$amdLiteRT=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'amd' -and $_.runtime -eq 'litert' } | Select-Object -First 1)[0]
Assert-True ($null -ne $amdLiteRT -and $amdLiteRT.status -eq 'unsupported_route') 'AMD explicit LiteRT should be marked unsupported.'

$cpu8=@($out.configurations | Where-Object { $_.os -eq 'windows' -and $_.graphics -eq 'cpu-only' -and [int]$_.memory_gb -eq 8 -and $_.runtime -eq 'automatic' } | Select-Object -First 1)[0]
Assert-True ($null -ne $cpu8 -and $cpu8.status -eq 'pending_validation' -and $cpu8.profile_id -eq 'windows-ollama-gemma4-e2b-cpu-8gb') 'Windows CPU-only 8 GB should be pending physical validation.'

Write-Host ("PROFILE / ROUTING CATALOG PASSED: "+$out.configuration_count+" configurations, "+$out.installer_available_count+" installer-ready.")
