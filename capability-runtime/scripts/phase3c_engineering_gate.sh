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
2. Set real peer_id/route_id in .devcontainer/sandcat/capability-catalog.json
3. sandcat compose up -d
4. sandcat capability lease --ref cap-reach-api --justification "gate"
5. sandcat capability check          # reach_api in bundle
6. sandcat netbird status            # route enabled within 30s
7. ping mesh target via wt0          # reachable while leased
8. sandcat capability revoke --ref cap-reach-api --reason "gate"
9. sandcat capability check          # reach_api absent
10. sandcat netbird status           # route disabled; peer remains
11. sandcat capability watch         # JSONL shows grant/revoke + physical_sync
EOF
