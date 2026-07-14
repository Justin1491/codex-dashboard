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

$Script:AppVersion = '2.3.0'
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
$Script:WasBlocked = $false
$Script:ResumeStatus = if ($AutoResume) { 'Armed' } else { 'Disabled' }
$Script:ResumeLog = $null
$Script:OriginalCursorVisible = $true

function Show-Usage {
@"
Codex Usage Dashboard v$($Script:AppVersion) for Windows

Usage:
  .\CodexDashboard.ps1 [options]

Options:
  -AutoResume          Resume the most recent non-interactive Codex session
                       after Codex access becomes available again.
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
if ($Version) { $Script:AppVersion; exit 0 }

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

    $fiveReset = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $primary @('reset_at','resetAt') 0)
    $primaryWindowAvailable = ($null -ne $primary -and $fiveReset -gt 0)
    $fiveUsed = if ($primaryWindowAvailable) { ConvertTo-Percent (Get-ObjectPropertyValue $primary @('used_percent','usedPercent') 0) } else { 0 }
    $primaryMinutes = [int](Get-ObjectPropertyValue $primary @('window_minutes','windowMinutes') 300)
    $primaryWindowLabel = if ($primaryWindowAvailable -and $primaryMinutes -gt 0 -and ($primaryMinutes % 60) -eq 0) { "$([int]($primaryMinutes / 60))-hour" } else { 'Short-term' }
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
        PrimaryWindowAvailable = $primaryWindowAvailable
        PrimaryWindowLabel = $primaryWindowLabel
        FiveUsed = $fiveUsed
        FiveRemaining = 100 - $fiveUsed
        FiveReset = $fiveReset
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

function New-DashboardSegment {
    param(
        [AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Get-DashboardRowText {
    param([object[]]$Segments)
    -join @($Segments | ForEach-Object { [string]$_.Text })
}

function New-UsageBarSegments {
    param([int]$Remaining, [int]$Width = 20)
    $remainingValue = [math]::Max(0,[math]::Min(100,$Remaining))
    $filled = [int][math]::Floor($remainingValue * $Width / 100)
    $empty = $Width - $filled
    @(
        New-DashboardSegment -Text '[' -Color ([ConsoleColor]::Gray)
        New-DashboardSegment -Text ('#' * $filled) -Color ([ConsoleColor]::Green)
        New-DashboardSegment -Text ('-' * $empty) -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text ']' -Color ([ConsoleColor]::Gray)
    )
}

function Get-CountdownColor {
    param([string]$Countdown)
    if ($Countdown -eq 'Ready') { return [ConsoleColor]::Green }
    if ($Countdown -eq 'Unknown') { return [ConsoleColor]::Red }
    return [ConsoleColor]::Yellow
}

function Get-CreditStatusColor {
    param([string]$Status)
    if ($Status -match '(?i)available|active|unused') { return [ConsoleColor]::Green }
    if ($Status -match '(?i)pending|waiting|queued') { return [ConsoleColor]::Yellow }
    if ($Status -match '(?i)expired|failed|invalid|revoked') { return [ConsoleColor]::Red }
    return [ConsoleColor]::Gray
}

function Get-AutoResumeColor {
    param([string]$Status)
    if ($Status -match '(?i)failed|error') { return [ConsoleColor]::Red }
    if ($Status -match '(?i)waiting') { return [ConsoleColor]::Yellow }
    if ($Status -match '(?i)enabled|armed|started') { return [ConsoleColor]::Green }
    if ($Status -match '(?i)disabled|off') { return [ConsoleColor]::DarkGray }
    return [ConsoleColor]::Gray
}

function Write-ColoredDashboardRow {
    param(
        [object[]]$Segments,
        [string]$Pad,
        [int]$Canvas,
        [int]$ScreenWidth
    )

    Write-Host $Pad -NoNewline
    $written = 0
    foreach ($segment in @($Segments)) {
        $available = $Canvas - $written
        if ($available -le 0) { break }
        $text = [string]$segment.Text
        if ($text.Length -gt $available) { $text = $text.Substring(0,$available) }
        if ($text.Length -gt 0) {
            Write-Host $text -ForegroundColor $segment.Color -NoNewline
            $written += $text.Length
        }
    }

    $tail = [math]::Max(0,$ScreenWidth - $Pad.Length - $written)
    Write-Host (' ' * $tail)
}

function Write-PlainDashboardRows {
    param(
        [System.Collections.IEnumerable]$Rows,
        [string]$Pad,
        [int]$Canvas,
        [int]$ScreenWidth
    )

    foreach ($row in $Rows) {
        $text = Get-DashboardRowText -Segments @($row)
        if ($text.Length -gt $Canvas) { $text = $text.Substring(0,$Canvas) }
        $line = ($Pad + $text.PadRight($Canvas)).PadRight($ScreenWidth)
        Write-Host $line
    }
}

function Write-DashboardRows {
    param(
        [System.Collections.IEnumerable]$Rows,
        [string]$Pad,
        [int]$Canvas,
        [int]$ScreenWidth
    )

    try {
        foreach ($row in $Rows) {
            Write-ColoredDashboardRow -Segments @($row) -Pad $Pad -Canvas $Canvas -ScreenWidth $ScreenWidth
        }
    }
    catch {
        try { [Console]::ResetColor() } catch {}
        try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }
        Write-PlainDashboardRows -Rows $Rows -Pad $Pad -Canvas $Canvas -ScreenWidth $ScreenWidth
    }
}

function New-UsageWindowRow {
    param(
        [string]$Label,
        [bool]$Available,
        [int]$Remaining,
        [int]$Used,
        [long]$Reset
    )

    if (-not $Available) {
        return @(
            New-DashboardSegment -Text ('{0,-11} ' -f $Label) -Color ([ConsoleColor]::DarkGray)
            New-DashboardSegment -Text ('{0,-50} {1,-36} {2}' -f 'Temporarily not enforced','No reset scheduled','-') -Color ([ConsoleColor]::DarkGray)
        )
    }

    $segments = [System.Collections.Generic.List[object]]::new()
    [void]$segments.Add((New-DashboardSegment -Text ('{0,-11} ' -f $Label) -Color ([ConsoleColor]::DarkGray)))
    [void]$segments.Add((New-DashboardSegment -Text ('{0,3}% ' -f $Remaining) -Color ([ConsoleColor]::Green)))
    foreach ($segment in @(New-UsageBarSegments -Remaining $Remaining)) { [void]$segments.Add($segment) }
    [void]$segments.Add((New-DashboardSegment -Text ('   {0,3}%       ' -f $Used) -Color ([ConsoleColor]::Gray)))
    [void]$segments.Add((New-DashboardSegment -Text ('{0,-36} ' -f (Format-LocalTime $Reset)) -Color ([ConsoleColor]::Yellow)))
    $countdown = Format-Countdown $Reset
    [void]$segments.Add((New-DashboardSegment -Text $countdown -Color (Get-CountdownColor $countdown)))
    return @($segments)
}

function New-CreditRow {
    param($Credit)
    $countdown = Format-Countdown $Credit.ExpiresAt
    @(
        New-DashboardSegment -Text ('{0,-14} ' -f $Credit.Status) -Color (Get-CreditStatusColor $Credit.Status)
        New-DashboardSegment -Text ('{0,-36} ' -f (Format-LocalTime $Credit.GrantedAt)) -Color ([ConsoleColor]::Gray)
        New-DashboardSegment -Text ('{0,-36} ' -f (Format-LocalTime $Credit.ExpiresAt)) -Color ([ConsoleColor]::Gray)
        New-DashboardSegment -Text $countdown -Color (Get-CountdownColor $countdown)
    )
}

function New-AutoResumeRow {
    param([string]$Status, [string]$Project = $null)
    $segments = [System.Collections.Generic.List[object]]::new()
    [void]$segments.Add((New-DashboardSegment -Text 'Auto-resume: ' -Color ([ConsoleColor]::DarkGray)))
    [void]$segments.Add((New-DashboardSegment -Text $Status -Color (Get-AutoResumeColor $Status)))
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
        [void]$segments.Add((New-DashboardSegment -Text ' | Project: ' -Color ([ConsoleColor]::DarkGray)))
        [void]$segments.Add((New-DashboardSegment -Text $Project -Color ([ConsoleColor]::Gray)))
    }
    return @($segments)
}

function New-FooterRow {
    param([string]$Text)
    @((New-DashboardSegment -Text $Text -Color ([ConsoleColor]::DarkGray)))
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
    $rows = [System.Collections.Generic.List[object]]::new()

    [void]$rows.Add(@(New-DashboardSegment -Text (Center-Line "CODEX USAGE DASHBOARD v$($Script:AppVersion)" $canvas) -Color ([ConsoleColor]::Cyan)))
    [void]$rows.Add(@(New-DashboardSegment -Text (Center-Line "Windows PowerShell | Plan: $($State.Plan)" $canvas) -Color ([ConsoleColor]::Cyan)))
    [void]$rows.Add(@(New-DashboardSegment -Text ('-' * $canvas) -Color ([ConsoleColor]::Cyan)))

    $access = if ($State.Allowed -and -not $State.LimitReached) { 'AVAILABLE' } else { 'RATE LIMITED' }
    $accessColor = if ($access -eq 'AVAILABLE') { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    [void]$rows.Add(@(
        New-DashboardSegment -Text 'Access: ' -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text ('{0,-14}' -f $access) -Color $accessColor
        New-DashboardSegment -Text '  Last API refresh: ' -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text $State.RefreshedAt.ToString('h:mm:ss tt') -Color ([ConsoleColor]::Gray)
    ))

    [void]$rows.Add(@())
    [void]$rows.Add(@(New-DashboardSegment -Text 'USAGE WINDOWS' -Color ([ConsoleColor]::Cyan)))
    [void]$rows.Add(@(New-DashboardSegment -Text 'Window      Remaining                    Used       Resets                               Countdown' -Color ([ConsoleColor]::DarkGray)))
    [void]$rows.Add((New-UsageWindowRow -Label $State.PrimaryWindowLabel -Available $State.PrimaryWindowAvailable -Remaining $State.FiveRemaining -Used $State.FiveUsed -Reset $State.FiveReset))
    [void]$rows.Add((New-UsageWindowRow -Label 'Weekly' -Available $true -Remaining $State.WeekRemaining -Used $State.WeekUsed -Reset $State.WeekReset))

    [void]$rows.Add(@())
    [void]$rows.Add(@(
        New-DashboardSegment -Text 'RESET CREDITS  ' -Color ([ConsoleColor]::Cyan)
        New-DashboardSegment -Text 'Available: ' -Color ([ConsoleColor]::DarkGray)
        New-DashboardSegment -Text ([string]$State.AvailableCredits) -Color ([ConsoleColor]::Green)
    ))
    [void]$rows.Add(@(New-DashboardSegment -Text 'Status         Granted                              Expires                              Countdown' -Color ([ConsoleColor]::DarkGray)))

    if (@($State.Credits).Count -eq 0) {
        [void]$rows.Add(@(New-DashboardSegment -Text 'No reset-credit records returned.' -Color ([ConsoleColor]::DarkGray)))
    }
    else {
        foreach ($credit in @($State.Credits)) { [void]$rows.Add((New-CreditRow -Credit $credit)) }
    }

    [void]$rows.Add(@())
    [void]$rows.Add((New-AutoResumeRow -Status $Script:ResumeStatus))
    if ($Script:ResumeLog) {
        [void]$rows.Add(@(
            New-DashboardSegment -Text 'Resume log: ' -Color ([ConsoleColor]::DarkGray)
            New-DashboardSegment -Text $Script:ResumeLog -Color ([ConsoleColor]::Gray)
        ))
    }
    if ($Script:LastRefreshError) {
        [void]$rows.Add(@(
            New-DashboardSegment -Text 'Warning: ' -Color ([ConsoleColor]::Red)
            New-DashboardSegment -Text $Script:LastRefreshError -Color ([ConsoleColor]::Red)
        ))
    }
    [void]$rows.Add((New-FooterRow -Text "Terminal: $($size.Width)x$($size.Height)  |  API refresh: ${Refresh}s  |  Ctrl+C to exit"))

    while ($rows.Count -lt ($size.Height - 1)) { [void]$rows.Add(@()) }
    Write-DashboardRows -Rows $rows -Pad $pad -Canvas $canvas -ScreenWidth $size.Width
}

function Start-CodexResume {
    param($State)
    if (-not $AutoResume) { return }
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
                $blocked = (-not $Script:LastGoodState.Allowed -or $Script:LastGoodState.LimitReached)
                if ($blocked) {
                    $Script:WasBlocked = $true
                    $Script:ResumeStatus = 'Waiting for Codex access to reset'
                } elseif ($Script:WasBlocked) {
                    $Script:WasBlocked = $false
                    Start-CodexResume -State $Script:LastGoodState
                } elseif ($AutoResume -and $Script:ResumeStatus -ne 'Started') {
                    $Script:ResumeStatus = 'Armed'
                }
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
