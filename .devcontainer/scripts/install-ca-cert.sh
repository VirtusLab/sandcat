#!/bin/bash
#
# Entrypoint for containers that share the wg-client's network namespace.
# Installs the mitmproxy CA certificate into the system trust store so that
# TLS interception works transparently for tools using the system CA bundle
# (curl, git, cargo, rustls-native-certs).
#
set -e

CA_CERT="/mitmproxy-config/mitmproxy-ca-cert.pem"

# The CA cert should already exist (wg-client depends_on mitmproxy healthy),
# but wait briefly in case of a slight race on the shared volume.
elapsed=0
while [ ! -f "$CA_CERT" ]; do
    if [ "$elapsed" -ge 30 ]; then
        echo "Timed out waiting for mitmproxy CA cert" >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

cp "$CA_CERT" /usr/local/share/ca-certificates/mitmproxy.crt
update-ca-certificates

exec "$@"
