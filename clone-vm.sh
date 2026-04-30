#!/usr/bin/env bash
# Clone a VM workspace into a new one. Full copy: the new disk is
# independent of the source. Uses APFS clonefile() for instant + CoW
# duplication when source and destination live on the same volume.
#
# Usage:
#   ./clone-vm.sh <source-workspace> [dest-workspace]
#
# The source VM must be shut down before cloning.
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <source-workspace> [dest-workspace]" >&2
    exit 1
fi
if ! [ -t 0 ]; then
    echo "clone-vm.sh requires an interactive terminal." >&2
    exit 1
fi

# ---- helpers --------------------------------------------------------------

prompt() {
    local question="$1" default_val="${2:-}" answer label
    if [ -n "$default_val" ]; then
        label="$question [$default_val]: "
    else
        label="$question: "
    fi
    printf '%s' "$label" >&2
    IFS= read -r answer
    printf '%s' "${answer:-$default_val}"
}

confirm() {
    local answer
    printf '%s [Y/n]: ' "$1" >&2
    IFS= read -r answer
    case "${answer:-y}" in
        y|Y|yes|YES|Yes) return 0 ;;
        *)               return 1 ;;
    esac
}

expand_path() {
    local p="$1"
    p="${p/#\~/$HOME}"
    case "$p" in
        /*) printf '%s' "$p" ;;
        *)  printf '%s' "$PWD/$p" ;;
    esac
}

# ---- inspect source -------------------------------------------------------

source_ws="$1"
if [ ! -d "$source_ws" ]; then
    echo "Source workspace not found: $source_ws" >&2
    exit 1
fi
source_ws="$(cd "$source_ws" && pwd)"
SRC_VM="$source_ws/vm"
SRC_DISK="$SRC_VM/disk.qcow2"

if [ ! -f "$SRC_DISK" ]; then
    echo "No VM disk at $SRC_DISK." >&2
    exit 1
fi

if pgrep -f "qemu-system-aarch64.*${SRC_DISK}" >/dev/null; then
    echo "Source VM appears to be running:" >&2
    pgrep -fl "qemu-system-aarch64.*${SRC_DISK}" >&2
    echo "Shut it down (sudo poweroff inside the VM) before cloning." >&2
    exit 1
fi

echo "=== Clone VM workspace ==="
echo "Source: $source_ws"
echo

# ---- pick destination -----------------------------------------------------

if [ -n "${2:-}" ]; then
    clone_ws=$(expand_path "$2")
else
    clone_ws=$(prompt "Clone workspace" "${source_ws}-clone")
    clone_ws=$(expand_path "$clone_ws")
fi

if [ -e "$clone_ws/vm" ]; then
    echo "Refusing to overwrite $clone_ws/vm (already exists)." >&2
    exit 1
fi

cat <<EOF

About to clone:
  Source: $SRC_VM
  Dest:   $clone_ws/vm           (full copy)
          $clone_ws/shared       (new, empty)
EOF
echo
confirm "Proceed?" || { echo "Aborted." >&2; exit 1; }

# ---- copy ----------------------------------------------------------------

mkdir -p "$clone_ws"

echo "Copying VM files..."
# APFS clonefile() makes this instant + CoW on the same volume.
if cp -c -R "$SRC_VM" "$clone_ws/vm" 2>/dev/null; then
    echo "  cloned via APFS copy-on-write"
else
    cp -R "$SRC_VM" "$clone_ws/vm"
    echo "  copied (no CoW available across volumes)"
fi

mkdir -p "$clone_ws/shared"

cat <<EOF

Clone created: $clone_ws

To run source and clone concurrently, give the clone a different SSH port:
  ./start-vm.sh $source_ws                       # source on default port 2222
  SSH_PORT=2223 ./start-vm.sh $clone_ws          # clone on port 2223
  SSH_PORT=2223 ./ssh-vm.sh   $clone_ws          # SSH to the clone
EOF
