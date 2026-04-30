#!/usr/bin/env bash
# Rename the running guest's hostname. Updates /etc/hostname (via
# hostnamectl) and /etc/hosts inside the VM. Useful after clone-vm.sh,
# which produces a clone that still answers to the source's hostname.
#
# Usage:
#   ./rename-vm.sh <workspace> <new-hostname>
#   SSH_PORT=2223 ./rename-vm.sh <workspace> <new-hostname>
#
# The VM must already be running (start it with ./start-vm.sh first).
# This script does not start it for you.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <workspace> <new-hostname>" >&2
    exit 1
fi

workspace="$1"
new_name="$2"

if [ ! -d "$workspace" ]; then
    echo "Workspace not found: $workspace" >&2
    exit 1
fi
workspace="$(cd "$workspace" && pwd)"

DISK="$workspace/vm/disk.qcow2"
if [ ! -f "$DISK" ]; then
    echo "VM disk missing at $DISK." >&2
    exit 1
fi

# RFC 1123 hostname rules: 1-63 chars, letters/digits/hyphens, no leading
# or trailing hyphen. Matches the validation in create-vm.sh.
if ! [[ "$new_name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Invalid hostname '$new_name'." >&2
    echo "Must be 1-63 chars: letters, digits, hyphens (no leading/trailing hyphen)." >&2
    exit 1
fi

if ! pgrep -f "qemu-system-aarch64.*${DISK}" >/dev/null; then
    echo "VM is not running for $workspace." >&2
    echo "Start it first with: ./start-vm.sh $workspace" >&2
    exit 1
fi

# new_name is alnum+hyphen only (validated above), so single-quoting it into
# the remote script is safe -- no quote injection.
remote_script=$(cat <<EOF
set -e
old=\$(hostname)
new='$new_name'
if [ "\$old" = "\$new" ]; then
    echo "Hostname is already \$new -- nothing to do."
    exit 0
fi
sudo hostnamectl set-hostname "\$new"
sudo sed -i "s/\\b\$old\\b/\$new/g" /etc/hosts
echo "Renamed: \$old -> \$new"
EOF
)

exec "$SCRIPT_DIR/ssh-vm.sh" "$workspace" "$remote_script"
