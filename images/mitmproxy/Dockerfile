# mitmproxy + 1Password CLI
#
# Extends the upstream mitmproxy image with the 1Password CLI (op),
# enabling op:// secret references in sandcat settings files.
# The mitmproxy addon resolves these references at startup via
# `op read`, authenticated with OP_SERVICE_ACCOUNT_TOKEN.
#
# Published as ghcr.io/virtuslab/sandcat-mitmproxy-op.
# Rebuilt weekly to track mitmproxy:latest.

FROM mitmproxy/mitmproxy:latest

ARG OP_CLI_VERSION=2.30.3

USER root
RUN ARCH=$(dpkg --print-architecture) \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl unzip \
    && curl -sSfo /tmp/op.zip "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_CLI_VERSION}/op_linux_${ARCH}_v${OP_CLI_VERSION}.zip" \
    && unzip /tmp/op.zip -d /usr/local/bin op \
    && rm /tmp/op.zip \
    && apt-get purge -y curl unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && op --version
USER mitmproxy
