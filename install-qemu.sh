#!/usr/bin/env bash
# Install host dependencies for running an Ubuntu ARM64 VM under QEMU.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required. Install from https://brew.sh" >&2
    exit 1
fi

brew install qemu

# hdiutil (macOS built-in) builds the cloud-init seed ISO, so no
# mkisofs/xorriso dependency is needed.

echo
echo "Installed:"
echo "  qemu-system-aarch64: $(command -v qemu-system-aarch64)"
echo "  qemu-img:            $(command -v qemu-img)"
echo
echo "Next: ./create-vm.sh"
