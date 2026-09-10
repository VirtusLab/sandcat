#!/bin/sh
# Entrypoint wrapper for the dind service (Docker in the sandbox, #70).
# Runs BEFORE the nested dockerd:
#   1. installs the mitmproxy CA into the system store — must happen before
#      dockerd starts, because Go loads the x509 pool once per process;
#      without it `docker pull` cannot pass the TLS bump on the registry,
#   2. replaces the default route with wg-client, so all egress from this
#      namespace (and every inner container NATed through it) transits
#      wg0 → mitmproxy — fail-loud: no route means no unproxied fallback,
#   3. publishes the docker CLI onto the shared socket volume for the agent,
#   4. makes the socket accessible to the agent's vscode user (gid 1000).
set -eu

cp /mitmproxy-config/mitmproxy-ca-cert.pem \
   /usr/local/share/ca-certificates/sandcat-mitm-ca.crt
update-ca-certificates >/dev/null 2>&1

WG_IP=""
i=0
while [ -z "$WG_IP" ]; do
    WG_IP=$(getent hosts wg-client 2>/dev/null | awk '{print $1; exit}') || true
    if [ -z "$WG_IP" ]; then
        WG_IP=$(nslookup wg-client 2>/dev/null \
            | awk '/^Address/ && $2 !~ /#|:53/ {ip=$2} END {print ip}') || true
    fi
    [ -n "$WG_IP" ] && break
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
        echo "[dind] cannot resolve wg-client; refusing to start with an unproxied route" >&2
        exit 1
    fi
    sleep 1
done
ip route replace default via "$WG_IP"
echo "[dind] default route via wg-client ($WG_IP)"

mkdir -p /docker-sock/bin
cp /usr/local/bin/docker /docker-sock/bin/docker

# Group 1000 matches the agent's vscode gid; dockerd chgrps the socket to it.
addgroup -g 1000 sandcat 2>/dev/null || true

exec dockerd-entrypoint.sh dockerd \
    --host=unix:///docker-sock/docker.sock \
    --group sandcat
