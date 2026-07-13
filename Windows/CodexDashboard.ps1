[CmdletBinding()]
param(
    [switch]$AutoResume,
    [string]$Project = (Get-Location).Path,
    [ValidateRange(1,86400)][int]$Refresh = 60,
    [string]$Prompt = 'The rate limit has reset. Review the current repository and session state, then continue the interrupted task from the last safe point. Do not repeat completed work.',
    [switch]$Help,
    [switch]$Version
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$Script:AppVersion = '2.4.1'
$Script:UsageEndpoint = if ($env:CODEX_USAGE_ENDPOINT) { $env:CODEX_USAGE_ENDPOINT } else { 'https://chatgpt.com/backend-api/wham/usage' }
$Script:CreditsEndpoint = if ($env:CODEX_CREDITS_ENDPOINT) { $env:CODEX_CREDITS_ENDPOINT } else { 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits' }
$Script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Script:AuthPath = Join-Path $Script:CodexHome 'auth.json'
$Script:CachePath = Join-Path $Script:CodexHome 'dashboard-window-cache.json'
$Script:MinimumWidth = 116
$Script:MaximumWidth = 160
$Script:LastWidth = 120
$Script:LastHeight = 30
$Script:LastGoodState = $null
$Script:LastRefreshError = $null
$Script:WasBlocked = $false
$Script:ResumeStatus = if ($AutoResume) { 'Armed' } else { 'Disabled' }
$Script:ResumeLog = $null
$Script:OriginalCursorVisible = $true
$Script:WindowCache = @{}

function Show-Usage {
@"
Codex Usage Dashboard v$($Script:AppVersion) for Windows

Usage:
  .\CodexDashboard.ps1 [options]

Options:
  -AutoResume          Resume Codex after access becomes available again.
  -Project PATH        Project directory used for resume --last.
  -Refresh SECONDS     API refresh interval. Default: 60.
  -Prompt TEXT         Continuation instruction sent to Codex.
  -Version             Print the version.
  -Help                Show this help.
"@
}

if ($Help) { Show-Usage; exit 0 }
if ($Version) { $Script:AppVersion; exit 0 }

function Get-ObjectPropertyValue {
    param([object]$Object, [string[]]$Names, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and "$($property.Value)" -ne '') { return $property.Value }
    }
    return $Default
}

function Get-CodexAuth {
    if (-not (Test-Path -LiteralPath $Script:AuthPath -PathType Leaf)) { throw "Codex authentication file not found: $($Script:AuthPath)" }
    $auth = Get-Content -LiteralPath $Script:AuthPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $token = Get-ObjectPropertyValue $auth @('access_token','accessToken')
    if (-not $token -and $auth.tokens) { $token = Get-ObjectPropertyValue $auth.tokens @('access_token','accessToken') }
    $accountId = Get-ObjectPropertyValue $auth @('account_id','accountId','chatgpt_account_id')
    if (-not $accountId -and $auth.tokens) { $accountId = Get-ObjectPropertyValue $auth.tokens @('account_id','accountId','chatgpt_account_id') }
    if (-not $token -or -not $accountId) { throw 'Authentication values were not found in auth.json.' }
    [pscustomobject]@{ Token = [string]$token; AccountId = [string]$accountId }
}

function Invoke-CodexJsonRequest {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)]$Auth)
    $headers = @{ Authorization = "Bearer $($Auth.Token)"; 'ChatGPT-Account-ID' = $Auth.AccountId; originator = 'Codex Desktop' }
    Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 20
}

function ConvertTo-EpochSeconds {
    param($Value)
    if ($null -eq $Value) { return 0L }
    $number = 0L
    if ([long]::TryParse([string]$Value, [ref]$number)) {
        if ($number -gt 99999999999) { return [long]($number / 1000) }
        return $number
    }
    try { return [DateTimeOffset]::Parse([string]$Value).ToUnixTimeSeconds() } catch { return 0L }
}

function ConvertTo-Percent {
    param($Value)
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [ref]$number)) { return 0 }
    [int][math]::Max(0,[math]::Min(100,[math]::Round($number)))
}

function Load-WindowCache {
    $Script:WindowCache = @{}
    if (-not (Test-Path -LiteralPath $Script:CachePath -PathType Leaf)) { return }
    try {
        $raw = Get-Content -LiteralPath $Script:CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $raw.PSObject.Properties) {
            $Script:WindowCache[$property.Name] = [pscustomobject]@{
                ResetAt = [long](Get-ObjectPropertyValue $property.Value @('reset_at','ResetAt') 0)
                Kind = [string](Get-ObjectPropertyValue $property.Value @('kind','Kind') '')
            }
        }
    } catch { $Script:WindowCache = @{} }
}

function Save-WindowCache {
    try {
        if (-not (Test-Path -LiteralPath $Script:CodexHome)) { New-Item -ItemType Directory -Path $Script:CodexHome -Force | Out-Null }
        $out = @{}
        foreach ($key in $Script:WindowCache.Keys) { $out[$key] = @{ reset_at = [long]$Script:WindowCache[$key].ResetAt; kind = [string]$Script:WindowCache[$key].Kind } }
        $out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Script:CachePath -Encoding UTF8
    } catch {}
}

function Set-WindowCacheEntry {
    param([string]$Slot,[long]$ResetAt,[string]$Kind)
    $Script:WindowCache[$Slot] = [pscustomobject]@{ ResetAt = $ResetAt; Kind = $Kind }
}

function Classify-Window {
    param([string]$Slot,[int]$Minutes,[long]$ResetAt)
    if ($Minutes -ge 4320) { return 'weekly' }
    if ($Minutes -gt 0 -and $Minutes -le 720) { return 'short' }
    if ($Script:WindowCache.ContainsKey($Slot)) {
        $cached = $Script:WindowCache[$Slot]
        if ($cached.ResetAt -eq $ResetAt -and $cached.Kind) { return $cached.Kind }
        if ($ResetAt -gt $cached.ResetAt -and $cached.ResetAt -gt 0) {
            $delta = $ResetAt - $cached.ResetAt
            if ($delta -ge 259200) { return 'weekly' }
            if ($delta -le 43200) { return 'short' }
        }
        if ($cached.Kind -eq 'weekly') { return 'weekly' }
    }
    $remaining = $ResetAt - [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($remaining -gt 43200) { return 'weekly' }
    return 'ambiguous'
}

function Get-WindowObject {
    param([string]$Slot,$Raw)
    if ($null -eq $Raw) { return $null }
    [pscustomobject]@{
        Slot = $Slot
        Used = ConvertTo-Percent (Get-ObjectPropertyValue $Raw @('used_percent','usedPercent') 0)
        ResetAt = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $Raw @('reset_at','resetAt') 0)
        Minutes = [int](Get-ObjectPropertyValue $Raw @('window_minutes','windowMinutes','window_size_minutes','windowSizeMinutes') 0)
        Kind = ''
    }
}

function Normalize-CodexState {
    param($Usage,$Credits)
    $rateLimit = Get-ObjectPropertyValue $Usage @('rate_limit','rateLimit')
    $primary = Get-WindowObject 'primary' (Get-ObjectPropertyValue $rateLimit @('primary_window','primaryWindow'))
    $secondary = Get-WindowObject 'secondary' (Get-ObjectPropertyValue $rateLimit @('secondary_window','secondaryWindow'))
    $windows = @($primary,$secondary) | Where-Object { $null -ne $_ }

    if ($windows.Count -eq 2 -and $windows[0].Minutes -eq 0 -and $windows[1].Minutes -eq 0) {
        $ordered = @($windows | Sort-Object ResetAt)
        $ordered[0].Kind = 'short'; $ordered[1].Kind = 'weekly'
    } else {
        foreach ($window in $windows) { $window.Kind = Classify-Window -Slot $window.Slot -Minutes $window.Minutes -ResetAt $window.ResetAt }
    }

    foreach ($window in $windows) { if ($window.Kind -ne 'ambiguous') { Set-WindowCacheEntry -Slot $window.Slot -ResetAt $window.ResetAt -Kind $window.Kind } }
    Save-WindowCache

    $short = $windows | Where-Object Kind -eq 'short' | Select-Object -First 1
    $weekly = $windows | Where-Object Kind -eq 'weekly' | Select-Object -First 1
    $ambiguous = $windows | Where-Object Kind -eq 'ambiguous' | Select-Object -First 1

    $records = @()
    if ($Credits) {
        foreach ($record in @(Get-ObjectPropertyValue $Credits @('credits','records') @())) {
            $records += [pscustomobject]@{
                Status = [string](Get-ObjectPropertyValue $record @('status','state') 'unknown')
                GrantedAt = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $record @('granted_at','grantedAt') 0)
                ExpiresAt = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $record @('expires_at','expiresAt') 0)
            }
        }
    }

    $available = Get-ObjectPropertyValue $Credits @('available_count','availableCount','available') $null
    if ($null -eq $available) { $available = @($records | Where-Object { $_.Status -match 'available|active|unused' }).Count }

    [pscustomobject]@{
        Plan = [string](Get-ObjectPropertyValue $Usage @('plan_type','planType') 'unknown')
        Allowed = [bool](Get-ObjectPropertyValue $rateLimit @('allowed') $false)
        LimitReached = [bool](Get-ObjectPropertyValue $rateLimit @('limit_reached','limitReached') $false)
        Short = $short
        Weekly = $weekly
        Ambiguous = $ambiguous
        AvailableCredits = [int]$available
        Credits = @($records)
        RefreshedAt = Get-Date
    }
}

function Get-CodexState {
    param($Auth)
    $usage = Invoke-CodexJsonRequest -Uri $Script:UsageEndpoint -Auth $Auth
    $credits = $null
    try { $credits = Invoke-CodexJsonRequest -Uri $Script:CreditsEndpoint -Auth $Auth } catch { $Script:LastRefreshError = "Credit endpoint: $($_.Exception.Message)" }
    Normalize-CodexState -Usage $usage -Credits $credits
}

function Get-ConsoleSize {
    try {
        $width = [Console]::WindowWidth; $height = [Console]::WindowHeight
        if ($width -gt 0 -and $height -gt 0) { $Script:LastWidth = $width; $Script:LastHeight = $height }
    } catch {}
    [pscustomobject]@{ Width = $Script:LastWidth; Height = $Script:LastHeight }
}

function Format-LocalTime {
    param([long]$Epoch)
    if ($Epoch -le 0) { return '-' }
    try { [DateTimeOffset]::FromUnixTimeSeconds($Epoch).LocalDateTime.ToString('MMM d, yyyy h:mm:ss tt zzz') } catch { '-' }
}

function Format-Countdown {
    param([long]$Epoch)
    if ($Epoch -le 0) { return '-' }
    $seconds = $Epoch - [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($seconds -le 0) { return 'READY' }
    $span = [TimeSpan]::FromSeconds($seconds)
    return ('{0}d {1:00}h {2:00}m {3:00}s' -f $span.Days,$span.Hours,$span.Minutes,$span.Seconds)
}

function New-AsciiBar {
    param([int]$Remaining,[int]$Width=20)
    $remaining = [math]::Max(0,[math]::Min(100,$Remaining)); $filled = [int][math]::Floor($remaining*$Width/100)
    '[' + ('#' * $filled) + ('-' * ($Width-$filled)) + ']'
}

function Center-Line {
    param([string]$Text,[int]$Width)
    if ($Text.Length -ge $Width) { return $Text.Substring(0,$Width) }
    $left = [int][math]::Floor(($Width-$Text.Length)/2)
    (' ' * $left) + $Text
}

function Get-UsageLine {
    param([string]$Label,$Window,[switch]$Unavailable)
    if ($Unavailable) { return ('{0,-11} {1,-29} {2,-7} {3,-35} {4}' -f $Label,'Temporarily not enforced','-','No reset scheduled','-') }
    if ($null -eq $Window) { return $null }
    $remaining = 100 - $Window.Used
    return ('{0,-11} {1,3}% {2}   {3,3}%       {4,-35} {5}' -f $Label,$remaining,(New-AsciiBar $remaining),$Window.Used,(Format-LocalTime $Window.ResetAt),(Format-Countdown $Window.ResetAt))
}

function Build-Frame {
    param($State)
    $size = Get-ConsoleSize
    $canvas = [math]::Min($Script:MaximumWidth,[math]::Max($Script:MinimumWidth,$size.Width-4))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Center-Line "CODEX USAGE DASHBOARD v$($Script:AppVersion)" $canvas))
    $lines.Add((Center-Line "Windows PowerShell | Plan: $($State.Plan)" $canvas))
    $lines.Add(('-' * $canvas))
    $access = if ($State.Allowed -and -not $State.LimitReached) { 'AVAILABLE' } else { 'RATE LIMITED' }
    $lines.Add(('Access: {0,-14}  Last API refresh: {1}' -f $access,$State.RefreshedAt.ToString('h:mm:ss tt')))
    $lines.Add('')
    $lines.Add('USAGE WINDOWS')
    $lines.Add('Window      Remaining                    Used       Resets                               Countdown')
    if ($null -ne $State.Short) {
        $label = 'Short-term'
        if ($State.Short.Minutes -gt 0 -and ($State.Short.Minutes % 60) -eq 0) { $label = "$([int]($State.Short.Minutes/60))-hour" }
        $lines.Add((Get-UsageLine -Label $label -Window $State.Short))
    } else { $lines.Add((Get-UsageLine -Label 'Short-term' -Window $null -Unavailable)) }
    if ($null -ne $State.Weekly) { $lines.Add((Get-UsageLine -Label 'Weekly' -Window $State.Weekly)) }
    if ($null -ne $State.Ambiguous) { $lines.Add((Get-UsageLine -Label 'Usage window' -Window $State.Ambiguous)) }
    $lines.Add('')
    $lines.Add("RESET CREDITS  Available: $($State.AvailableCredits)")
    $lines.Add('Status         Granted                              Expires                              Countdown')
    if (@($State.Credits).Count -eq 0) { $lines.Add('No reset-credit records returned.') }
    else {
        foreach ($credit in @($State.Credits)) {
            $lines.Add(('{0,-14} {1,-36} {2,-36} {3}' -f $credit.Status,(Format-LocalTime $credit.GrantedAt),(Format-LocalTime $credit.ExpiresAt),(Format-Countdown $credit.ExpiresAt)))
        }
    }
    $lines.Add('')
    $lines.Add("Auto-resume: $($Script:ResumeStatus)")
    if ($Script:ResumeLog) { $lines.Add("Resume log: $($Script:ResumeLog)") }
    if ($Script:LastRefreshError) { $lines.Add("Warning: $($Script:LastRefreshError)") }
    $lines.Add("Terminal: $($size.Width)x$($size.Height) | API refresh: ${Refresh}s | Countdown: 1s | Ctrl+C to exit")
    [pscustomobject]@{ Lines = $lines; Canvas = $canvas; Size = $size }
}

function Render-Frame {
    param($State)
    $frame = Build-Frame -State $State
    $pad = ' ' * [math]::Max(0,[int](($frame.Size.Width-$frame.Canvas)/2))
    try { [Console]::SetCursorPosition(0,0) } catch { return }
    $output = New-Object System.Collections.Generic.List[string]
    foreach ($line in $frame.Lines) {
        $trimmed = if ($line.Length -gt $frame.Canvas) { $line.Substring(0,$frame.Canvas) } else { $line }
        $output.Add($pad + $trimmed.PadRight($frame.Canvas))
    }
    while ($output.Count -lt ($frame.Size.Height-1)) { $output.Add(' ' * $frame.Size.Width) }
    [Console]::Write(($output -join [Environment]::NewLine))
}

function Start-CodexResume {
    param($State)
    if (-not $AutoResume -or -not $State.Allowed -or $State.LimitReached) { return }
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) { $Script:ResumeStatus = 'Failed: project not found'; return }
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { $Script:ResumeStatus = 'Failed: codex command not found'; return }
    $logDir = Join-Path ([IO.Path]::GetTempPath()) 'CodexDashboard'; New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logPath = Join-Path $logDir ("resume-{0}.out.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $errorLogPath = $logPath.Replace('.out.log','.err.log')
    $escapedPrompt = $Prompt.Replace('"','\"'); $arguments = "exec resume --last `"$escapedPrompt`""
    try {
        Start-Process -FilePath 'codex' -ArgumentList $arguments -WorkingDirectory $Project -RedirectStandardOutput $logPath -RedirectStandardError $errorLogPath -WindowStyle Hidden | Out-Null
        $Script:ResumeStatus = 'Started'; $Script:ResumeLog = $logPath
    } catch { $Script:ResumeStatus = "Failed: $($_.Exception.Message)" }
}

function Restore-Console {
    try { [Console]::CursorVisible = $Script:OriginalCursorVisible } catch {}
    try { [Console]::ResetColor() } catch {}
}

try {
    if ($AutoResume -and -not (Test-Path -LiteralPath $Project -PathType Container)) { throw "Project directory not found: $Project" }
    $auth = Get-CodexAuth
    Load-WindowCache
    try { $Script:OriginalCursorVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    Clear-Host
    $lastApiRefresh = [DateTime]::MinValue
    while ($true) {
        if (((Get-Date)-$lastApiRefresh).TotalSeconds -ge $Refresh -or $null -eq $Script:LastGoodState) {
            try {
                $Script:LastGoodState = Get-CodexState -Auth $auth
                $Script:LastRefreshError = $null
                $lastApiRefresh = Get-Date
                $blocked = (-not $Script:LastGoodState.Allowed -or $Script:LastGoodState.LimitReached)
                if ($blocked) { $Script:WasBlocked = $true; $Script:ResumeStatus = 'Waiting for Codex access to reset' }
                elseif ($Script:WasBlocked) { $Script:WasBlocked = $false; Start-CodexResume -State $Script:LastGoodState }
                elseif ($AutoResume -and $Script:ResumeStatus -ne 'Started') { $Script:ResumeStatus = 'Armed' }
                else { $Script:ResumeStatus = 'Codex is available' }
            } catch {
                $Script:LastRefreshError = $_.Exception.Message
                if ($null -eq $Script:LastGoodState) { throw }
                $lastApiRefresh = Get-Date
            }
        }
        Render-Frame -State $Script:LastGoodState
        Start-Sleep -Seconds 1
    }
}
catch {
    Restore-Console
    Write-Error $_.Exception.Message
    exit 1
}
finally { Restore-Console }
