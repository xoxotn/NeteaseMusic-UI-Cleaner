# One-Click Build & Wireless Push to iPhone 13 Pro (192.168.1.xxx)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$wsl = "C:\Program Files\WSL\wsl.exe"

& "$root\build.ps1"

$pushCmd = @'
set -e
DEB=$(ls ~/projects/ui-cleaner/dist/*.deb | head -n1)
scp "$DEB" root@192.168.1.xxx:/tmp/uicleaner.deb
ssh root@192.168.1.xxx "/var/jb/usr/bin/dpkg -i /tmp/uicleaner.deb && rm -f /tmp/uicleaner.deb && (/var/jb/usr/bin/killall -9 NeteaseMusic 2>/dev/null || true)"
'@ -replace "`r`n", "`n"

$pushCmd | & $wsl -d Ubuntu-24.04 -u dev -- bash -c "tr -d '\r' | bash"
Write-Host "=== Successfully installed & refreshed on iPhone 13 Pro (192.168.1.xxx)! ===" -ForegroundColor Green
