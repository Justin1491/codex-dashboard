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

$Script:Version = '2.2.0'
$Script:UsageEndpoint = if ($env:CODEX_USAGE_ENDPOINT) { $env:CODEX_USAGE_ENDPOINT } else { 'https://chatgpt.com/backend-api/wham/usage' }
$Script:CreditsEndpoint = if ($env:CODEX_CREDITS_ENDPOINT) { $env:CODEX_CREDITS_ENDPOINT } else { 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits' }
$Script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Script:AuthPath = Join-Path $Script:CodexHome 'auth.json'
$Script:MinimumWidth = 116
$Script:MinimumHeight = 24
$Script:LastWidth = 120
$Script:LastHeight = 30
$Script:LastGoodState = $null
$Script:LastRefreshError = $null
$Script:ResumeStartedForReset = 0
$Script:ResumeStatus = if ($AutoResume) { 'Armed' } else { 'Disabled' }
$Script:ResumeLog = $null
$Script:OriginalCursorVisible = $true

function Show-Usage {
@"
Codex Usage Dashboard v$($Script:Version) for Windows

Usage:
  .\CodexDashboard.ps1 [options]

Options:
  -AutoResume          Resume the most recent non-interactive Codex session
                       after the five-hour limit resets.
  -Project PATH        Project directory used for resume --last.
                       Default: current directory.
  -Refresh SECONDS     API refresh interval. Default: 60.
  -Prompt TEXT         Continuation instruction sent to Codex.
  -Version             Print the version.
  -Help                Show this help.

Examples:
  .\CodexDashboard.ps1
  .\CodexDashboard.ps1 -AutoResume -Project C:\dev\MyProject
"@
}

if ($Help) { Show-Usage; exit 0 }
if ($Version) { $Script:Version; exit 0 }

function Get-ObjectPropertyValue {
    param([object]$Object, [string[]]$Names, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and "$($property.Value)" -ne '') {
            return $property.Value
        }
    }
    return $Default
}

function Get-CodexAuth {
    if (-not (Test-Path -LiteralPath $Script:AuthPath -PathType Leaf)) {
        throw "Codex authentication file not found: $($Script:AuthPath). Install Codex and sign in first."
    }

    try {
        $auth = Get-Content -LiteralPath $Script:AuthPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Could not parse Codex authentication file: $($Script:AuthPath). $($_.Exception.Message)"
    }

    $token = Get-ObjectPropertyValue $auth @('access_token','accessToken')
    if (-not $token -and $auth.tokens) { $token = Get-ObjectPropertyValue $auth.tokens @('access_token','accessToken') }

    $accountId = Get-ObjectPropertyValue $auth @('account_id','accountId','chatgpt_account_id')
    if (-not $accountId -and $auth.tokens) { $accountId = Get-ObjectPropertyValue $auth.tokens @('account_id','accountId','chatgpt_account_id') }

    if (-not $token) { throw 'The access token was not found in auth.json.' }
    if (-not $accountId) { throw 'The ChatGPT account ID was not found in auth.json.' }

    [pscustomobject]@{ Token = [string]$token; AccountId = [string]$accountId }
}

function Invoke-CodexJsonRequest {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)]$Auth)
    $headers = @{
        Authorization = "Bearer $($Auth.Token)"
        'ChatGPT-Account-ID' = $Auth.AccountId
        originator = 'Codex Desktop'
    }
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
    [int][math]::Max(0, [math]::Min(100, [math]::Round($number)))
}

function Normalize-CodexState {
    param($Usage, $Credits)
    $rateLimit = Get-ObjectPropertyValue $Usage @('rate_limit','rateLimit')
    $primary = Get-ObjectPropertyValue $rateLimit @('primary_window','primaryWindow')
    $secondary = Get-ObjectPropertyValue $rateLimit @('secondary_window','secondaryWindow')

    $fiveUsed = ConvertTo-Percent (Get-ObjectPropertyValue $primary @('used_percent','usedPercent') 0)
    $weekUsed = ConvertTo-Percent (Get-ObjectPropertyValue $secondary @('used_percent','usedPercent') 0)

    $records = @()
    if ($Credits) {
        $rawRecords = Get-ObjectPropertyValue $Credits @('credits','records','rate_limit_reset_credits') @()
        foreach ($record in @($rawRecords)) {
            $records += [pscustomobject]@{
                Status = [string](Get-ObjectPropertyValue $record @('status','state') 'unknown')
                GrantedAt = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $record @('granted_at','grantedAt','created_at','createdAt') 0)
                ExpiresAt = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $record @('expires_at','expiresAt','expiration_at','expirationAt') 0)
            }
        }
    }

    $available = Get-ObjectPropertyValue $Credits @('available_count','availableCount','available') $null
    if ($null -eq $available) { $available = @($records | Where-Object { $_.Status -match 'available|active|unused' }).Count }

    [pscustomobject]@{
        Plan = [string](Get-ObjectPropertyValue $Usage @('plan_type','planType') 'unknown')
        Allowed = [bool](Get-ObjectPropertyValue $rateLimit @('allowed') $false)
        LimitReached = [bool](Get-ObjectPropertyValue $rateLimit @('limit_reached','limitReached') $false)
        FiveUsed = $fiveUsed
        FiveRemaining = 100 - $fiveUsed
        FiveReset = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $primary @('reset_at','resetAt') 0)
        WeekUsed = $weekUsed
        WeekRemaining = 100 - $weekUsed
        WeekReset = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $secondary @('reset_at','resetAt') 0)
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
        $width = [Console]::WindowWidth
        $height = [Console]::WindowHeight
        if ($width -gt 0 -and $height -gt 0) {
            $Script:LastWidth = $width
            $Script:LastHeight = $height
        }
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
    if ($Epoch -le 0) { return 'Unknown' }
    $seconds = $Epoch - [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($seconds -le 0) { return 'Ready' }
    $span = [TimeSpan]::FromSeconds($seconds)
    if ($span.Days -gt 0) { return ('{0}d {1:00}h {2:00}m {3:00}s' -f $span.Days,$span.Hours,$span.Minutes,$span.Seconds) }
    return ('{0:00}h {1:00}m {2:00}s' -f [int]$span.TotalHours,$span.Minutes,$span.Seconds)
}

function New-AsciiBar {
    param([int]$Remaining, [int]$Width = 20)
    $remaining = [math]::Max(0,[math]::Min(100,$Remaining))
    $filled = [int][math]::Floor($remaining * $Width / 100)
    '[' + ('#' * $filled) + ('-' * ($Width - $filled)) + ']'
}

function Center-Line {
    param([string]$Text, [int]$Width)
    if ($Text.Length -ge $Width) { return $Text.Substring(0,$Width) }
    $left = [int][math]::Floor(($Width - $Text.Length) / 2)
    (' ' * $left) + $Text
}

function Write-ColoredLine {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
}

function Render-Dashboard {
    param($State)
    $size = Get-ConsoleSize
    try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }

    if ($size.Width -lt $Script:MinimumWidth -or $size.Height -lt $Script:MinimumHeight) {
        Clear-Host
        Write-ColoredLine 'Codex Dashboard' Cyan
        Write-Host "Terminal is too small. Current: $($size.Width)x$($size.Height). Required: at least $($Script:MinimumWidth)x$($Script:MinimumHeight)."
        Write-Host 'Resize the window. The dashboard will redraw automatically.'
        return
    }

    $canvas = [math]::Min(160,$size.Width - 4)
    $pad = ' ' * [math]::Max(0,[int](($size.Width - $canvas) / 2))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Center-Line "CODEX USAGE DASHBOARD v$($Script:Version)" $canvas))
    $lines.Add((Center-Line "Windows PowerShell | Plan: $($State.Plan)" $canvas))
    $lines.Add(('-' * $canvas))
    $access = if ($State.Allowed -and -not $State.LimitReached) { 'AVAILABLE' } else { 'RATE LIMITED' }
    $lines.Add(('Access: {0,-14}  Last API refresh: {1}' -f $access,$State.RefreshedAt.ToString('h:mm:ss tt')))
    $lines.Add('')
    $lines.Add('USAGE WINDOWS')
    $lines.Add(('Window      Remaining                    Used       Resets                               Countdown'))
    $lines.Add(('5-hour     {0,3}% {1}   {2,3}%       {3,-36} {4}' -f $State.FiveRemaining,(New-AsciiBar $State.FiveRemaining),$State.FiveUsed,(Format-LocalTime $State.FiveReset),(Format-Countdown $State.FiveReset)))
    $lines.Add(('Weekly     {0,3}% {1}   {2,3}%       {3,-36} {4}' -f $State.WeekRemaining,(New-AsciiBar $State.WeekRemaining),$State.WeekUsed,(Format-LocalTime $State.WeekReset),(Format-Countdown $State.WeekReset)))
    $lines.Add('')
    $lines.Add("RESET CREDITS  Available: $($State.AvailableCredits)")
    $lines.Add(('Status         Granted                              Expires                              Countdown'))
    if (@($State.Credits).Count -eq 0) {
        $lines.Add('No reset-credit records returned.')
    } else {
        foreach ($credit in @($State.Credits)) {
            $lines.Add(('{0,-14} {1,-36} {2,-36} {3}' -f $credit.Status,(Format-LocalTime $credit.GrantedAt),(Format-LocalTime $credit.ExpiresAt),(Format-Countdown $credit.ExpiresAt)))
        }
    }
    $lines.Add('')
    $lines.Add("Auto-resume: $($Script:ResumeStatus)")
    if ($Script:ResumeLog) { $lines.Add("Resume log: $($Script:ResumeLog)") }
    if ($Script:LastRefreshError) { $lines.Add("Warning: $($Script:LastRefreshError)") }
    $lines.Add("Terminal: $($size.Width)x$($size.Height)  |  API refresh: ${Refresh}s  |  Ctrl+C to exit")

    $output = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trimmed = if ($line.Length -gt $canvas) { $line.Substring(0,$canvas) } else { $line }
        $output.Add($pad + $trimmed.PadRight($canvas))
    }
    while ($output.Count -lt ($size.Height - 1)) { $output.Add(' ' * $size.Width) }
    Write-Host ($output -join [Environment]::NewLine)
}

function Start-CodexResume {
    param($State)
    if (-not $AutoResume) { return }
    if ($State.FiveReset -le 0 -or $Script:ResumeStartedForReset -eq $State.FiveReset) { return }
    if (-not $State.Allowed -or $State.LimitReached) { return }
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) { $Script:ResumeStatus = "Failed: project not found"; return }
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { $Script:ResumeStatus = 'Failed: codex command not found'; return }

    $logDir = Join-Path ([IO.Path]::GetTempPath()) 'CodexDashboard'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logPath = Join-Path $logDir ("resume-{0}.out.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $errorLogPath = $logPath.Replace('.out.log','.err.log')
    $escapedPrompt = $Prompt.Replace('"','\"')
    $arguments = "exec resume --last `"$escapedPrompt`""
    try {
        Start-Process -FilePath 'codex' -ArgumentList $arguments -WorkingDirectory $Project -RedirectStandardOutput $logPath -RedirectStandardError $errorLogPath -WindowStyle Hidden | Out-Null
        $Script:ResumeStartedForReset = $State.FiveReset
        $Script:ResumeStatus = 'Started'
        $Script:ResumeLog = $logPath
    } catch {
        $Script:ResumeStatus = "Failed: $($_.Exception.Message)"
    }
}

function Restore-Console {
    try { [Console]::CursorVisible = $Script:OriginalCursorVisible } catch {}
    try { [Console]::ResetColor() } catch {}
    try { [Console]::Clear() } catch {}
}

try {
    if ($AutoResume -and -not (Test-Path -LiteralPath $Project -PathType Container)) { throw "Project directory not found: $Project" }
    $auth = Get-CodexAuth
    try { $Script:OriginalCursorVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    Clear-Host

    $lastApiRefresh = [DateTime]::MinValue
    while ($true) {
        if (((Get-Date) - $lastApiRefresh).TotalSeconds -ge $Refresh -or $null -eq $Script:LastGoodState) {
            try {
                $Script:LastGoodState = Get-CodexState -Auth $auth
                $Script:LastRefreshError = $null
                $lastApiRefresh = Get-Date
                Start-CodexResume -State $Script:LastGoodState
            } catch {
                $Script:LastRefreshError = $_.Exception.Message
                if ($null -eq $Script:LastGoodState) { throw }
                $lastApiRefresh = Get-Date
            }
        }
        Render-Dashboard -State $Script:LastGoodState
        Start-Sleep -Seconds 1
    }
}
catch {
    Restore-Console
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    Restore-Console
}
