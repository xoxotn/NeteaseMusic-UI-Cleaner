# Self-elevating WSL2 Installer (Bypasses GitHub API 403 rate limit on shared proxy IPs)
$ErrorActionPreference = "Stop"
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Cyan
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "=== [1/3] Enabling Windows Subsystem for Linux & Virtual Machine Platform via DISM (Offline, no 403) ===" -ForegroundColor Green
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

$msiPath = Join-Path $PSScriptRoot "wsl.3.0.5.0.x64.msi"
$msiUrl = "https://github.com/microsoft/WSL/releases/download/3.0.5/wsl.3.0.5.0.x64.msi"

Write-Host ""
Write-Host "=== [2/3] Downloading Official Microsoft WSL 3.0.5 Package Directly (Bypassing api.github.com 403) ===" -ForegroundColor Green
if (-not (Test-Path $msiPath)) {
    curl.exe -L --fail --retry 3 -o "$msiPath" "$msiUrl"
}

Write-Host ""
Write-Host "=== [3/3] Installing WSL Core MSI Package ===" -ForegroundColor Green
Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /passive /norestart" -Wait

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host "WSL Core Installed! NOW DO ONE REBOOT:" -ForegroundColor Green
Write-Host "1. Restart PC and press [Delete] to enter MSI BIOS (B650M GAMING PLUS WIFI)." -ForegroundColor White
Write-Host "2. Go to: OC -> Advanced CPU Configuration -> SVM Mode -> [Enabled]" -ForegroundColor Cyan
Write-Host "3. Press [F10] to Save & Reboot into Windows." -ForegroundColor White
Write-Host "4. After reboot, come back to Antigravity and tell me 'Rebooted'!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Yellow
Read-Host "Press Enter to close"
