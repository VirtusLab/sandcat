# Base of the agent image (Dockerfile.app in generated projects): the parts
# that don't depend on the agent or the selected stacks. Published to GHCR
# so a first sandbox build pulls these layers instead of building them.
#
# devbox.json (baseline shell tools) is generated before the build, from
# the repository root:
#   bash -c 'source cli/lib/devbox.bash && write_devbox_stack_json images/agent-base/devbox.json'

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

ENV LANG="en_US.UTF-8"

# Prep /nix owned by vscode. Single-user Nix (which we need — see below)
# requires a user-writable /nix.
RUN mkdir -m 0755 /nix && chown vscode /nix
# Install devbox launcher. The installer writes /usr/local/bin/devbox as
# mode 711 (root:root, no read bit for others). It's a bash launcher, not
# a native binary, so bash can't read the shebang as non-root and exec
# fails with EACCES. Force 0755 so vscode can execute it.
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f \
    && chmod 0755 /usr/local/bin/devbox

USER vscode
# Preinstall Nix in single-user mode BEFORE devbox gets a chance.
# `devbox global install` on a fresh system triggers Determinate's
# `nix-installer`, which defaults to multi-user (systemd-managed daemon)
# whenever sudo is available. Containers based on debian have sudo but
# no systemd, so the daemon never starts, and later `nix` commands fail
# with "cannot connect to socket at /nix/var/nix/daemon-socket/socket"
# and "opening lock file /nix/var/nix/db/big-lock: Permission denied".
# The classic nixos.org installer with --no-daemon reliably yields a
# single-user install that works under vscode's UID.
RUN curl -fsSL -L https://nixos.org/nix/install \
    | sh -s -- --no-daemon --no-modify-profile --yes
ENV PATH="/home/vscode/.nix-profile/bin:${PATH}"

# Baseline packages. The devbox.lock written here pins their versions, so
# installing a project's stacks on top only fetches the stack packages.
COPY --chown=vscode:vscode devbox.json /home/vscode/.local/share/devbox/global/default/devbox.json
RUN . /home/vscode/.nix-profile/etc/profile.d/nix.sh \
 && devbox global install
