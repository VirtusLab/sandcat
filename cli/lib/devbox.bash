#!/usr/bin/env bash
# Devbox feature: custom Nix packages baked into the agent image at build
# time (see docs/superpowers/specs/2026-07-17-devbox-support-design.md).

# Prints the Dockerfile block that installs devbox, installs the packages
# from devbox.json into image layers, and hooks them into every shell.
devbox_dockerfile_block() {
	cat <<'EOF'
USER root
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

# Seed the devbox *global* config from the project's devbox.json.
# devbox.loc[k] is the optional-file COPY idiom: it picks up a committed
# devbox.lock (reproducible package versions) without failing when absent.
COPY --chown=vscode:vscode devbox.json devbox.loc[k] /home/vscode/.local/share/devbox/global/default/
# Install all packages from devbox.json into image layers, so nothing
# downloads at container start. Sourcing nix.sh puts nix on PATH for
# this RUN layer (ENV alone isn't enough — devbox also needs
# NIX_PROFILES / NIX_SSL_CERT_FILE set by nix.sh).
RUN . /home/vscode/.nix-profile/etc/profile.d/nix.sh \
    && devbox global install

USER root
# Hook packages into every shell via the sandcat profile.d sourcing
# machinery (app-init.sh sources /etc/profile.d/sandcat-*.sh into login
# shells and /etc/bash.bashrc). Source nix.sh first so `devbox` and
# the packages it manages resolve.
RUN printf '%s\n' \
    '. /home/vscode/.nix-profile/etc/profile.d/nix.sh 2>/dev/null || true' \
    'if command -v devbox >/dev/null 2>&1; then' \
    '    eval "$(devbox global shellenv 2>/dev/null)" || true' \
    'fi' > /etc/profile.d/sandcat-devbox.sh
USER vscode
EOF
}

# Applies devbox to a generated devcontainer directory: copies the starter
# devbox.json (unless one already exists, so re-init keeps user edits) and
# expands the __DEVBOX_INSTALL__ placeholder in Dockerfile.app.
# Args:
#   $1 - Path to devcontainer directory
customize_devbox() {
	local devcontainer_dir=$1

	if [[ ! -f "$devcontainer_dir/devbox.json" ]]; then
		cp "$SCT_TEMPLATEDIR/devbox.json" "$devcontainer_dir/devbox.json"
	fi

	local block
	block=$(devbox_dockerfile_block)
	apply_template_placeholders "$devcontainer_dir/Dockerfile.app" \
		"__DEVBOX_INSTALL__" "$block"
}
