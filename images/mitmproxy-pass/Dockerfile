# mitmproxy + Proton Pass CLI
#
# Extends the upstream mitmproxy image with the Proton Pass CLI (pass-cli),
# enabling pass:// secret references in sandcat settings files.
# The mitmproxy addon resolves these references at startup via
# `pass-cli item view`, authenticated with a scoped Personal Access Token
# set through PROTON_PASS_PERSONAL_ACCESS_TOKEN.
#
# IMPORTANT: use a Proton Pass Personal Access Token (PAT), NOT your account
# password. Create one with `pass-cli pat create` and grant it read-only
# access to only the vaults/items this project needs:
#   pass-cli pat create --name "sandcat" --expiration 3m
#   pass-cli pat access grant --pat-name "sandcat" --vault-name "MyVault" --role viewer
#
# Published as ghcr.io/virtuslab/sandcat-mitmproxy-pass.
# Rebuilt weekly to track mitmproxy:latest.

FROM mitmproxy/mitmproxy:latest

# Version + per-arch checksums are the single source of truth in
# images/mitmproxy-pass/pass-cli.env and MUST be supplied as build args
# (the build workflow and the local-build docs source that file). No defaults
# here on purpose, so the pin lives in exactly one place.
ARG PASS_CLI_VERSION
ARG PASS_CLI_SHA256_X86_64
ARG PASS_CLI_SHA256_AARCH64

# Proton Pass CLI distributes binaries directly from proton.me (no GitHub releases).
# dpkg architecture names (amd64, arm64) differ from the download URL naming
# (x86_64, aarch64), so we map them explicitly.
# The upstream image runs as root; the entrypoint uses gosu to drop
# privileges to the mitmproxy user. Do not add USER mitmproxy here.
RUN test -n "$PASS_CLI_VERSION" || { echo "PASS_CLI_VERSION build arg is required (source pass-cli.env)" >&2; exit 1; } \
    && DPKG_ARCH=$(dpkg --print-architecture) \
    && case "$DPKG_ARCH" in \
         amd64)   DL_ARCH=x86_64;  PASS_CLI_SHA256="$PASS_CLI_SHA256_X86_64" ;; \
         arm64)   DL_ARCH=aarch64; PASS_CLI_SHA256="$PASS_CLI_SHA256_AARCH64" ;; \
         *)       echo "Unsupported architecture: $DPKG_ARCH" >&2; exit 1 ;; \
       esac \
    && test -n "$PASS_CLI_SHA256" \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && curl -sSfLo /usr/local/bin/pass-cli \
        "https://proton.me/download/pass-cli/${PASS_CLI_VERSION}/pass-cli-linux-${DL_ARCH}" \
    && echo "${PASS_CLI_SHA256}  /usr/local/bin/pass-cli" | sha256sum -c - \
    && chmod +x /usr/local/bin/pass-cli \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && pass-cli --version

# pass-cli stores session data under the mitmproxy user's home directory.
# The mitmproxy entrypoint runs as mitmproxy (uid 1000), so the session
# directory must be writable by that user.
# Using filesystem key storage (PROTON_PASS_KEY_PROVIDER=fs) because the
# kernel keyring is not available inside Docker containers.
ENV PROTON_PASS_KEY_PROVIDER=fs
