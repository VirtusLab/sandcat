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
    && rm -rf /var/lib/apt/lists/*
USER mitmproxy
