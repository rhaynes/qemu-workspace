#!/usr/bin/env bash
# Forward a TCP port between the host (Mac) and a running VM.
#
# Usage:
#   ./forward-port-vm.sh <workspace> port=PORT [server-on=guest|host]
#   ./forward-port-vm.sh <workspace> on-host=PORT on-guest=PORT [server-on=guest|host]
#
# Examples:
#   # Reach a web server running inside the VM on guest:8080 from host:8080
#   ./forward-port-vm.sh vms/dev port=8080
#
#   # Different ports on each side
#   ./forward-port-vm.sh vms/dev on-host=8080 on-guest=80
#
#   # Expose a Postgres on the host to the guest as guest:5432
#   ./forward-port-vm.sh vms/dev port=5432 server-on=host
#
# Args:
#   port=PORT        shorthand: same port number on both sides
#   on-host=PORT     port number on the host (Mac) side
#   on-guest=PORT    port number on the guest (VM)  side
#   server-on=guest  server is in the VM; connect to it via host:on-host  (default)
#   server-on=host   server is on the host; VM connects via guest:on-guest
#
# SSH_PORT env var (default 2222) sets the host port used to SSH into the VM.
# The forward stays up until you Ctrl-C.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: forward-port-vm.sh <workspace> port=PORT [server-on=guest|host]
       forward-port-vm.sh <workspace> on-host=PORT on-guest=PORT [server-on=guest|host]
  port=PORT         shorthand: same port number on both host and guest
  on-host=PORT      port number on the host (Mac) side
  on-guest=PORT     port number on the guest (VM)  side
  server-on=guest   server runs in the VM;  reach it on host  localhost:on-host  (default)
  server-on=host    server runs on the host; reach it on guest localhost:on-guest

  SSH_PORT env var (default 2222) sets the host port used to SSH into the VM.
EOF
    exit 1
}

if [ -z "${1:-}" ]; then
    usage
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

on_host=""
on_guest=""
both_port=""
server_on="guest"

for arg in "$@"; do
    case "$arg" in
        port=*)      both_port="${arg#port=}"       ;;
        on-host=*)   on_host="${arg#on-host=}"      ;;
        on-guest=*)  on_guest="${arg#on-guest=}"    ;;
        server-on=*) server_on="${arg#server-on=}"  ;;
        -h|--help)   usage ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage
            ;;
    esac
done

if [ -n "$both_port" ]; then
    if [ -n "$on_host" ] || [ -n "$on_guest" ]; then
        echo "port=PORT cannot be combined with on-host= or on-guest=." >&2
        exit 1
    fi
    on_host="$both_port"
    on_guest="$both_port"
fi

if [ -z "$on_host" ] || [ -z "$on_guest" ]; then
    echo "Specify port=PORT, or both on-host=PORT and on-guest=PORT." >&2
    usage
fi

for p in "$on_host" "$on_guest"; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        echo "Invalid port: $p (must be 1-65535)" >&2
        exit 1
    fi
done

case "$server_on" in
    guest)
        forward_flag="-L"
        forward_spec="${on_host}:localhost:${on_guest}"
        forward_desc="Forwarding  host localhost:${on_host}  -->  guest localhost:${on_guest}  (server in VM)"
        ;;
    host)
        forward_flag="-R"
        forward_spec="${on_guest}:localhost:${on_host}"
        forward_desc="Forwarding guest localhost:${on_guest}  -->   host localhost:${on_host}  (server on Mac)"
        ;;
    *)
        echo "server-on must be 'guest' or 'host', got: $server_on" >&2
        exit 1
        ;;
esac

if [ ! -f "$KEY" ]; then
    echo "SSH key not found at $KEY." >&2
    exit 1
fi

echo "$forward_desc"

echo "Press Ctrl-C to stop."

exec ssh \
    -i "$KEY" \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -N \
    "$forward_flag" "$forward_spec" \
    ubuntu@localhost
