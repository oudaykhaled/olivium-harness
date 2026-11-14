#!/bin/bash
# Creates or removes the two benchmark networks.
#   net.sh up [suffix]     internal network (agent <-> meter only) + egress (meter only)
#   net.sh down [suffix]
# The internal network has no host-side gateway address, so containers on it
# cannot reach the Docker host, and no default route.
set -euo pipefail
suffix="${2:-main}"
internal="olivium-bench-int-${suffix}"
egress="olivium-bench-egress-${suffix}"
case "${1:-}" in
  up)
    docker network inspect "$internal" >/dev/null 2>&1 || docker network create \
      --internal --label olivium-bench=1 \
      -o com.docker.network.bridge.gateway_mode_ipv4=isolated \
      "$internal" >/dev/null
    docker network inspect "$egress" >/dev/null 2>&1 || docker network create \
      --label olivium-bench=1 "$egress" >/dev/null
    echo "$internal $egress"
    ;;
  down)
    docker network rm "$internal" "$egress" >/dev/null 2>&1 || true
    ;;
  *) echo "usage: net.sh up|down [suffix]" >&2; exit 2 ;;
esac
