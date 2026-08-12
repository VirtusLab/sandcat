#!/usr/bin/env bash
# capability-runtime/scripts/phase3c_engineering_gate.sh
set -euo pipefail

echo "== Phase 3c unit gate =="
cd "$(dirname "$0")/.."
pytest -q

echo "== Phase 3c PoC demo =="
PYTHONPATH=src python poc/network_route_demo.py >/dev/null
echo "PoC demo: OK"

echo "== Manual steps (require enrolled NetBird + NB_API_TOKEN) =="
cat <<'EOF'
1. sandcat init --netbird --capability --name <project>
2. Bring up the stack: sandcat compose up -d
   NetBird enrolls on the mitmproxy container (not wg-client).
   The mitmproxy peer appears in the NetBird management dashboard.
3. Find the mitmproxy peer ID:
     docker compose exec mitmproxy netbird status --json | jq -r '.id'
   Or look for the 'sandcat-proxy' hostname in the NetBird dashboard.
4. Set real peer_id (mitmproxy peer) and route_id in
   .devcontainer/sandcat/capability-catalog.json
5. Restart capability-runtime to reload catalog:
     sandcat compose restart capability-runtime
6. sandcat capability lease --ref cap-reach-api --justification "gate"
7. sandcat capability check          # reach_api in bundle
8. docker compose exec mitmproxy netbird routes list   # route enabled
9. sandcat run curl http://<mesh-target>   # reachable via mitmproxy wt0
10. sandcat capability revoke --ref cap-reach-api --reason "gate"
11. sandcat capability check          # reach_api absent
12. docker compose exec mitmproxy netbird routes list  # route disabled; peer remains
13. sandcat capability watch          # JSONL shows grant/revoke + physical_sync
EOF
