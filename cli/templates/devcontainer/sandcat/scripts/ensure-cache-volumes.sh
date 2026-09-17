#!/bin/bash
#
# Creates the host-wide shared cache volumes (sandcat-cache-*) that
# compose-all.yml declares as `external: true`. Runs on the HOST as the
# devcontainer initializeCommand, so "Reopen in Container" from an IDE
# works on a machine where `sandcat run` has never created them.
#
# Idempotent: `docker volume create` on an existing name is a no-op.
# Silently does nothing when docker is missing so the IDE flow still
# gets compose's own, clearer error.
#
# Usage: ensure-cache-volumes.sh [compose-file]
# Default compose file: ../../compose-all.yml relative to this script.
set -euo pipefail

compose_file=${1:-"$(dirname "$0")/../../compose-all.yml"}

[ -f "$compose_file" ] || exit 0
command -v docker >/dev/null 2>&1 || exit 0

# Only the `name:` lines of the external volume declarations match this
# prefix, so no YAML parser is needed on the host. grep exits 1 on no
# match, which is the normal case for projects without cache volumes.
names=$(grep -E '^[[:space:]]+name:[[:space:]]+sandcat-cache-' "$compose_file" | awk '{print $2}' || true)

for name in $names; do
    docker volume create --label sandcat-shared-cache=true "$name" >/dev/null
done
