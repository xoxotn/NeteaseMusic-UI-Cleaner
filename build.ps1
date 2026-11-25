# One-Click Windows -> WSL2 Dual-Target Release Builder
# Builds BOTH:
# 1. Rootless .deb for iPhone 13 Pro (iOS 16.5 Dopamine)
# 2. Standalone zero-dependency UICleaner.dylib for iPhone 15 Pro Max (iOS 17.4.1)

$ErrorActionPreference = "Stop"
$wsl = "C:\Program Files\WSL\wsl.exe"
$root = $PSScriptRoot

# 1. Normalize Linux LF line endings automatically so Windows edits never break make/dpkg
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
Get-ChildItem "$root\ui-cleaner-template" -File | ForEach-Object {
    $raw = [System.IO.File]::ReadAllText($_.FullName)
    $lf = $raw -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($_.FullName, $lf, $utf8NoBom)
}

# 2. Sync to WSL2 ext4 workspace and compile stripped Release (FINALPACKAGE=1)
$bashCmd = @'
set -euo pipefail
export THEOS="$HOME/theos"
export THEOS_PACKAGE_SCHEME=rootless
export PATH="$THEOS/bin:$PATH"
WSL_ROOT="/mnt/c/Users/Xoxo/.gemini/antigravity/scratch/rootless-ui-starter"

mkdir -p "$HOME/projects/ui-cleaner"
rsync -a --delete "$WSL_ROOT/ui-cleaner-template/" "$HOME/projects/ui-cleaner/"
chmod -R 755 "$HOME/projects/ui-cleaner"

cd "$HOME/projects/ui-cleaner"
rm -rf ./packages ./dist
make clean
make package FINALPACKAGE=1

mkdir -p "$WSL_ROOT/dist"
rm -f "$WSL_ROOT/dist/"*
cp -f "$HOME/projects/ui-cleaner/dist/"* "$WSL_ROOT/dist/"
'@ -replace "`r`n", "`n"

$bashCmd | & $wsl -d Ubuntu-24.04 -u dev -- bash -c "tr -d '\r' | bash"
if ($LASTEXITCODE -ne 0) {
    throw "WSL2 Theos compilation failed!"
}

Write-Host ""
Write-Host "=== Build Succeeded! Output files in .\dist\ ===" -ForegroundColor Green
Get-ChildItem "$root\dist" | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
