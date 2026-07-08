#!/usr/bin/env bash
# capability-runtime/scripts/phase3e_engineering_gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."
pytest -q
PYTHONPATH=src python poc/network_route_demo.py >/dev/null
echo "== Manual proxy-peer gate =="
cat <<'EOF'
1. sandcat init --netbird --capability --proxy-peer --name <project>
2. docker compose -f .devcontainer/sandcat/compose-proxy-peer.yml up -d --build
3. sandcat netbird status  # note proxy-peer peer_id + mesh IP
4. Set capability-catalog.json: cap-reach-proxy peer_id + network <mesh-ip>/32
5. Merge settings-proxy-peer.json into .sandcat/settings.json (replace mesh IP)
6. sandcat restart-proxy && docker compose build capability-runtime && sandcat compose up -d
7. sandcat run curl -sf --connect-timeout 3 http://<mesh-ip>:8080/hello  # FAIL without lease
8. sandcat capability lease --ref cap-reach-proxy --justification "gate"
9. sandcat run curl -sf http://<mesh-ip>:8080/hello  # PASS
10. sandcat capability revoke --ref cap-reach-proxy --reason "gate"
11. sandcat run curl -sf --connect-timeout 3 http://<mesh-ip>:8080/hello  # FAIL
12. Lease with quota=2; three curls → auto-revoke (with CAPABILITY_L7_RECORD=1)
EOF
