[CmdletBinding()]
param(
    [switch]$AutoResume,
    [string]$Project = (Get-Location).Path,
    [ValidateRange(1,86400)][int]$Refresh = 60,
    [string]$Prompt = 'The rate limit has reset. Review the current repository and session state, then continue the interrupted task from the last safe point. Do not repeat completed work.',
    [switch]$Help,
    [switch]$Version
)

# Thin compatibility launcher. The stable v2.3 dashboard core remains unchanged;
# this file only normalizes OpenAI's usage-window response before the core reads it.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$corePath = Join-Path $scriptDir 'CodexDashboardCore.ps1'
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cachePath = Join-Path $codexHome 'dashboard-window-cache.json'
$usageEndpoint = if ($env:CODEX_USAGE_ENDPOINT) { $env:CODEX_USAGE_ENDPOINT } else { 'https://chatgpt.com/backend-api/wham/usage' }

if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Stable dashboard core not found: $corePath"
}

function Get-NormalizedProperty {
    param($Object,[string[]]$Names,$Default=$null)
    if ($null -eq $Object) { return $Default }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and [string]$property.Value -ne '') { return $property.Value }
    }
    return $Default
}

function Set-NormalizedProperty {
    param($Object,[string]$Name,$Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $property.Value = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function ConvertTo-NormalizedEpoch {
    param($Value)
    if ($null -eq $Value) { return 0L }
    $number = 0L
    if ([long]::TryParse([string]$Value,[ref]$number)) {
        if ($number -gt 99999999999) { return [long]($number / 1000) }
        return $number
    }
    try { return [DateTimeOffset]::Parse([string]$Value).ToUnixTimeSeconds() } catch { return 0L }
}

function Load-NormalizedCache {
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cache = @{}
            foreach ($property in $raw.PSObject.Properties) {
                $cache[$property.Name] = [pscustomobject]@{
                    ResetAt = [long](Get-NormalizedProperty $property.Value @('reset_at','ResetAt') 0)
                    Kind = [string](Get-NormalizedProperty $property.Value @('kind','Kind') '')
                }
            }
            return $cache
        } catch {}
    }
    return @{}
}

function Save-NormalizedCache {
    param([hashtable]$Cache)
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $cachePath) -Force | Out-Null
        $out = @{}
        foreach ($key in $Cache.Keys) {
            $out[$key] = @{ reset_at = [long]$Cache[$key].ResetAt; kind = [string]$Cache[$key].Kind }
        }
        $out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    } catch {}
}

function Classify-NormalizedWindow {
    param([string]$Slot,$Window,[bool]$OnlyWindow,[hashtable]$Cache)
    $minutes = [int](Get-NormalizedProperty $Window @('window_minutes','windowMinutes','window_size_minutes','windowSizeMinutes') 0)
    $resetAt = ConvertTo-NormalizedEpoch (Get-NormalizedProperty $Window @('reset_at','resetAt') 0)

    if ($minutes -ge 4320) { return 'weekly' }
    if ($minutes -gt 0 -and $minutes -le 720) { return 'short' }

    if ($Cache.ContainsKey($Slot)) {
        $cached = $Cache[$Slot]
        if ($cached.ResetAt -eq $resetAt -and $cached.Kind) { return $cached.Kind }
        if ($resetAt -gt $cached.ResetAt -and $cached.ResetAt -gt 0) {
            $delta = $resetAt - $cached.ResetAt
            if ($delta -ge 259200) { return 'weekly' }
            if ($delta -le 43200) { return 'short' }
        }
        if ($cached.Kind -eq 'weekly' -or $cached.Kind -eq 'short') { return $cached.Kind }
    }

    if ($OnlyWindow) { return 'weekly' }
    $remaining = $resetAt - [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($remaining -gt 43200) { return 'weekly' }
    return 'short'
}

function Normalize-UsageResponse {
    param($Response)
    $clone = ($Response | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    $rateLimit = Get-NormalizedProperty $clone @('rate_limit','rateLimit')
    if ($null -eq $rateLimit) { return $clone }

    $primary = Get-NormalizedProperty $rateLimit @('primary_window','primaryWindow')
    $secondary = Get-NormalizedProperty $rateLimit @('secondary_window','secondaryWindow')
    $cache = Load-NormalizedCache
    $short = $null
    $weekly = $null

    if ($null -ne $primary -and $null -ne $secondary) {
        $primaryKind = Classify-NormalizedWindow -Slot 'primary' -Window $primary -OnlyWindow:$false -Cache $cache
        $secondaryKind = Classify-NormalizedWindow -Slot 'secondary' -Window $secondary -OnlyWindow:$false -Cache $cache

        if ($primaryKind -eq $secondaryKind) {
            $primaryReset = ConvertTo-NormalizedEpoch (Get-NormalizedProperty $primary @('reset_at','resetAt') 0)
            $secondaryReset = ConvertTo-NormalizedEpoch (Get-NormalizedProperty $secondary @('reset_at','resetAt') 0)
            if ($primaryReset -lt $secondaryReset) { $primaryKind = 'short'; $secondaryKind = 'weekly' }
            else { $primaryKind = 'weekly'; $secondaryKind = 'short' }
        }

        if ($primaryKind -eq 'short') { $short = $primary } else { $weekly = $primary }
        if ($secondaryKind -eq 'short') { $short = $secondary } else { $weekly = $secondary }
        $cache['primary'] = [pscustomobject]@{ ResetAt = ConvertTo-NormalizedEpoch (Get-NormalizedProperty $primary @('reset_at','resetAt') 0); Kind = $primaryKind }
        $cache['secondary'] = [pscustomobject]@{ ResetAt = ConvertTo-NormalizedEpoch (Get-NormalizedProperty $secondary @('reset_at','resetAt') 0); Kind = $secondaryKind }
    }
    elseif ($null -ne $primary) {
        $kind = Classify-NormalizedWindow -Slot 'primary' -Window $primary -OnlyWindow:$true -Cache $cache
        if ($kind -eq 'short') { $short = $primary } else { $weekly = $primary }
        $cache['primary'] = [pscustomobject]@{ ResetAt = ConvertTo-NormalizedEpoch (Get-NormalizedProperty $primary @('reset_at','resetAt') 0); Kind = $kind }
    }
    elseif ($null -ne $secondary) {
        $kind = Classify-NormalizedWindow -Slot 'secondary' -Window $secondary -OnlyWindow:$true -Cache $cache
        if ($kind -eq 'short') { $short = $secondary } else { $weekly = $secondary }
        $cache['secondary'] = [pscustomobject]@{ ResetAt = ConvertTo-NormalizedEpoch (Get-NormalizedProperty $secondary @('reset_at','resetAt') 0); Kind = $kind }
    }

    Set-NormalizedProperty -Object $rateLimit -Name 'primary_window' -Value $short
    Set-NormalizedProperty -Object $rateLimit -Name 'secondary_window' -Value $weekly
    Save-NormalizedCache -Cache $cache
    return $clone
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param(
        [string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSec
    )

    $parameters = @{}
    if ($Method) { $parameters.Method = $Method }
    $parameters.Uri = $Uri
    if ($Headers) { $parameters.Headers = $Headers }
    if ($TimeoutSec) { $parameters.TimeoutSec = $TimeoutSec }

    $response = Microsoft.PowerShell.Utility\Invoke-RestMethod @parameters
    if ($Uri -eq $usageEndpoint) { return Normalize-UsageResponse -Response $response }
    return $response
}

$coreText = Get-Content -LiteralPath $corePath -Raw -Encoding UTF8
$coreText = $coreText.Replace("`$Script:AppVersion = '2.3.0'", "`$Script:AppVersion = '2.4.3'")
$coreScript = [ScriptBlock]::Create($coreText)
& $coreScript @PSBoundParameters
exit $LASTEXITCODE
