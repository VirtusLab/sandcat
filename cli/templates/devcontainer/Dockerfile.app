FROM mcr.microsoft.com/devcontainers/base:debian

# ca-certificates, curl, git are already in the devcontainers base image.
# The three tools below all run before devbox is usable, so they have to
# come from apt — devbox packages live under /home/vscode (masked by the
# agent-home volume) and require the vscode-user shellenv to be on PATH.
#
# gosu:  drops privileges in the entrypoint. Invoked by root before any
#        user profile is set up, so it can't come from devbox.
# jq:    merges devbox.stack.json + devbox.tools.json at build time
#        (see cli/lib/devbox.bash). Bootstrap: we need jq to install
#        devbox's config, so it can't itself come from devbox.
# rsync: refreshes the image-side /home/vscode snapshot into the
#        agent-home volume in app-init.sh. Root-invoked and it's the
#        very tool syncing devbox into the volume — can't live in
#        the volume it syncs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gosu jq rsync \
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
# JDK-distribution-agnostic detection: devbox always exposes bin/java in
# its profile as a symlink to the actual JDK inside /nix/store/. Following
# that symlink and stripping bin/ gives the canonical JAVA_HOME for
# whichever distribution the user picked (openjdk, temurin-bin-*, jdk,
# jetbrains.jdk*, or any future one) — no hardcoded layout assumptions.
# Every valid JDK derivation has $JAVA_HOME/lib/security/cacerts inside.
#
# JAVA_TOOL_OPTIONS points to a trust store copy that app-user-init.sh
# populates with the mitmproxy CA at runtime; until then it holds the
# default Java CAs (harmless).
RUN JAVA_BIN="$HOME/.local/share/devbox/global/default/.devbox/nix/profile/default/bin/java"; \
    if [ -e "$JAVA_BIN" ]; then \
      DEVBOX_JAVA="$(dirname $(dirname $(readlink -f "$JAVA_BIN")))"; \
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
# Snapshot the image-side /home/vscode state that the agent-home volume
# will mask at runtime (devbox profile with symlinks into /nix/store, the
# sandcat helper dir with java-home + baseline cacerts, and .bashrc env
# hooks). app-init.sh rsyncs this back into the volume when the snapshot
# hash changes, so rebuilds that add/remove packages or switch JDKs take
# effect without `docker compose down -v` (which would wipe auth Claude
# Code and force the IDE backend to re-upload).
#
# The hash covers merged devbox.json + .bashrc — the two files that
# capture "what packages devbox installed" and "what env we bake". Any
# stack/tools/Java change flips at least one of them; unchanged rebuilds
# leave the hash stable so app-init.sh skips the sync entirely.
RUN mkdir -p /opt/sandcat/snapshots \
 && cp -a /home/vscode/.local/share/devbox /opt/sandcat/snapshots/devbox \
 && if [ -d /home/vscode/.local/share/sandcat ]; then \
      cp -a /home/vscode/.local/share/sandcat /opt/sandcat/snapshots/sandcat; \
    fi \
 && cp /home/vscode/.bashrc /opt/sandcat/snapshots/bashrc \
 && sha256sum \
      /opt/sandcat/snapshots/devbox/global/default/devbox.json \
      /opt/sandcat/snapshots/bashrc \
    | sha256sum | cut -d' ' -f1 > /opt/sandcat/snapshots/hash

ENTRYPOINT ["/usr/local/bin/app-init.sh"]
