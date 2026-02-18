#!/bin/bash
#
# vscode-user tasks run via su from app-init.sh.
# /etc/profile.d/ is sourced by the login shell, providing
# GIT_USER_NAME, GIT_USER_EMAIL, and NODE_EXTRA_CA_CERTS.
#
set -e

if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# If Java is installed (via mise), import the mitmproxy CA into Java's trust
# store. Java uses its own cacerts and ignores the system CA store.
CA_CERT="/mitmproxy-config/mitmproxy-ca-cert.pem"
MISE_JAVA_HOME="$(mise where java 2>/dev/null || true)"
if [ -n "$MISE_JAVA_HOME" ] && [ -f "$CA_CERT" ]; then
    # Create a version-independent symlink so JAVA_HOME (exported via
    # /etc/profile.d/) doesn't depend on the mise Java version.
    SANDCAT_DIR="$HOME/.local/share/sandcat"
    mkdir -p "$SANDCAT_DIR"
    ln -sfn "$MISE_JAVA_HOME" "$SANDCAT_DIR/java-home"

    JAVA_CACERTS="$MISE_JAVA_HOME/lib/security/cacerts"
    if [ -f "$JAVA_CACERTS" ]; then
        if keytool -importcert -trustcacerts -noprompt \
            -alias mitmproxy \
            -file "$CA_CERT" \
            -keystore "$JAVA_CACERTS" \
            -storepass changeit >/dev/null 2>&1; then
            echo "Imported mitmproxy CA into Java trust store"
            # Create a standalone copy of the trust store (with the mitmproxy
            # CA) so JAVA_TOOL_OPTIONS can point all JVMs to it — including
            # ones downloaded later by tools like Coursier (Scala Metals).
            SANDCAT_CACERTS="$SANDCAT_DIR/cacerts"
            cp "$JAVA_CACERTS" "$SANDCAT_CACERTS"
            echo "$SANDCAT_CACERTS" > /tmp/sandcat-java-cacerts-path

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
        else
            echo "Failed to import mitmproxy CA into Java trust store" >&2
        fi
    fi
fi

# Best-effort: may fail if network isn't routed yet or CLI was just installed.
claude update || true
