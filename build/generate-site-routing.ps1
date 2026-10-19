$ErrorActionPreference='Stop'

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hardware=Get-Content (Join-Path $repoRoot 'catalog\site-hardware-options.json') -Raw | ConvertFrom-Json
$routing=Get-Content (Join-Path $repoRoot 'catalog\package-routing.json') -Raw | ConvertFrom-Json
$packages=Get-Content (Join-Path $repoRoot 'src\_internal\pack.json') -Raw | ConvertFrom-Json

function Get-VramGb([string]$Hardware){
    if([string]::IsNullOrWhiteSpace($Hardware)){ return $null }
    $m=[regex]::Match($Hardware,'(?i)(?:\(|\s)(\d+)\s*GB\)?')
    if($m.Success){ return [int]$m.Groups[1].Value }
    return $null
}

function Match-Range($Value,$Match,[string]$MinName,[string]$MaxName){
    $min=$Match.PSObject.Properties[$MinName]
    $max=$Match.PSObject.Properties[$MaxName]
    if($null -ne $min -and $null -ne $min.Value){
        if($null -eq $Value -or [double]$Value -lt [double]$min.Value){ return $false }
    }
    if($null -ne $max -and $null -ne $max.Value){
        if($null -eq $Value -or [double]$Value -gt [double]$max.Value){ return $false }
    }
    return $true
}

function Resolve-Profile([string]$Os,[string]$Graphics,[string]$Runtime,$VramGb,$MemoryGb){
    $rule=@($routing.rules | Where-Object {
        @($_.match.os) -contains $Os -and
        @($_.match.graphics) -contains $Graphics -and
        @($_.match.runtime) -contains $Runtime -and
        (Match-Range $VramGb $_.match 'min_vram_gb' 'max_vram_gb') -and
        (Match-Range $MemoryGb $_.match 'min_memory_gb' 'max_memory_gb')
    } | Sort-Object @{Expression={[int]$_.priority};Descending=$true} | Select-Object -First 1)[0]
    if($null -eq $rule){ return $null }
    $profile=@($packages.profiles | Where-Object { [string]$_.id -eq [string]$rule.profile_id } | Select-Object -First 1)[0]
    if($null -eq $profile -or -not [bool]$profile.verified){ return $null }
    return [pscustomobject]@{rule=$rule;profile=$profile}
}

function Add-Row([System.Collections.ArrayList]$Rows,[string]$Os,[string]$Graphics,[string]$Hardware,[object]$Memory,[string]$Runtime){
    $vram=Get-VramGb $Hardware
    $resolved=Resolve-Profile $Os $Graphics $Runtime $vram $Memory
    $row=[ordered]@{
        os=$Os
        graphics=$Graphics
        hardware=$Hardware
        vram_gb=$vram
        memory_gb=$Memory
        runtime=$Runtime
        status=[string]$routing.default_status
        profile_id=$null
        installer_file=$null
        final_check='none'
    }
    if($null -ne $resolved){
        $row.status=[string]$resolved.rule.status
        $row.profile_id=[string]$resolved.profile.id
        $row.installer_file=('profiles/'+[string]$resolved.profile.id+'.exe')
        $row.final_check=[string]$resolved.rule.final_check
    }
    [void]$Rows.Add([pscustomobject]$row)
}

$rows=New-Object System.Collections.ArrayList
$runtimes=@($hardware.runtimes)

foreach($osName in @('windows','macos','linux')){
    $os=$hardware.operating_systems.$osName
    foreach($graphicsName in @($os.graphics.PSObject.Properties.Name)){
        $value=$os.graphics.$graphicsName

        if($graphicsName -eq 'nvidia' -or $graphicsName -eq 'amd'){
            $models=@($value)
            if($models.Count -eq 1 -and [string]$models[0] -eq 'same-as-windows'){
                $models=@($hardware.operating_systems.windows.graphics.$graphicsName)
            }
            foreach($model in $models){
                foreach($runtime in $runtimes){ Add-Row $rows $osName $graphicsName ([string]$model) $null ([string]$runtime) }
            }
            continue
        }

        if($graphicsName -eq 'apple-silicon'){
            foreach($chip in @($value.chips)){
                foreach($mem in @($value.memory_gb)){
                    foreach($runtime in $runtimes){ Add-Row $rows $osName $graphicsName ([string]$chip) ([int]$mem) ([string]$runtime) }
                }
            }
            continue
        }

        if($graphicsName -eq 'cpu-only'){
            foreach($mem in @($value)){
                foreach($runtime in $runtimes){ Add-Row $rows $osName $graphicsName 'CPU only' ([int]$mem) ([string]$runtime) }
            }
        }
    }
}

$outDir=Join-Path $repoRoot 'dist'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out=Join-Path $outDir 'site-installer-routing.json'
$result=[ordered]@{
    schema_version=1
    generated_utc=(Get-Date).ToUniversalTime().ToString('o')
    configuration_count=$rows.Count
    installer_available_count=@($rows | Where-Object { $_.status -eq 'installer_available' }).Count
    no_verified_installer_count=@($rows | Where-Object { $_.status -ne 'installer_available' }).Count
    configurations=@($rows)
}
$result | ConvertTo-Json -Depth 12 | Set-Content $out -Encoding UTF8

Write-Host ("Generated "+$rows.Count+" website configuration routes.")
Write-Host ("Installer available: "+$result.installer_available_count)
Write-Host ("No verified installer yet: "+$result.no_verified_installer_count)
Write-Host ("Routing table: "+$out)
