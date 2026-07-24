#!/bin/bash
#
# vscode-user tasks run via su from app-init.sh.
# /etc/profile.d/ is sourced by the login shell, providing
# GIT_USER_NAME, GIT_USER_EMAIL, and NODE_EXTRA_CA_CERTS.
#
set -e

# app-init uses `su - vscode` (login shell). Keep HOME explicit so git config
# and related tools always write to the expected location.
export HOME="/home/vscode"

if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# GPG keys are not forwarded into the container (credential isolation),
# so commit signing would always fail. Disable it via global config as a
# baseline; app-init.sh also sets GIT_CONFIG env vars which override even
# repo-level config.
git config --global commit.gpgsign false

# SSH keys are not available in the container (SSH_AUTH_SOCK is cleared
# and credential sockets are removed), so rewrite git SSH URLs to HTTPS.
# Sandcat's secret substitution handles GitHub token authentication over
# HTTPS transparently.
git config --global --replace-all url."https://github.com/".insteadOf "git@github.com:" "git@github.com:"
git config --global --replace-all url."https://github.com/".insteadOf "ssh://git@github.com/" "ssh://git@github.com/"

# Mark mounted workspaces as safe Git directories to avoid
# "detected dubious ownership" errors in devcontainers.
for ws_dir in /workspaces/*; do
    [ -d "$ws_dir" ] || continue
    if ! git config --global --get-all safe.directory | grep -Fx "$ws_dir" >/dev/null 2>&1; then
        git config --global --add safe.directory "$ws_dir"
    fi
done

# If openjdk was installed via devbox (as a --stacks java or scala package,
# or explicitly in devbox.tools.json), import the mitmproxy CA into a
# writable Java trust store copy. Java has its own cacerts and ignores
# the system CA store.
#
# Key difference from the previous mise-based flow: Nix stores are
# read-only, so the openjdk cacerts inside the Nix store cannot be
# modified in place. We copy it to $SANDCAT_DIR first (cp preserves
# the read-only mode), chmod it writable, and then run keytool on the
# copy. JAVA_TOOL_OPTIONS in Dockerfile.app already points every JVM
# at this copy.
CA_CERT="/mitmproxy-config/mitmproxy-ca-cert.pem"

# JDK-distribution-agnostic: follow devbox profile's bin/java symlink
# into /nix/store/ and strip bin/ to get the canonical JAVA_HOME.
# Works for openjdk, temurin-bin-*, jdk, jetbrains.jdk*, and any other
# valid JDK derivation — no hardcoded layout assumptions. See the same
# pattern in Dockerfile.app for the build-time equivalent.
DEVBOX_JAVA_BIN="$HOME/.local/share/devbox/global/default/.devbox/nix/profile/default/bin/java"
DEVBOX_JAVA_HOME=""
if [ -e "$DEVBOX_JAVA_BIN" ]; then
    DEVBOX_JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$DEVBOX_JAVA_BIN")")")"
fi

if [ -n "$DEVBOX_JAVA_HOME" ] && [ -f "$CA_CERT" ]; then
    SANDCAT_DIR="$HOME/.local/share/sandcat"
    mkdir -p "$SANDCAT_DIR"
    # Refresh the symlink each start so a devbox openjdk update lands here.
    ln -sfn "$DEVBOX_JAVA_HOME" "$SANDCAT_DIR/java-home"

    NIX_CACERTS="$DEVBOX_JAVA_HOME/lib/security/cacerts"
    SANDCAT_CACERTS="$SANDCAT_DIR/cacerts"
    if [ -f "$NIX_CACERTS" ]; then
        # Copy first (destination inherits Nix store's 0444 mode), then
        # make writable so keytool can update it. Copying happens every
        # start so a devbox update to openjdk gets a fresh baseline
        # before we re-import mitmproxy CA.
        cp "$NIX_CACERTS" "$SANDCAT_CACERTS"
        chmod 0644 "$SANDCAT_CACERTS"

        # Import into the writable copy only. The Nix store original stays
        # untouched (immutable by design). On restart the alias already
        # exists and the second import is a harmless no-op.
        if "$DEVBOX_JAVA_HOME/bin/keytool" -importcert -trustcacerts -noprompt \
            -alias mitmproxy \
            -file "$CA_CERT" \
            -keystore "$SANDCAT_CACERTS" \
            -storepass changeit >/dev/null 2>&1; then
            echo "Imported mitmproxy CA into Java trust store"
        fi

        # scala-cli is a GraalVM native binary that ignores JAVA_TOOL_OPTIONS
        # and JAVA_HOME for trust store resolution. Pre-create its config
        # so the trust store is used even if scala-cli isn't installed yet
        # (e.g. when Metals downloads it later).
        SCALACLI_CONFIG="$HOME/.local/share/scalacli/secrets/config.json"
        mkdir -p "$(dirname "$SCALACLI_CONFIG")"
        cat > "$SCALACLI_CONFIG" << EOFJSON
{
  "java": {
    "properties": ["javax.net.ssl.trustStore=$SANDCAT_CACERTS","javax.net.ssl.trustStorePassword=changeit"]
  }
}
EOFJSON

    fi
fi

__AGENT_USER_INIT__

