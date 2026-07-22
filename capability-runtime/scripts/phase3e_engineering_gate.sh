#!/usr/bin/env bash
# capability-runtime/scripts/phase3e_engineering_gate.sh
set -euo pipefail
cd "$(dirname "$0")/.."
pytest -q
PYTHONPATH=src python poc/network_route_demo.py >/dev/null
echo "== Manual proxy-peer gate (NetBird DNS mode) =="
cat <<'EOF'
Prerequisites
  - NetBird DNS enabled in the dashboard: Settings → DNS → Nameservers, group All
  - proxy-peer enrolled with a stable NetBird peer name (e.g. "peer-proxy")

Steps
1. sandcat init --netbird --capability --proxy-peer --name <project>
2. docker compose -f .devcontainer/sandcat/compose-proxy-peer.yml up -d --build
3. sandcat netbird status  # verify proxy-peer dns_label = peer-proxy.netbird.selfhosted
4. capability-catalog.json already has dns_label="peer-proxy.netbird.selfhosted"; no IP to update
5. Merge settings-proxy-peer.json into .sandcat/settings.json (already uses FQDN)
6. sandcat restart-proxy && docker compose build capability-runtime && sandcat compose up -d
7. sandcat run curl -sf --connect-timeout 3 http://peer-proxy.netbird.selfhosted:8080/hello  # FAIL without lease
8. sandcat capability lease --ref cap-reach-proxy --justification "gate"
9. sandcat run curl -sf http://peer-proxy.netbird.selfhosted:8080/hello  # PASS
10. sandcat capability revoke --ref cap-reach-proxy --reason "gate"
11. sandcat run curl -sf --connect-timeout 3 http://peer-proxy.netbird.selfhosted:8080/hello  # FAIL
12. Lease with quota=2; three curls → auto-revoke (with CAPABILITY_L7_RECORD=1)

IP-only fallback (NetBird DNS not enabled)
  - In capability-catalog.json set peer_id and network=<mesh-ip>/32 directly (omit dns_label)
  - In .sandcat/settings.json set host to the mesh IP instead of the FQDN
  - Steps 7-12 use http://<mesh-ip>:8080/hello
EOF
