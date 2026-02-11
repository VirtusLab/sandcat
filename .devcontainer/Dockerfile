FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends gh vim \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/sandcat-init.sh /usr/local/bin/sandcat-init.sh
RUN chmod +x /usr/local/bin/sandcat-init.sh

ENTRYPOINT ["/usr/local/bin/sandcat-init.sh"]
