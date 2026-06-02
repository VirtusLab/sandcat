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

# Keep checksums in sync with PASS_CLI_VERSION from Proton's versions listing.
ARG PASS_CLI_VERSION=2.1.2
ARG PASS_CLI_SHA256_X86_64=5291edd21d85d222538b91341345ae3b0a1479e254d42920c2bbbd34012c6243
ARG PASS_CLI_SHA256_AARCH64=0562625812f940bd4b7abd664b3bbcfefdeaf79d2f9b12f2d0a73be1ffc551ff

# Proton Pass CLI distributes binaries directly from proton.me (no GitHub releases).
# dpkg architecture names (amd64, arm64) differ from the download URL naming
# (x86_64, aarch64), so we map them explicitly.
# The upstream image runs as root; the entrypoint uses gosu to drop
# privileges to the mitmproxy user. Do not add USER mitmproxy here.
RUN DPKG_ARCH=$(dpkg --print-architecture) \
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
