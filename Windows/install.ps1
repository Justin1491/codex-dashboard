[CmdletBinding()]
param([switch]$Force)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'CodexDashboard.ps1'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "CodexDashboard.ps1 was not found next to this installer."
}

$installDir = Join-Path $env:LOCALAPPDATA 'CodexDashboard'
$binDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
$scriptTarget = Join-Path $installDir 'CodexDashboard.ps1'
$shimTarget = Join-Path $binDir 'codex-dashboard.cmd'

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $scriptTarget -Force

$shim = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$scriptTarget`" %*`r`n"
Set-Content -LiteralPath $shimTarget -Value $shim -Encoding ASCII -Force

Write-Host "Codex Dashboard installed." -ForegroundColor Green
Write-Host "Command: codex-dashboard"
Write-Host "Application: $scriptTarget"
Write-Host "Shim: $shimTarget"
Write-Host "Open a new terminal before running the command."
