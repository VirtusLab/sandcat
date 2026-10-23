# Pre-built by sandcat (images/agent-base): devcontainers base, apt tools,
# Nix, devbox and the baseline shell tools.
FROM __AGENT_BASE_IMAGE__

# The devcontainers base image grants vscode passwordless sudo
# (/etc/sudoers.d/vscode: `vscode ALL=(root) NOPASSWD:ALL`). Sandcat's
# design gives the agent no legitimate sudo use — every root-phase step
# runs in the entrypoint (app-init.sh) before it drops to vscode via gosu.
# Remove the grant so the image is hardened even when run outside sandcat's
# compose; inside compose this is the image-level layer of the same defense
# whose runtime layer is `security_opt: no-new-privileges` (issue #12, #90).
USER root
RUN rm -f /etc/sudoers.d/vscode

# Devbox goes first: its layers are multi-GB, and anything above it that
# differs per agent or sandcat release would force a rebuild and re-export.

# __DEVBOX_INSTALL__

# __AGENT_DOCKER_INSTALL__

COPY --chmod=755 sandcat/scripts/app-init.sh /usr/local/bin/app-init.sh
COPY --chmod=755 sandcat/scripts/app-user-init.sh /usr/local/bin/app-user-init.sh
COPY --chmod=644 sandcat/scripts/java-env.sh /etc/profile.d/sandcat-java.sh
COPY --chown=vscode:vscode sandcat/tmux.conf /home/vscode/.tmux.conf

# __AGENT_DOCKER_HOME_PREP__

USER root
# Snapshot the image-side /home/vscode state that the agent-home volume
# will mask at runtime (Nix and devbox profiles with symlinks into
# /nix/store, the sandcat helper dir with java-home + baseline cacerts,
# and .bashrc). app-init.sh rsyncs this back into the volume when the
# snapshot hash changes, so rebuilds that add/remove packages, switch JDKs
# or pull a new base image take effect without `docker compose down -v`
# (which would wipe auth Claude Code and force the IDE backend to re-upload).
#
# The hash covers the /nix/store paths both profiles resolve to, plus
# .bashrc. These change whenever the volume's symlinks would point at
# store paths missing from the image, e.g. after a base image update
# that leaves devbox.json unchanged. Unchanged rebuilds leave the hash
# stable so app-init.sh skips the sync entirely.
RUN mkdir -p /opt/sandcat/snapshots \
 && cp -a /home/vscode/.local/share/devbox /opt/sandcat/snapshots/devbox \
 && cp -a /home/vscode/.local/state/nix /opt/sandcat/snapshots/nix-state \
 && if [ -d /home/vscode/.local/share/sandcat ]; then \
      cp -a /home/vscode/.local/share/sandcat /opt/sandcat/snapshots/sandcat; \
    fi \
 && cp /home/vscode/.bashrc /opt/sandcat/snapshots/bashrc \
 && store_paths=$(readlink -e /home/vscode/.nix-profile \
      /home/vscode/.local/share/devbox/global/default/.devbox/nix/profile/default) \
 && { echo "$store_paths"; sha256sum /opt/sandcat/snapshots/bashrc; } \
    | sha256sum | cut -d' ' -f1 > /opt/sandcat/snapshots/hash

ENTRYPOINT ["/usr/local/bin/app-init.sh"]
