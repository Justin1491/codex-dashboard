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
$coreText = $coreText.Replace("`r`n", "`n")
$coreText = $coreText.Replace("`$Script:AppVersion = '2.3.0'", "`$Script:AppVersion = '2.5.0'")

$oldState = @'
$Script:WasBlocked = $false
$Script:ResumeStatus = if ($AutoResume) { 'Armed' } else { 'Disabled' }
$Script:ResumeLog = $null
'@
$newState = @'
$Script:WasBlocked = $false
$Script:AutoResumeEnabled = [bool]$AutoResume
$Script:ResumeProject = $Project
$Script:ResumePrompt = $Prompt
$Script:ResumeStatus = if ($Script:AutoResumeEnabled) { 'Armed' } else { 'Disabled' }
$Script:ResumeLog = $null
'@
$coreText = $coreText.Replace($oldState.Replace("`r`n", "`n"), $newState.Replace("`r`n", "`n"))

$oldDisplay = @'
    $lines.Add("Auto-resume: $($Script:ResumeStatus)")
    if ($Script:ResumeLog) { $lines.Add("Resume log: $($Script:ResumeLog)") }
    if ($Script:LastRefreshError) { $lines.Add("Warning: $($Script:LastRefreshError)") }
    $lines.Add("Terminal: $($size.Width)x$($size.Height)  |  API refresh: ${Refresh}s  |  Ctrl+C to exit")
'@
$newDisplay = @'
    $autoResumeLine = "Auto-resume: $($Script:ResumeStatus)"
    if ($Script:AutoResumeEnabled) { $autoResumeLine += " | Project: $($Script:ResumeProject)" }
    $lines.Add($autoResumeLine)
    if ($Script:ResumeLog) { $lines.Add("Resume log: $($Script:ResumeLog)") }
    if ($Script:LastRefreshError) { $lines.Add("Warning: $($Script:LastRefreshError)") }
    $lines.Add("Terminal: $($size.Width)x$($size.Height)  |  API refresh: ${Refresh}s  |  Press A to configure auto-resume | Control+C to exit.")
'@
$coreText = $coreText.Replace($oldDisplay.Replace("`r`n", "`n"), $newDisplay.Replace("`r`n", "`n"))

$interactiveFunctions = @'
function Resolve-InteractiveProjectPath {
    param([string]$Path)

    $candidate = if ([string]::IsNullOrWhiteSpace($Path)) { $Script:ResumeProject } else { $Path.Trim() }
    if ($candidate -eq '~') {
        $candidate = $HOME
    }
    elseif ($candidate.StartsWith('~/') -or $candidate.StartsWith('~\')) {
        $candidate = Join-Path $HOME $candidate.Substring(2)
    }

    $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
    try { return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { return $null }
}

function Wait-InteractiveAcknowledgement {
    [void](Read-Host 'Press Enter to return to the dashboard')
}

function Restore-DashboardAfterPrompt {
    Clear-Host
    try { [Console]::CursorVisible = $false } catch {}
    if ($null -ne $Script:LastGoodState) { Render-Dashboard -State $Script:LastGoodState }
}

function Invoke-AutoResumeConfiguration {
    try { [Console]::CursorVisible = $true } catch {}
    Clear-Host
    Write-Host 'Configure Automatic Resume'
    Write-Host ''

    if ($Script:AutoResumeEnabled) {
        Write-Host 'Auto-resume is currently armed for:'
        Write-Host "  $($Script:ResumeProject)"
        Write-Host ''
        Write-Host '[C] Change project'
        Write-Host '[D] Disable auto-resume'
        Write-Host '[Enter] Cancel'
        Write-Host ''
        $action = Read-Host 'Choice'

        if ($action -match '^[dD]$') {
            $Script:AutoResumeEnabled = $false
            $Script:ResumeStatus = 'Disabled'
            $Script:WasBlocked = $false
            Restore-DashboardAfterPrompt
            return
        }
        if ($action -notmatch '^[cC]$') {
            Restore-DashboardAfterPrompt
            return
        }
    }

    $projectInput = Read-Host "Project folder [$($Script:ResumeProject)]"
    $candidate = Resolve-InteractiveProjectPath -Path $projectInput
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        Write-Host ''
        Write-Host "Project directory not found: $(if ($projectInput) { $projectInput } else { $Script:ResumeProject })" -ForegroundColor Red
        Wait-InteractiveAcknowledgement
        Restore-DashboardAfterPrompt
        return
    }

    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host 'The codex command was not found. Install or sign in to Codex first.' -ForegroundColor Red
        Wait-InteractiveAcknowledgement
        Restore-DashboardAfterPrompt
        return
    }

    Write-Host ''
    Write-Host 'Arm auto-resume for:'
    Write-Host "  $candidate"
    Write-Host ''
    $confirmation = Read-Host 'Confirm? [Y/n]'
    if ($confirmation -match '^(n|no)$') {
        Restore-DashboardAfterPrompt
        return
    }

    $Script:AutoResumeEnabled = $true
    $Script:ResumeProject = $candidate
    $Script:WasBlocked = (-not $Script:LastGoodState.Allowed -or $Script:LastGoodState.LimitReached)
    if ($Script:WasBlocked) {
        $Script:ResumeStatus = 'Waiting for Codex access to reset'
    }
    else {
        $Script:ResumeStatus = 'Armed; waiting for Codex to become rate limited'
    }

    Restore-DashboardAfterPrompt
}

function Test-InteractiveDashboardKey {
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::A) { Invoke-AutoResumeConfiguration }
        }
    } catch {}
}

'@
$coreText = $coreText.Replace('function Start-CodexResume {', $interactiveFunctions + 'function Start-CodexResume {')
$coreText = $coreText.Replace('if (-not $AutoResume) { return }', 'if (-not $Script:AutoResumeEnabled) { return }')
$coreText = $coreText.Replace('Test-Path -LiteralPath $Project -PathType Container', 'Test-Path -LiteralPath $Script:ResumeProject -PathType Container')
$coreText = $coreText.Replace('$Prompt.Replace(''"'',''\"'')', '$Script:ResumePrompt.Replace(''"'',''\"'')')
$coreText = $coreText.Replace('-WorkingDirectory $Project', '-WorkingDirectory $Script:ResumeProject')
$coreText = $coreText.Replace('elseif ($AutoResume -and $Script:ResumeStatus -ne ''Started'')', 'elseif ($Script:AutoResumeEnabled -and $Script:ResumeStatus -ne ''Started'')')
$coreText = $coreText.Replace("                    `$Script:ResumeStatus = 'Waiting for Codex access to reset'", "                    `$Script:ResumeStatus = if (`$Script:AutoResumeEnabled) { 'Waiting for Codex access to reset' } else { 'Disabled' }")
$coreText = $coreText.Replace("        `$Script:ResumeStatus = 'Waiting for Codex access to reset'", "        `$Script:ResumeStatus = if (`$Script:AutoResumeEnabled) { 'Waiting for Codex access to reset' } else { 'Disabled' }")
$coreText = $coreText.Replace('if ($AutoResume -and -not (Test-Path -LiteralPath $Script:ResumeProject -PathType Container))', 'if ($Script:AutoResumeEnabled -and -not (Test-Path -LiteralPath $Script:ResumeProject -PathType Container))')
$coreText = $coreText.Replace('throw "Project directory not found: $Project"', 'throw "Project directory not found: $($Script:ResumeProject)"')
$coreText = $coreText.Replace('        Render-Dashboard -State $Script:LastGoodState', "        Test-InteractiveDashboardKey`n        Render-Dashboard -State `$Script:LastGoodState")


$requiredOverlays = @(
    "`$Script:AppVersion = '2.5.0'",
    'function Invoke-AutoResumeConfiguration',
    'function Test-InteractiveDashboardKey',
    'Press A to configure auto-resume',
    '$Script:AutoResumeEnabled',
    'if (-not $Script:AutoResumeEnabled) { return }',
    '-WorkingDirectory $Script:ResumeProject',
    '$Script:ResumePrompt.Replace',
    'Test-InteractiveDashboardKey'
)
foreach ($marker in $requiredOverlays) {
    if (-not $coreText.Contains($marker)) { throw "Interactive dashboard overlay failed: $marker" }
}

$coreScript = [ScriptBlock]::Create($coreText)
& $coreScript @PSBoundParameters
exit $LASTEXITCODE
