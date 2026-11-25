#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Please run this script as your normal Ubuntu user (NOT root / sudo)."
    exit 1
fi

echo "==> [1/6] Installing Ubuntu build dependencies..."
sudo apt update
sudo apt install -y \
    build-essential \
    fakeroot \
    rsync \
    curl \
    perl \
    zip \
    unzip \
    xz-utils \
    git \
    libxml2 \
    libtinfo6 \
    openssh-client \
    ca-certificates

sudo update-alternatives --set fakeroot /usr/bin/fakeroot-sysv || true

export THEOS="$HOME/theos"
echo "==> [2/6] Cloning Theos repository to $THEOS (Bypassing api.github.com 403)..."
if [[ -d "$THEOS/.git" ]]; then
    git -C "$THEOS" pull --recurse-submodules
else
    rm -rf "$THEOS"
    git clone --recursive https://github.com/theos/theos.git "$THEOS"
fi

echo "==> [3/6] Downloading Linux iOS Clang/LLVM Toolchain (82 MB)..."
mkdir -p "$THEOS/toolchain"
if [[ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]]; then
    curl -fL --retry 3 https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-x86_64.tar.xz \
        | tar -xJf - -C "$THEOS/toolchain/"
fi

echo "==> [4/6] Downloading iPhoneOS16.5.sdk (16.6 MB)..."
mkdir -p "$THEOS/sdks"
if [[ ! -d "$THEOS/sdks/iPhoneOS16.5.sdk" ]]; then
    curl -fL --retry 3 https://github.com/theos/sdks/releases/latest/download/iPhoneOS16.5.sdk.tar.xz \
        | tar -xJf - -C "$THEOS/sdks/"
fi

echo "==> [5/6] Configuring Rootless environment variables in ~/.bashrc..."
if ! grep -q "THEOS_PACKAGE_SCHEME=rootless" "$HOME/.bashrc"; then
    cat << 'EOF' >> "$HOME/.bashrc"

# Theos Rootless defaults (iOS 15+ / 16.5 & 17.4.1 dual-target)
export THEOS=~/theos
export THEOS_PACKAGE_SCHEME=rootless
export PATH="$THEOS/bin:$PATH"
EOF
fi

export THEOS_PACKAGE_SCHEME=rootless
export PATH="$THEOS/bin:$PATH"

echo "==> [6/6] Building dual-device (13 Pro 16.5 .deb + 15PM 17.4.1 .dylib) package..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/projects/ui-cleaner"
rsync -av --delete "$SCRIPT_DIR/ui-cleaner-template/" "$HOME/projects/ui-cleaner/"
chmod -R 755 "$HOME/projects/ui-cleaner"

cd "$HOME/projects/ui-cleaner"
make clean
make package

echo ""
echo "=================================================================="
echo "Verifying dylib linkage (should ONLY depend on system UIKit/Foundation/libobjc):"
"$THEOS/toolchain/linux/iphone/bin/llvm-objdump" --macho --dylibs-used ./dist/UICleaner.dylib || true
echo ""
echo "SUCCESS! Dual-device build outputs ready in ~/projects/ui-cleaner/dist/:"
ls -lh "$HOME/projects/ui-cleaner/dist/"
echo "=================================================================="
