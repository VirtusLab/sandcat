# mitmproxy + 1Password CLI
#
# Extends the upstream mitmproxy image with the 1Password CLI (op),
# enabling op:// secret references in sandcat settings files.
# The mitmproxy addon resolves these references at startup via
# `op read`, authenticated with OP_SERVICE_ACCOUNT_TOKEN.
#
# Published as ghcr.io/virtuslab/sandcat-mitmproxy-op.
#
# Dual-channel tag policy: versioned tags (e.g. 12.2.3) are built from master
# pushes against the pin in images/mitmproxy.env and are immutable. The
# `latest` tag is rebuilt weekly from upstream mitmproxy:latest as a
# best-effort tracking channel — it is NOT what pinned installs resolve to.
#
# MITMPROXY_VERSION has no default on purpose: the pin lives in exactly one
# place (images/mitmproxy.env) and MUST be supplied as a build arg (the build
# workflow sources that file; see images/mitmproxy.env for all consumers).
ARG MITMPROXY_VERSION

FROM mitmproxy/mitmproxy:${MITMPROXY_VERSION}

ARG OP_CLI_VERSION=2.30.3

# The upstream image runs as root; the entrypoint uses gosu to drop
# privileges to the mitmproxy user. Do not add USER mitmproxy here.
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
