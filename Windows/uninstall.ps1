[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'CodexDashboard'
$shim = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps') 'codex-dashboard.cmd'

if (Test-Path -LiteralPath $shim) { Remove-Item -LiteralPath $shim -Force }
if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }

Write-Host 'Codex Dashboard has been removed.' -ForegroundColor Green
