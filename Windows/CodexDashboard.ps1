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

$Script:AppVersion = '2.4.0'
$Script:UsageEndpoint = if ($env:CODEX_USAGE_ENDPOINT) { $env:CODEX_USAGE_ENDPOINT } else { 'https://chatgpt.com/backend-api/wham/usage' }
$Script:CreditsEndpoint = if ($env:CODEX_CREDITS_ENDPOINT) { $env:CODEX_CREDITS_ENDPOINT } else { 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits' }
$Script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Script:AuthPath = Join-Path $Script:CodexHome 'auth.json'
$Script:CachePath = Join-Path $Script:CodexHome 'dashboard-window-cache.json'
$Script:MinimumWidth = 116
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
  -AutoResume          Resume the most recent non-interactive Codex session
                       after Codex access becomes available again.
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
    if (-not $token -or -not $accountId) { throw 'Required authentication values were not found in auth.json.' }
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
    [int][math]::Max(0, [math]::Min(100, [math]::Round($number)))
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
        if (-not (Test-Path -LiteralPath $Script:CodexHome -PathType Container)) { New-Item -ItemType Directory -Path $Script:CodexHome -Force | Out-Null }
        $out = @{}
        foreach ($key in $Script:WindowCache.Keys) {
            $out[$key] = @{ reset_at = [long]$Script:WindowCache[$key].ResetAt; kind = [string]$Script:WindowCache[$key].Kind }
        }
        $out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Script:CachePath -Encoding UTF8
    } catch {}
}

function Set-WindowCacheEntry {
    param([string]$Slot, [long]$ResetAt, [string]$Kind)
    $Script:WindowCache[$Slot] = [pscustomobject]@{ ResetAt = $ResetAt; Kind = $Kind }
}

function Classify-Window {
    param([string]$Slot, [int]$Minutes, [long]$ResetAt)
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
        if ($cached.Kind -eq 'weekly' -and ($ResetAt - [DateTimeOffset]::Now.ToUnixTimeSeconds()) -le 43200) { return 'weekly' }
    }

    $remaining = $ResetAt - [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($remaining -gt 43200) { return 'weekly' }
    return 'ambiguous'
}

function Get-WindowObject {
    param([string]$Slot, $Raw)
    if ($null -eq $Raw) { return $null }
    $reset = ConvertTo-EpochSeconds (Get-ObjectPropertyValue $Raw @('reset_at','resetAt') 0)
    $minutes = [int](Get-ObjectPropertyValue $Raw @('window_minutes','windowMinutes','window_size_minutes','windowSizeMinutes') 0)
    [pscustomobject]@{
        Slot = $Slot
        Used = ConvertTo-Percent (Get-ObjectPropertyValue $Raw @('used_percent','usedPercent') 0)
        ResetAt = $reset
        Minutes = $minutes
        Kind = ''
    }
}

function Normalize-CodexState {
    param($Usage, $Credits)
    $rateLimit = Get-ObjectPropertyValue $Usage @('rate_limit','rateLimit')
    $primary = Get-WindowObject 'primary' (Get-ObjectPropertyValue $rateLimit @('primary_window','primaryWindow'))
    $secondary = Get-WindowObject 'secondary' (Get-ObjectPropertyValue $rateLimit @('secondary_window','secondaryWindow'))
    $windows = @($primary,$secondary | Where-Object { $null -ne $_ })

    if ($windows.Count -eq 2 -and $windows[0].Minutes -eq 0 -and $windows[1].Minutes -eq 0) {
        $ordered = @($windows | Sort-Object ResetAt)
        $ordered[0].Kind = 'short'
        $ordered[1].Kind = 'weekly'
    } else {
        foreach ($window in $windows) { $window.Kind = Classify-Window -Slot $window.Slot -Minutes $window.Minutes -ResetAt $window.ResetAt }
    }

    foreach ($window in $windows) {
        if ($window.Kind -ne 'ambiguous') { Set-WindowCacheEntry -Slot $window.Slot -ResetAt $window.ResetAt -Kind $window.Kind }
    }
    Save-WindowCache

    $short = @($windows | Where-Object Kind -eq 'short' | Select-Object -First 1)
    $weekly = @($windows | Where-Object Kind -eq 'weekly' | Select-Object -First 1)
    $ambiguous = @($windows | Where-Object Kind -eq 'ambiguous' | Select-Object -First 1)

    $records = @()
    if ($Credits) {
        foreach ($record in @(Get-ObjectPropertyValue $Credits @('credits','records') @())) {
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
        ShortWindow = if ($short.Count) { $short[0] } else { $null }
        WeeklyWindow = if ($weekly.Count) { $weekly[0] } else { $null }
        AmbiguousWindow = if ($ambiguous.Count) { $ambiguous[0] } else { $null }
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
    try { $Script:LastWidth = [Console]::WindowWidth; $Script:LastHeight = [Console]::WindowHeight } catch {}
    [pscustomobject]@{ Width = $Script:LastWidth; Height = $Script:LastHeight }
}

function Format-LocalTime { param([long]$Epoch); if ($Epoch -le 0) { return '-' }; try { [DateTimeOffset]::FromUnixTimeSeconds($Epoch).LocalDateTime.ToString('MMM d, yyyy h:mm:ss tt zzz') } catch { '-' } }
function Format-Countdown {
    param([long]$Epoch)
    if ($Epoch -le 0) { return '-' }
    $seconds = $Epoch - [DateTimeOffset]::Now.ToUnixTimeSeconds()
    if ($seconds -le 0) { return 'Ready' }
    $span = [TimeSpan]::FromSeconds($seconds)
    return ('{0}d {1:00}h {2:00}m {3:00}s' -f $span.Days,$span.Hours,$span.Minutes,$span.Seconds)
}
function New-AsciiBar { param([int]$Remaining,[int]$Width=20); $r=[math]::Max(0,[math]::Min(100,$Remaining)); $f=[int][math]::Floor($r*$Width/100); '['+('#'*$f)+('-'*($Width-$f))+']' }
function Center-Line { param([string]$Text,[int]$Width); if($Text.Length-ge$Width){return $Text.Substring(0,$Width)}; (' '*[int][math]::Floor(($Width-$Text.Length)/2))+$Text }

function Format-WindowLine {
    param([string]$Label,$Window,[bool]$NotEnforced=$false)
    if ($NotEnforced) { return ('{0,-12} {1,-30} {2,-8} {3,-36} {4}' -f $Label,'Temporarily not enforced','-','No reset scheduled','-') }
    $remaining = 100 - $Window.Used
    ('{0,-12} {1,3}% {2}   {3,3}%     {4,-36} {5}' -f $Label,$remaining,(New-AsciiBar $remaining),$Window.Used,(Format-LocalTime $Window.ResetAt),(Format-Countdown $Window.ResetAt))
}

function Render-Dashboard {
    param($State)
    $size = Get-ConsoleSize
    try { [Console]::SetCursorPosition(0,0) } catch { Clear-Host }
    if ($size.Width -lt $Script:MinimumWidth) { Clear-Host; Write-Host "Terminal is too small. Current width: $($size.Width). Required: $($Script:MinimumWidth)."; return }
    $canvas = [math]::Min(160,$size.Width-4)
    $pad = ' '*[math]::Max(0,[int](($size.Width-$canvas)/2))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Center-Line "CODEX USAGE DASHBOARD v$($Script:AppVersion)" $canvas))
    $lines.Add((Center-Line "Windows PowerShell | Plan: $($State.Plan)" $canvas))
    $lines.Add(('-'*$canvas))
    $access = if($State.Allowed-and-not$State.LimitReached){'AVAILABLE'}else{'RATE LIMITED'}
    $lines.Add(('Access: {0,-14} Last API refresh: {1}' -f $access,$State.RefreshedAt.ToString('h:mm:ss tt')))
    $lines.Add('')
    $lines.Add('USAGE WINDOWS')
    $lines.Add('Window       Remaining                      Used     Resets                               Countdown')
    if ($State.AmbiguousWindow) {
        $lines.Add((Format-WindowLine 'Usage window' $State.AmbiguousWindow))
    } else {
        if ($State.ShortWindow) { $label = if($State.ShortWindow.Minutes-gt 0-and($State.ShortWindow.Minutes%60)-eq0){"$([int]($State.ShortWindow.Minutes/60))-hour"}else{'Short-term'}; $lines.Add((Format-WindowLine $label $State.ShortWindow)) } else { $lines.Add((Format-WindowLine 'Short-term' $null $true)) }
        if ($State.WeeklyWindow) { $lines.Add((Format-WindowLine 'Weekly' $State.WeeklyWindow)) } else { $lines.Add((Format-WindowLine 'Weekly' $null $true)) }
    }
    $lines.Add('')
    $lines.Add("RESET CREDITS  Available: $($State.AvailableCredits)")
    $lines.Add('Status       Granted                          Expires                          Countdown')
    if (@($State.Credits).Count -eq 0) { $lines.Add('No reset-credit records returned.') } else {
        foreach($credit in @($State.Credits)){ $lines.Add(('{0,-12} {1,-32} {2,-32} {3}' -f $credit.Status,(Format-LocalTime $credit.GrantedAt),(Format-LocalTime $credit.ExpiresAt),(Format-Countdown $credit.ExpiresAt))) }
    }
    $lines.Add('')
    $lines.Add("Auto-resume: $($Script:ResumeStatus)")
    if($Script:ResumeLog){$lines.Add("Resume log: $($Script:ResumeLog)")}
    if($Script:LastRefreshError){$lines.Add("Warning: $($Script:LastRefreshError)")}
    $lines.Add("Terminal: $($size.Width)x$($size.Height) | API refresh: ${Refresh}s | Ctrl+C to exit")
    $output=New-Object System.Collections.Generic.List[string]
    foreach($line in $lines){$trim=if($line.Length-gt$canvas){$line.Substring(0,$canvas)}else{$line};$output.Add($pad+$trim.PadRight($canvas))}
    while($output.Count-lt($size.Height-1)){$output.Add(' '*$size.Width)}
    Write-Host($output-join[Environment]::NewLine)
}

function Start-CodexResume {
    param($State)
    if(-not$AutoResume-or-not$State.Allowed-or$State.LimitReached){return}
    if(-not(Test-Path-LiteralPath$Project-PathType Container)){$Script:ResumeStatus='Failed: project not found';return}
    if(-not(Get-Command codex-ErrorAction SilentlyContinue)){$Script:ResumeStatus='Failed: codex command not found';return}
    $logDir=Join-Path([IO.Path]::GetTempPath())'CodexDashboard';New-Item-ItemType Directory-Path$logDir-Force|Out-Null
    $logPath=Join-Path$logDir("resume-{0}.out.log"-f(Get-Date-Format'yyyyMMdd-HHmmss'));$err=$logPath.Replace('.out.log','.err.log')
    try{Start-Process-FilePath'codex'-ArgumentList("exec resume --last `"$($Prompt.Replace('"','\"'))`"")-WorkingDirectory$Project-RedirectStandardOutput$logPath-RedirectStandardError$err-WindowStyle Hidden|Out-Null;$Script:ResumeStatus='Started';$Script:ResumeLog=$logPath}catch{$Script:ResumeStatus="Failed: $($_.Exception.Message)"}
}

function Restore-Console { try{[Console]::CursorVisible=$Script:OriginalCursorVisible}catch{};try{[Console]::ResetColor()}catch{};try{[Console]::Clear()}catch{} }

try {
    if($AutoResume-and-not(Test-Path-LiteralPath$Project-PathType Container)){throw"Project directory not found: $Project"}
    Load-WindowCache
    $auth=Get-CodexAuth
    try{$Script:OriginalCursorVisible=[Console]::CursorVisible;[Console]::CursorVisible=$false}catch{}
    Clear-Host
    $lastApiRefresh=[DateTime]::MinValue
    while($true){
        if(((Get-Date)-$lastApiRefresh).TotalSeconds-ge$Refresh-or$null-eq$Script:LastGoodState){
            try{
                $Script:LastGoodState=Get-CodexState-Auth$auth;$Script:LastRefreshError=$null;$lastApiRefresh=Get-Date
                $blocked=(-not$Script:LastGoodState.Allowed-or$Script:LastGoodState.LimitReached)
                if($blocked){$Script:WasBlocked=$true;$Script:ResumeStatus='Waiting for Codex access to reset'}elseif($Script:WasBlocked){$Script:WasBlocked=$false;Start-CodexResume-State$Script:LastGoodState}elseif($AutoResume-and$Script:ResumeStatus-ne'Started'){$Script:ResumeStatus='Armed'}
            }catch{$Script:LastRefreshError=$_.Exception.Message;if($null-eq$Script:LastGoodState){throw};$lastApiRefresh=Get-Date}
        }
        Render-Dashboard-State$Script:LastGoodState
        Start-Sleep-Seconds 1
    }
}
catch{Restore-Console;Write-Error$_.Exception.Message;exit 1}
finally{Restore-Console}
