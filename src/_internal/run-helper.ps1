$ErrorActionPreference='Stop'

param(
    [Parameter(Mandatory=$true)][string]$Python,
    [Parameter(Mandatory=$true)][string]$Agent,
    [Parameter(Mandatory=$true)][string]$Ollama,
    [Parameter(Mandatory=$true)][string]$ModelRoot,
    [Parameter(Mandatory=$true)][string]$HostValue,
    [Parameter(Mandatory=$true)][string]$PidFile,
    [Parameter(Mandatory=$true)][string]$PromptFile,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [Parameter(Mandatory=$true)][string]$ErrFile,
    [Parameter(Mandatory=$true)][string]$CodeFile,
    [Parameter(Mandatory=$true)][string]$StatusFile
)

$ApiBase="http://$HostValue"

function Set-RunStatus([string]$Text){
    Set-Content -LiteralPath $StatusFile -Value $Text -Encoding UTF8
}

function ApiReady {
    try {
        $r=Invoke-RestMethod -Uri "$ApiBase/api/version" -TimeoutSec 2
        return ($null -ne $r.version)
    } catch {
        return $false
    }
}

try {
    Set-RunStatus 'Starting local model...'

    if(-not(ApiReady)){
        $psi=New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName=$Ollama
        $psi.Arguments='serve'
        $psi.UseShellExecute=$false
        $psi.CreateNoWindow=$true
        $psi.EnvironmentVariables['OLLAMA_HOST']=$HostValue
        $psi.EnvironmentVariables['OLLAMA_MODELS']=$ModelRoot

        $server=New-Object System.Diagnostics.Process
        $server.StartInfo=$psi
        [void]$server.Start()
        $server.Id | Set-Content $PidFile -Encoding ASCII

        $ready=$false
        for($i=0;$i -lt 120;$i++){
            Start-Sleep -Milliseconds 500
            if(ApiReady){$ready=$true;break}
            if($server.HasExited){break}
        }
        if(-not $ready){
            throw 'The local model service did not start.'
        }
    }

    Set-RunStatus 'Running model...'
    $prompt=Get-Content -LiteralPath $PromptFile -Raw
    $oldPrompt=$env:ANTIGRAVITY_LOCAL_PROMPT
    $env:ANTIGRAVITY_LOCAL_PROMPT=$prompt
    try {
        & $Python $Agent 1> $OutFile 2> $ErrFile
        $nativeCode=$LASTEXITCODE
        if($null -eq $nativeCode){$nativeCode=0}
    } finally {
        $env:ANTIGRAVITY_LOCAL_PROMPT=$oldPrompt
    }

    Set-Content -LiteralPath $CodeFile -Value ([string]$nativeCode) -Encoding ASCII
    Set-RunStatus 'Done'
    exit $nativeCode
} catch {
    $_.Exception.ToString() | Set-Content -LiteralPath $ErrFile -Encoding UTF8
    Set-Content -LiteralPath $CodeFile -Value '1' -Encoding ASCII
    Set-RunStatus 'Failed'
    exit 1
}
