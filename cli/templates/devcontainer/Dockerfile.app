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

# The devcontainers base image grants vscode passwordless sudo
# (/etc/sudoers.d/vscode: `vscode ALL=(root) NOPASSWD:ALL`). Sandcat's
# design gives the agent no legitimate sudo use — every root-phase step
# runs in the entrypoint (app-init.sh) before it drops to vscode via gosu.
# Remove the grant so the image is hardened even when run outside sandcat's
# compose; inside compose this is the image-level layer of the same defense
# whose runtime layer is `security_opt: no-new-privileges` (issue #12, #90).
RUN rm -f /etc/sudoers.d/vscode

COPY --chmod=755 sandcat/scripts/app-init.sh /usr/local/bin/app-init.sh
COPY --chmod=755 sandcat/scripts/app-user-init.sh /usr/local/bin/app-user-init.sh
COPY --chmod=644 sandcat/scripts/java-env.sh /etc/profile.d/sandcat-java.sh
COPY --chown=vscode:vscode sandcat/tmux.conf /home/vscode/.tmux.conf

USER vscode

ENV LANG="en_US.UTF-8"

# __AGENT_DOCKER_INSTALL__

# __DEVBOX_INSTALL__

# __AGENT_DOCKER_HOME_PREP__

USER root
# Snapshot the image-side /home/vscode state that the agent-home volume
# will mask at runtime (devbox profile with symlinks into /nix/store, the
# sandcat helper dir with java-home + baseline cacerts, and .bashrc). app-init.sh
# rsyncs this back into the volume when the snapshot
# hash changes, so rebuilds that add/remove packages or switch JDKs take
# effect without `docker compose down -v` (which would wipe auth Claude
# Code and force the IDE backend to re-upload).
#
# The hash covers merged devbox.json + .bashrc. Any stack or tools change
# flips at least one of them; unchanged rebuilds
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
