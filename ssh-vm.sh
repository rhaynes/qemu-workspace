#!/usr/bin/env bash
# SSH into a running VM identified by its workspace.
#
# Usage:
#   ./ssh-vm.sh <workspace>                       # interactive shell
#   ./ssh-vm.sh <workspace> sudo apt update       # run a remote command
#   SSH_PORT=2223 ./ssh-vm.sh <workspace>         # use a non-default port
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <workspace> [remote-command...]" >&2
    echo "  SSH_PORT env var (default 2222) sets the host port to connect to." >&2
    exit 1
fi

workspace="$1"
shift
if [ ! -d "$workspace" ]; then
    echo "Workspace not found: $workspace" >&2
    exit 1
fi
workspace="$(cd "$workspace" && pwd)"

KEY="$workspace/vm/id_ed25519"
: "${SSH_PORT:=2222}"

if [ ! -f "$KEY" ]; then
    echo "SSH key not found at $KEY." >&2
    exit 1
fi

exec ssh \
    -i "$KEY" \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    ubuntu@localhost "$@"
