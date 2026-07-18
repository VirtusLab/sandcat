FROM mcr.microsoft.com/devcontainers/base:debian

# ca-certificates, curl, git are already in the devcontainers base image.
# gosu:     drops privileges in the entrypoint
RUN apt-get update \
    && apt-get install -y --no-install-recommends gosu \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 sandcat/scripts/app-init.sh /usr/local/bin/app-init.sh
COPY --chmod=755 sandcat/scripts/app-user-init.sh /usr/local/bin/app-user-init.sh
COPY --chown=vscode:vscode sandcat/tmux.conf /home/vscode/.tmux.conf

USER vscode

# __AGENT_DOCKER_INSTALL__

# Install mise (SDK manager) for language toolchains.
RUN curl https://mise.run | sh
# Make mise available in login shells (su - vscode) and Docker CMD/RUN.
RUN echo 'export PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:$PATH"' >> /home/vscode/.profile
ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:$PATH"
ENV LANG="en_US.UTF-8"

# Development stacks (managed by sandcat init --stacks):
# END STACKS

# If Java was installed above, bake JAVA_HOME and JAVA_TOOL_OPTIONS into
# .bashrc so VS Code's env probe picks them up before the entrypoint runs.
# Without JAVA_HOME, JVM tooling like Metals fails to find the JDK.
# JAVA_TOOL_OPTIONS points to a trust store copy that the entrypoint will
# populate with the mitmproxy CA at runtime; until then it holds the default
# Java CAs (harmless — equivalent to not setting it at all).
# A version-independent symlink is used so .bashrc doesn't need updating
# when the Java version changes — only the symlink target is updated.
RUN if MISE_JAVA=$(mise where java 2>/dev/null); then \
    dir="$HOME/.local/share/sandcat"; mkdir -p "$dir"; \
    ln -sfn "$MISE_JAVA" "$dir/java-home"; \
    cp "$MISE_JAVA/lib/security/cacerts" "$dir/cacerts" 2>/dev/null || true; \
    { echo ''; \
    echo '# sandcat-java-env'; \
    echo '[ -L "$HOME/.local/share/sandcat/java-home" ] && export JAVA_HOME="$HOME/.local/share/sandcat/java-home"'; \
    echo '[ -f "$HOME/.local/share/sandcat/cacerts" ] && export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$HOME/.local/share/sandcat/cacerts -Djavax.net.ssl.trustStorePassword=changeit"'; \
    } >> "$HOME/.bashrc"; \
    fi

# __DEVBOX_INSTALL__

# __AGENT_DOCKER_HOME_PREP__

USER root
ENTRYPOINT ["/usr/local/bin/app-init.sh"]
