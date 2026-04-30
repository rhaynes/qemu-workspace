#!/usr/bin/env bash
# Provision a fresh Ubuntu ARM64 VM. Interactive: prompts for the cloud
# image, the workspace directory (which holds vm/ and shared/), the disk
# size, and the EFI firmware path, then builds:
#   - a per-VM qcow2 disk
#   - an SSH keypair (host-only)
#   - a NoCloud cloud-init seed ISO
#   - a UEFI firmware copy and variable store
#
# Writes a vm-config file in the script directory recording the workspace
# location, so start-vm.sh and ssh-vm.sh can find the VM artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if ! [ -t 0 ]; then
    echo "create-vm.sh requires an interactive terminal." >&2
    exit 1
fi

if ! command -v qemu-img >/dev/null 2>&1; then
    echo "qemu-img not found. Run ./install-qemu.sh first." >&2
    exit 1
fi

EDK2_SRC="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
if [ ! -f "$EDK2_SRC" ]; then
    echo "EDK2 ARM64 firmware not found at $EDK2_SRC" >&2
    echo "This file ships with QEMU; reinstall via ./install-qemu.sh." >&2
    exit 1
fi

# ---- helpers ---------------------------------------------------------------

prompt() {
    # prompt "Question" "default" -> echoes the answer (or default on empty)
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
    # Expand a leading ~ and resolve to absolute path (file may not yet exist).
    local p="$1"
    p="${p/#\~/$HOME}"
    case "$p" in
        /*) printf '%s' "$p" ;;
        *)  printf '%s' "$PWD/$p" ;;
    esac
}

# ---- gather inputs ---------------------------------------------------------

echo "=== QEMU Ubuntu ARM64 VM provisioning ==="
echo

# 1. Cloud image -- default is the Ubuntu 26.04 LTS ARM64 cloud image URL.
#    Press Enter to download it (cached under ./images/ so subsequent runs
#    are instant). Supply a different URL to download a different image, or
#    a local file path to use that file directly.
DEFAULT_IMG_NAME="ubuntu-26.04-server-cloudimg-arm64.img"
DEFAULT_IMG_URL="https://cloud-images.ubuntu.com/releases/26.04/release/$DEFAULT_IMG_NAME"
DEFAULT_CACHE="$SCRIPT_DIR/images/$DEFAULT_IMG_NAME"

if [ -f "$DEFAULT_CACHE" ]; then
    cache_note="(already cached at ./images/$DEFAULT_IMG_NAME)"
else
    cache_note="(~900 MB download to ./images/)"
fi

echo "Default: Ubuntu 26.04 LTS ARM64 $cache_note"
echo "Press Enter to use it, or supply a different URL or local file path."
echo

while true; do
    cloud_img=$(prompt "Cloud image" "$DEFAULT_IMG_URL")

    if [[ "$cloud_img" =~ ^https?:// ]]; then
        url="$cloud_img"
        target="$SCRIPT_DIR/images/$(basename "$url")"
        if [ ! -f "$target" ]; then
            mkdir -p "$(dirname "$target")"
            echo "Downloading $(basename "$url")..."
            echo "  from: $url"
            if ! curl -fL --progress-bar -o "$target.partial" "$url"; then
                rm -f "$target.partial"
                echo "  Download failed." >&2
                continue
            fi
            mv "$target.partial" "$target"
        fi
        cloud_img="$target"
    else
        cloud_img=$(expand_path "$cloud_img")
        if [ ! -f "$cloud_img" ]; then
            echo "  File not found: $cloud_img" >&2
            continue
        fi
    fi

    # Validate format -- cloud images are qcow2; install ISOs come back as raw.
    fmt=$(qemu-img info "$cloud_img" 2>/dev/null | awk '/^file format:/ {print $3}')
    if [ "$fmt" = "qcow2" ]; then
        break
    fi
    echo "  $cloud_img has format '${fmt:-unknown}' (expected qcow2)." >&2
    if [[ "$cloud_img" == *.iso ]]; then
        echo "  This looks like an install ISO -- it can't be used with cloud-init." >&2
    fi
    echo "  Get a cloud image from: $DEFAULT_IMG_URL" >&2
done

# 2. VM name + parent directory -- workspace = <vms_dir>/<vm_name>, holding
#    vm/ and shared/ subdirs.
echo
echo "Workspace directory will hold:"
echo "  <workspace>/vm/      -- disk image, EFI vars, SSH key, seed ISO"
echo "  <workspace>/shared/  -- host<->guest bridge (mounted at /mnt/shared)"
echo "Created if it does not exist."
echo
while true; do
    vm_name=$(prompt "VM name")
    if [ -z "$vm_name" ]; then
        echo "  VM name is required." >&2
        continue
    fi
    case "$vm_name" in
        */*|.|..) echo "  VM name must not contain '/' or be '.'/'..'." >&2; continue ;;
    esac
    break
done

vms_dir=$(prompt "VMs directory" "$SCRIPT_DIR/vms")
vms_dir=$(expand_path "$vms_dir")

workspace="$vms_dir/$vm_name"

VM_DIR="$workspace/vm"
SHARED_DIR="$workspace/shared"
SEED_DIR="$VM_DIR/seed"

# 3. Disk size
echo
disk_size=$(prompt "VM disk size (qcow2 is sparse; 50G is not 50G on disk)" "50G")

# ---- summary + confirmation -----------------------------------------------

cat <<EOF

About to create:
  Source image:  $cloud_img
  Workspace:     $workspace
    VM disk:     $VM_DIR/disk.qcow2  (resized to $disk_size)
    SSH key:     $VM_DIR/id_ed25519
    Seed ISO:    $VM_DIR/seed.iso
    EFI files:   $VM_DIR/edk2-code.fd, $VM_DIR/efi_vars.fd
    Shared:      $SHARED_DIR  <-->  /mnt/shared
  EDK2 source:   $EDK2_SRC
EOF
echo
if ! confirm "Continue?"; then
    echo "Aborted. Nothing changed." >&2
    exit 1
fi

# ---- guard against clobbering an existing VM at this location -------------

if [ -f "$VM_DIR/disk.qcow2" ]; then
    echo
    echo "An existing VM was found at $VM_DIR/disk.qcow2."
    if confirm "Delete $VM_DIR and start fresh?"; then
        rm -rf "$VM_DIR"
    else
        echo "Aborted. Nothing changed." >&2
        exit 1
    fi
fi

mkdir -p "$VM_DIR" "$SEED_DIR" "$SHARED_DIR"

# ---- 1. SSH keypair --------------------------------------------------------

SSH_KEY="$VM_DIR/id_ed25519"
echo "Generating SSH keypair..."
ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "qemu-ubuntu-agent" >/dev/null

# ---- 2. cloud-init seed ISO -----------------------------------------------

echo "Building cloud-init seed ISO..."
PUBKEY=$(cat "${SSH_KEY}.pub")
PUBKEY_ESCAPED=$(printf '%s' "$PUBKEY" | sed -e 's/[&/\]/\\&/g')
sed "s|__SSH_PUBKEY__|${PUBKEY_ESCAPED}|" cloud-init/user-data.tmpl > "$SEED_DIR/user-data"
cp cloud-init/meta-data "$SEED_DIR/meta-data"

SEED_ISO="$VM_DIR/seed.iso"
rm -f "$SEED_ISO"
hdiutil makehybrid -quiet -iso -joliet \
    -default-volume-name CIDATA \
    -o "$SEED_ISO" "$SEED_DIR"

# ---- 3. VM disk ------------------------------------------------------------

DISK="$VM_DIR/disk.qcow2"
echo "Copying cloud image and resizing to $disk_size..."
cp "$cloud_img" "$DISK"
qemu-img resize "$DISK" "$disk_size"

# ---- 4. EFI firmware + variable store -------------------------------------

PFLASH_SIZE=67108864  # 64 MiB; QEMU pflash needs an exact size match
EDK2_LOCAL="$VM_DIR/edk2-code.fd"
echo "Setting up EFI firmware..."
cp "$EDK2_SRC" "$EDK2_LOCAL"
cur=$(stat -f%z "$EDK2_LOCAL")
if [ "$cur" -lt "$PFLASH_SIZE" ]; then
    # Append zero bytes to reach the exact pflash size.
    dd if=/dev/zero bs=$(( PFLASH_SIZE - cur )) count=1 >> "$EDK2_LOCAL" 2>/dev/null
fi

# Sparse 64 MiB blank UEFI variable store. mkfile errors if the file
# already exists, so wipe first.
EFI_VARS="$VM_DIR/efi_vars.fd"
rm -f "$EFI_VARS"
mkfile -n 64m "$EFI_VARS"

cat <<EOF

VM provisioned. Workspace: $workspace

Next:
  ./start-vm.sh $workspace
  ./ssh-vm.sh   $workspace                 # once cloud-init finishes (~2-3 min)

Multiple VMs at once: pass a different SSH_PORT per VM, e.g.
  SSH_PORT=2223 ./start-vm.sh $workspace
EOF
