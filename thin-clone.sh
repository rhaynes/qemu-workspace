#!/usr/bin/env bash
# Create a thin clone of a VM workspace: the new disk is a qcow2 overlay
# backed by the source disk, so it starts at ~200 KB and only stores its
# own writes.
#
# Usage:
#   ./thin-clone.sh <source-workspace> [dest-workspace]
#
# IMPORTANT: while the thin clone exists, the source disk must be treated
# as read-only. Booting the source VM modifies its own disk and will
# silently corrupt the clone's view. For independent VMs, use clone-vm.sh.
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <source-workspace> [dest-workspace]" >&2
    exit 1
fi
if ! [ -t 0 ]; then
    echo "thin-clone.sh requires an interactive terminal." >&2
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
    echo "Shut it down before cloning." >&2
    exit 1
fi

# Detect existing backing chain on the source so the user knows they're
# stacking layers (allowed but adds another fragile link).
SRC_BACKING=$(qemu-img info "$SRC_DISK" 2>/dev/null \
    | awk -F': ' '/^backing file:/ {print $2; exit}')
src_actual=$(qemu-img info "$SRC_DISK" 2>/dev/null \
    | awk -F': ' '/^disk size:/ {print $2; exit}')
src_virtual=$(qemu-img info "$SRC_DISK" 2>/dev/null \
    | awk -F': ' '/^virtual size:/ {print $2; exit}')

echo "=== Thin-clone VM workspace ==="
echo "Source workspace: $source_ws"
echo "Source disk:      $SRC_DISK"
echo "  virtual size:   ${src_virtual:-unknown}"
echo "  actual size:    ${src_actual:-unknown}"
if [ -n "$SRC_BACKING" ]; then
    echo "  backing file:   $SRC_BACKING  (source is itself a thin clone)"
fi
echo

# ---- pick destination -----------------------------------------------------

if [ -n "${2:-}" ]; then
    clone_ws=$(expand_path "$2")
else
    clone_ws=$(prompt "Clone workspace" "${source_ws}-thin")
    clone_ws=$(expand_path "$clone_ws")
fi

if [ -e "$clone_ws/vm" ]; then
    echo "Refusing to overwrite $clone_ws/vm (already exists)." >&2
    exit 1
fi

CLONE_VM="$clone_ws/vm"
CLONE_DISK="$CLONE_VM/disk.qcow2"

cat <<EOF

About to thin-clone:
  Source disk: $SRC_DISK   (must stay immutable)
  Clone disk:  $CLONE_DISK (qcow2 overlay, ~200 KB initially)
  Clone ws:    $clone_ws/shared (new, empty)

EOF
cat <<'EOF'
WARNING: while this clone exists, do not:
  - boot the source VM  (booting writes to the source disk)
  - move, rename, or delete the source disk
  - modify the source disk in any way
Doing any of these will silently corrupt or break the clone.
For independent VMs, abort and use ./clone-vm.sh instead.

EOF
confirm "Proceed?" || { echo "Aborted." >&2; exit 1; }

# ---- build the clone -----------------------------------------------------

mkdir -p "$CLONE_VM" "$clone_ws/shared"

echo "Creating qcow2 overlay..."
qemu-img create -q -f qcow2 -F qcow2 -b "$SRC_DISK" "$CLONE_DISK" >/dev/null

echo "Copying small per-VM files (firmware, NVRAM, seed, SSH key)..."
cp "$SRC_VM/efi_vars.fd"    "$CLONE_VM/efi_vars.fd"
cp "$SRC_VM/edk2-code.fd"   "$CLONE_VM/edk2-code.fd"
cp "$SRC_VM/seed.iso"       "$CLONE_VM/seed.iso"
cp "$SRC_VM/id_ed25519"     "$CLONE_VM/id_ed25519"
cp "$SRC_VM/id_ed25519.pub" "$CLONE_VM/id_ed25519.pub"

if ! qemu-img info "$CLONE_DISK" >/dev/null 2>&1; then
    echo "Created overlay but qemu-img cannot read it. Aborting." >&2
    exit 1
fi

clone_actual=$(qemu-img info "$CLONE_DISK" 2>/dev/null \
    | awk -F': ' '/^disk size:/ {print $2; exit}')

cat <<EOF

Thin clone created: $clone_ws
  Backing file:  $SRC_DISK
  Initial size:  ${clone_actual:-unknown} (overlay only)

To run source and clone concurrently, give the clone a different SSH port:
  ./start-vm.sh $source_ws                       # source on default port 2222
  SSH_PORT=2223 ./start-vm.sh $clone_ws          # clone on port 2223
EOF
