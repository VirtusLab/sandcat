FROM mcr.microsoft.com/devcontainers/base:debian

# ca-certificates, curl, git are already in the devcontainers base image.
# gosu: drops privileges in the entrypoint.
# jq:   used at build time to merge devbox.stack.json + devbox.tools.json
#       into the single global devbox config (see cli/lib/devbox.bash).
RUN apt-get update \
    && apt-get install -y --no-install-recommends gosu jq \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 sandcat/scripts/app-init.sh /usr/local/bin/app-init.sh
COPY --chmod=755 sandcat/scripts/app-user-init.sh /usr/local/bin/app-user-init.sh
COPY --chown=vscode:vscode sandcat/tmux.conf /home/vscode/.tmux.conf

USER vscode

ENV LANG="en_US.UTF-8"

# __AGENT_DOCKER_INSTALL__

# __DEVBOX_INSTALL__

# If a JDK is installed via devbox (java or scala stack, or a user entry
# in devbox.tools.json), bake JAVA_HOME and JAVA_TOOL_OPTIONS into .bashrc
# so VS Code's env probe picks them up before the entrypoint runs. Without
# JAVA_HOME, JVM tooling like Metals fails to find the JDK.
#
# Two JDK layouts appear in nixpkgs:
#   * Nested (nixpkgs `openjdk` package): java at $PROFILE/lib/openjdk/bin/java
#   * Flat   (`temurin-bin-*`, `jetbrains.jdk*`, `jdk`): java at $PROFILE/bin/java
# The block below detects whichever is present and points the sandcat
# symlink at the correct root (so $JAVA_HOME/bin/java always resolves).
#
# JAVA_TOOL_OPTIONS points to a trust store copy that app-user-init.sh
# populates with the mitmproxy CA at runtime; until then it holds the
# default Java CAs (harmless).
RUN DEVBOX_PROFILE="$HOME/.local/share/devbox/global/default/.devbox/nix/profile/default"; \
    if   [ -e "$DEVBOX_PROFILE/lib/openjdk/bin/java" ]; then \
      DEVBOX_JAVA="$DEVBOX_PROFILE/lib/openjdk"; \
    elif [ -e "$DEVBOX_PROFILE/bin/java" ] && [ -f "$DEVBOX_PROFILE/lib/security/cacerts" ]; then \
      DEVBOX_JAVA="$DEVBOX_PROFILE"; \
    fi; \
    if [ -n "$DEVBOX_JAVA" ]; then \
      dir="$HOME/.local/share/sandcat"; mkdir -p "$dir"; \
      ln -sfn "$DEVBOX_JAVA" "$dir/java-home"; \
      { echo ''; \
        echo '# sandcat-java-env'; \
        echo '[ -L "$HOME/.local/share/sandcat/java-home" ] && export JAVA_HOME="$HOME/.local/share/sandcat/java-home"'; \
        echo '[ -f "$HOME/.local/share/sandcat/cacerts" ] && export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$HOME/.local/share/sandcat/cacerts -Djavax.net.ssl.trustStorePassword=changeit"'; \
      } >> "$HOME/.bashrc"; \
    fi

# __AGENT_DOCKER_HOME_PREP__

USER root
ENTRYPOINT ["/usr/local/bin/app-init.sh"]
