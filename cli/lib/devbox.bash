#!/usr/bin/env bash
# Devbox feature: custom Nix packages baked into the agent image at build
# time (see docs/superpowers/specs/2026-07-17-devbox-support-design.md).

# Prints the Dockerfile block that installs devbox, installs the packages
# from devbox.json into image layers, and hooks them into every shell.
devbox_dockerfile_block() {
	cat <<'EOF'
USER root
# Install devbox and prepare a single-user Nix store owned by vscode.
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f \
    && mkdir -m 0755 /nix && chown vscode /nix
# Seed the devbox *global* config from the project's devbox.json.
# devbox.loc[k] is the optional-file COPY idiom: it picks up a committed
# devbox.lock (reproducible package versions) without failing when absent.
COPY --chown=vscode:vscode devbox.json devbox.loc[k] /home/vscode/.local/share/devbox/global/default/
USER vscode
# First run auto-installs single-user Nix into /nix, then installs all
# packages from devbox.json. Everything is baked into image layers, so
# nothing downloads at container start.
RUN devbox global install
USER root
# Hook packages into every shell via the sandcat profile.d sourcing
# machinery (app-init.sh sources /etc/profile.d/sandcat-*.sh into login
# shells and /etc/bash.bashrc).
RUN printf '%s\n' \
    'if command -v devbox >/dev/null 2>&1; then' \
    '    eval "$(devbox global shellenv 2>/dev/null)" || true' \
    'fi' > /etc/profile.d/sandcat-devbox.sh
USER vscode
EOF
}

# Applies the devbox feature to a generated devcontainer directory.
# When enabled: copies the starter devbox.json (unless one already exists,
# so re-init keeps user edits) and expands the __DEVBOX_INSTALL__
# placeholder in Dockerfile.app. When disabled: drops the placeholder line.
# Args:
#   $1 - Path to devcontainer directory
#   $2 - "true" to enable, anything else disables
customize_devbox() {
	local devcontainer_dir=$1
	local enabled=$2

	local block=""
	if [[ "$enabled" == "true" ]]; then
		if [[ ! -f "$devcontainer_dir/devbox.json" ]]; then
			cp "$SCT_TEMPLATEDIR/devbox.json" "$devcontainer_dir/devbox.json"
		fi
		block=$(devbox_dockerfile_block)
	fi

	apply_template_placeholders "$devcontainer_dir/Dockerfile.app" \
		"__DEVBOX_INSTALL__" "$block"
}
