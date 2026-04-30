#!/usr/bin/env bash
# Boot the Ubuntu ARM64 VM in <workspace>/vm with HVF acceleration and a
# 9p-mounted <workspace>/shared as the only filesystem bridge to the host.
#
# Usage:
#   ./start-vm.sh <workspace>
#   SSH_PORT=2223 ./start-vm.sh <workspace>
#
# Tunables (env vars):
#   SSH_PORT       host port forwarded to guest 22 (default 2222)
#   VM_MEMORY      e.g. 4G, 6G, 8G                  (default 6G)
#   VM_CPUS        number of vCPUs                  (default 4)
#   HEADLESS=1     no graphics; serial on stdio (exit with Ctrl-A X)
#   NET_RESTRICT=1 block VM from reaching the internet
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <workspace>" >&2
    echo "  Workspace = the directory created by ./create-vm.sh" >&2
    echo "  (contains vm/ and shared/)" >&2
    exit 1
fi

workspace="$1"
if [ ! -d "$workspace" ]; then
    echo "Workspace not found: $workspace" >&2
    exit 1
fi
workspace="$(cd "$workspace" && pwd)"

VM_DIR="$workspace/vm"
SHARED_DIR="$workspace/shared"

if [ ! -f "$VM_DIR/disk.qcow2" ]; then
    echo "VM disk missing at $VM_DIR/disk.qcow2." >&2
    echo "Provision this workspace with ./create-vm.sh first." >&2
    exit 1
fi

: "${VM_MEMORY:=6G}"
: "${VM_CPUS:=4}"
: "${SSH_PORT:=2222}"
: "${NET_RESTRICT:=0}"
: "${HEADLESS:=0}"

mkdir -p "$SHARED_DIR"

NETDEV_OPTS="user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
if [ "$NET_RESTRICT" = "1" ]; then
    NETDEV_OPTS="${NETDEV_OPTS},restrict=on"
    NET_DESC="restricted (no internet)"
else
    NET_DESC="NAT (full outbound; SSH on host port ${SSH_PORT})"
fi

if [ "$HEADLESS" = "1" ]; then
    DISPLAY_ARGS=(-display none -serial mon:stdio)
    DISPLAY_DESC="headless (serial on stdio; exit with Ctrl-A X)"
else
    DISPLAY_ARGS=(
        -display cocoa
        -device virtio-gpu-pci
        -device qemu-xhci,id=xhci
        -device usb-kbd
        -device usb-tablet
        -serial mon:stdio
    )
    DISPLAY_DESC="cocoa window (close window or 'sudo poweroff' via SSH to stop)"
fi

cat <<EOF
Workspace:     $workspace
Shared folder: $SHARED_DIR  <-->  /mnt/shared
Network:       $NET_DESC
Display:       $DISPLAY_DESC

EOF

exec qemu-system-aarch64 \
    -name "ubuntu-$(basename "$workspace")" \
    -machine virt,accel=hvf,highmem=on \
    -cpu host \
    -smp "$VM_CPUS" \
    -m "$VM_MEMORY" \
    -drive "if=pflash,format=raw,readonly=on,file=${VM_DIR}/edk2-code.fd" \
    -drive "if=pflash,format=raw,file=${VM_DIR}/efi_vars.fd" \
    -drive "if=virtio,format=qcow2,file=${VM_DIR}/disk.qcow2" \
    -drive "if=virtio,format=raw,readonly=on,file=${VM_DIR}/seed.iso" \
    -netdev "$NETDEV_OPTS" \
    -device virtio-net-pci,netdev=net0 \
    -fsdev "local,id=share0,path=${SHARED_DIR},security_model=mapped-xattr" \
    -device virtio-9p-pci,fsdev=share0,mount_tag=hostshare \
    -device virtio-rng-pci \
    "${DISPLAY_ARGS[@]}"
