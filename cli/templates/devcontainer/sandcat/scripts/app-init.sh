#!/bin/bash
#
# Entrypoint for containers that share the wg-client's network namespace.
# Installs the mitmproxy CA cert, disables commit signing, loads env vars
# and secret placeholders from sandcat.env, runs vscode-user setup (git
# identity, Java trust store, Claude Code update), then drops to vscode
# and exec's the container's main command.
#
set -e

# Adopt wg-client's resolv.conf. We share its network namespace via
# network_mode but each container has its own /etc/resolv.conf in its own
# mount namespace, so we have to copy it explicitly to point our DNS at
# wg-client's local dnsmasq (127.0.0.1) instead of whatever Docker wrote here.
# Use cat (not cp) because /etc/resolv.conf is bind-mounted by Docker and
# can't be replaced — only its contents can be rewritten in-place.
SHARED_RESOLV_CONF="/run/sandcat/resolv.conf"
if [ -f "$SHARED_RESOLV_CONF" ]; then
    cat "$SHARED_RESOLV_CONF" > /etc/resolv.conf
fi

CA_CERT="/mitmproxy-config/mitmproxy-ca-cert.pem"

# The CA cert is guaranteed to exist: app depends_on wg-client (healthy),
# which depends_on mitmproxy (healthy), whose healthcheck requires both
# wireguard.conf and mitmproxy-ca-cert.pem.
if [ ! -f "$CA_CERT" ]; then
    echo "mitmproxy CA cert not found at $CA_CERT" >&2
    exit 1
fi

cp "$CA_CERT" /usr/local/share/ca-certificates/mitmproxy.crt
update-ca-certificates

# Node.js ignores the system trust store and bundles its own CA certs.
# Point it at the mitmproxy CA so TLS verification works for Node-based
# tools (e.g. Anthropic SDK).
export NODE_EXTRA_CA_CERTS="$CA_CERT"

# Force Node.js to use the system CA store (via OpenSSL) instead of its
# bundled Mozilla roots. Required for tools that bundle their own Node.js
# binary where NODE_EXTRA_CA_CERTS alone may not suffice.
SANDCAT_NODE_OPTS="--use-openssl-ca"
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }$SANDCAT_NODE_OPTS"

cat > /etc/profile.d/sandcat-node-ca.sh << NODEEOF
export NODE_EXTRA_CA_CERTS="/mitmproxy-config/mitmproxy-ca-cert.pem"
export NODE_OPTIONS="\${NODE_OPTIONS:+\$NODE_OPTIONS }$SANDCAT_NODE_OPTS"
NODEEOF

# Some CLIs don't consistently use the system trust store in all code paths.
# Export common CA-related env vars so TLS clients prefer the updated Debian
# CA bundle (which now includes the mitmproxy CA).
CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
export SSL_CERT_FILE="$CA_BUNDLE"
export SSL_CERT_DIR="/etc/ssl/certs"
export CURL_CA_BUNDLE="$CA_BUNDLE"
export REQUESTS_CA_BUNDLE="$CA_BUNDLE"
export GIT_SSL_CAINFO="$CA_BUNDLE"
cat > /etc/profile.d/sandcat-ca.sh << CAEOF
export SSL_CERT_FILE="$CA_BUNDLE"
export SSL_CERT_DIR="/etc/ssl/certs"
export CURL_CA_BUNDLE="$CA_BUNDLE"
export REQUESTS_CA_BUNDLE="$CA_BUNDLE"
export GIT_SSL_CAINFO="$CA_BUNDLE"
CAEOF

# GPG keys are not forwarded into the container (credential isolation),
# so commit signing would always fail.  Git env vars have the highest
# precedence, overriding system/global/local/worktree config files.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="commit.gpgsign"
export GIT_CONFIG_VALUE_0="false"
cat > /etc/profile.d/sandcat-git.sh << 'GITEOF'
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="commit.gpgsign"
export GIT_CONFIG_VALUE_0="false"
GITEOF

# Source env vars and secret placeholders (if available)
SANDCAT_ENV="/mitmproxy-config/sandcat.env"
if [ -f "$SANDCAT_ENV" ]; then
    . "$SANDCAT_ENV"
    # Make vars available to new shells (e.g. VS Code terminals in dev
    # containers) that won't inherit the entrypoint's environment.
    cp "$SANDCAT_ENV" /etc/profile.d/sandcat-env.sh
    count=$(grep -c '^export ' "$SANDCAT_ENV" 2>/dev/null || echo 0)
    echo "Loaded $count env var(s) from $SANDCAT_ENV"
    grep '^export ' "$SANDCAT_ENV" | sed 's/=.*//' | sed 's/^export /  /'
else
    echo "No $SANDCAT_ENV found — env vars and secret substitution disabled"
fi

# Refresh image-managed home state (devbox profile, sandcat java-home
# symlink and baseline cacerts, .bashrc env hooks) into the agent-home
# volume when the image snapshot has changed since last start.
#
# The volume masks anything the Dockerfile writes under /home/vscode after
# it was first initialized, so without this sync, edits to devbox.stack.json
# or devbox.tools.json (or an updated JDK from the java block) never reach
# an existing container — users would need `docker compose down -v`, which
# wipes Claude auth and forces the IDE backend to re-upload.
#
# The snapshot lives in /opt/sandcat/snapshots/ (outside the volume mount)
# and is rebuilt from scratch on every image build (see Dockerfile.app).
# A content hash gates the rsync so unchanged rebuilds are no-ops.
SNAPSHOT_DIR="/opt/sandcat/snapshots"
SNAPSHOT_HASH_FILE="$SNAPSHOT_DIR/hash"
VOLUME_HASH_FILE="/home/vscode/.sandcat-snapshot-hash"
if [ -f "$SNAPSHOT_HASH_FILE" ]; then
    image_hash=$(cat "$SNAPSHOT_HASH_FILE")
    volume_hash=$(cat "$VOLUME_HASH_FILE" 2>/dev/null || echo "")
    if [ "$image_hash" != "$volume_hash" ]; then
        echo "sandcat: image snapshot changed, syncing home state to volume..."
        # devbox: --delete so removed packages disappear from the profile.
        # The whole subtree is image-owned; users never edit here directly.
        rsync -a --delete "$SNAPSHOT_DIR/devbox/" \
            /home/vscode/.local/share/devbox/
        # sandcat: no --delete because app-user-init.sh writes cacerts
        # (with the mitmproxy CA) here at runtime and we don't want to
        # blow that away between the sync and the reimport.
        if [ -d "$SNAPSHOT_DIR/sandcat" ]; then
            mkdir -p /home/vscode/.local/share/sandcat
            rsync -a "$SNAPSHOT_DIR/sandcat/" \
                /home/vscode/.local/share/sandcat/
        fi
        cp "$SNAPSHOT_DIR/bashrc" /home/vscode/.bashrc
        chown -R vscode:vscode \
            /home/vscode/.local/share/devbox \
            /home/vscode/.bashrc
        if [ -d /home/vscode/.local/share/sandcat ]; then
            chown -R vscode:vscode /home/vscode/.local/share/sandcat
        fi
        echo "$image_hash" > "$VOLUME_HASH_FILE"
        chown vscode:vscode "$VOLUME_HASH_FILE"
    fi
fi

# Shared-cache volumes (sandcat-cache-*) arrive as root:root because
# `docker volume create` produces empty root-owned volumes and Docker
# also creates any intermediate parent directories on the mount path as
# root when they don't yet exist in the image (e.g. .gradle/ when
# .gradle/caches/ is the mount target). Normalise ownership on both the
# mount roots and the intermediate parents so vscode can lay down
# tool-generated siblings like .m2/settings.xml or .gradle/daemon/.
#
# Only the listed directories are touched (non-recursive) — volumes
# shared with other projects can hold thousands of files, and the tools
# we care about only need the top-level dirs writable.
for cache_dir in \
    /home/vscode/.m2 \
    /home/vscode/.m2/repository \
    /home/vscode/.cache \
    /home/vscode/.cache/coursier \
    /home/vscode/.gradle \
    /home/vscode/.gradle/wrapper \
    /home/vscode/.gradle/caches \
    /home/vscode/.gradle/wrapper/dists \
    /home/vscode/.ivy2 \
    /home/vscode/.ivy2/cache \
    /home/vscode/.sbt \
    /home/vscode/.sbt/boot
do
    if [ -d "$cache_dir" ]; then
        chown vscode:vscode "$cache_dir" 2>/dev/null || true
    fi
done

# Run vscode-user tasks in a login shell so user profile customizations
# (PATH/NVM/direnv, etc.) are applied. Re-source sandcat.env inside that
# shell so app-user-init still receives sandcat placeholders and env vars.
su - vscode -c '. /mitmproxy-config/sandcat.env 2>/dev/null || true; /usr/local/bin/app-user-init.sh'

# Source all sandcat profile.d scripts from /etc/bash.bashrc so env vars
# are available in non-login shells (e.g. VS Code integrated terminals).
# Guard with a marker to avoid duplicating on container restart.
BASHRC_MARKER="# sandcat-profile-source"
if ! grep -q "$BASHRC_MARKER" /etc/bash.bashrc 2>/dev/null; then
    cat >> /etc/bash.bashrc << 'BASHRC_EOF'

# sandcat-profile-source
for _f in /etc/profile.d/sandcat-*.sh; do
    [ -r "$_f" ] && . "$_f"
done
unset _f
BASHRC_EOF
fi

exec gosu vscode "$@"
