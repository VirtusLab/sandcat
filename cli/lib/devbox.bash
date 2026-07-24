#!/usr/bin/env bash
# Devbox feature: Nix packages baked into the agent image at build time.
#
# Two-file model:
#   * devbox.stack.json  — sandcat-managed. Regenerated on every `sandcat init`
#     from the `--stacks` selection plus a baseline of shell tools that every
#     sandbox needs (fd, fzf, gh, jq, ripgrep, tmux, vim).
#   * devbox.tools.json  — user-managed. Written once with an empty package
#     list; subsequent `sandcat init` invocations leave it untouched so the
#     user's additions survive template regeneration.
#
# The two files are merged into a single devbox global config at Docker build
# time via jq. Version conflicts on the same package name across the two files
# fail the build.
#
# shellcheck source=devcontainer.bash
# (apply_template_placeholders lives there — devcontainer.bash sources this
# file after itself, so we rely on the function being available at call time.)

# Baseline shell tools installed in every sandbox regardless of --stacks.
# Kept here (not in a separate template file) so the list is easy to review
# next to the rest of the devbox machinery.
SCT_DEVBOX_BASELINE_PACKAGES=(
	"fd@latest"       # fast file finder
	"fzf@latest"      # fuzzy finder for files and command history
	"gh@latest"       # GitHub CLI
	"jq@latest"       # JSON processor
	"ripgrep@latest"  # fast recursive grep (rg)
	"tmux@latest"     # terminal multiplexer
	"vim@latest"      # text editor
)

# Writes .devcontainer/devbox.stack.json from the baseline plus per-stack
# packages contributed by stack_devbox_packages(). Regenerated every init —
# no guard against overwrite.
#
# Args:
#   $1     - Output path for devbox.stack.json
#   $2..$N - Resolved stack names (dependencies already expanded)
write_devbox_stack_json() {
	local out=$1
	shift

	local -a all=("${SCT_DEVBOX_BASELINE_PACKAGES[@]}")
	local stack pkg_list pkg
	for stack in "$@"; do
		pkg_list=$(stack_devbox_packages "$stack")
		# shellcheck disable=SC2086
		for pkg in $pkg_list; do
			all+=("$pkg")
		done
	done

	# Emit compact JSON, then pretty-print via jq for readability. jq is
	# available on hosts that already run sandcat init (a hard require).
	local json="{\"packages\":["
	local first=true
	for pkg in "${all[@]}"; do
		if [[ $first == true ]]; then
			first=false
		else
			json+=","
		fi
		json+="\"$pkg\""
	done
	json+="]}"
	echo "$json" | jq . > "$out"
}

# Writes .devcontainer/devbox.tools.json ONLY if it does not already exist,
# so user edits survive re-init.
#
# Args:
#   $1 - Output path for devbox.tools.json
write_devbox_tools_json() {
	local out=$1
	if [[ -f "$out" ]]; then
		return 0
	fi
	cat > "$out" <<'EOF'
{
  "//": "User-managed devbox packages. Add extras here — sandcat init does not overwrite this file. Merged with devbox.stack.json at image build time; version conflicts on the same package name fail the build.",
  "packages": []
}
EOF
}

# jq program that merges two devbox configs into one, failing on version
# conflicts for the same package name. Used by the Dockerfile build step.
# Emitted as a SINGLE LINE so it can be embedded directly inside a `RUN`
# command — Docker parses each backslash-continued line as an instruction,
# so a multi-line jq program would confuse the parser.
_devbox_merge_jq() {
	printf '%s' 'def pkgname: split("@")[0]; def combined: (.[0].packages // []) + (.[1].packages // []); def conflicts: combined | group_by(pkgname) | map(select((. | unique | length) > 1)); if (conflicts | length) > 0 then "devbox: version conflict between devbox.stack.json and devbox.tools.json for: " + (conflicts | map(.[0] | pkgname) | join(", ")) + " (found: " + (conflicts | tostring) + ")\n" | halt_error(1) else {packages: (combined | unique)} end'
}

# Prints the Dockerfile block that installs devbox, merges the two devbox
# configs into the global profile, installs all resolved packages into image
# layers, and hooks them into every shell via /etc/profile.d.
devbox_dockerfile_block() {
	local merge_jq
	merge_jq=$(_devbox_merge_jq)

	# The merge jq program is embedded verbatim between single-quoted RUN
	# arguments; jq's own quoting stays intact because Docker's shell parser
	# passes it through unchanged.
	cat <<EOF
USER root
# Prep /nix owned by vscode. Single-user Nix (which we need — see below)
# requires a user-writable /nix.
RUN mkdir -m 0755 /nix && chown vscode /nix
# Install devbox launcher. The installer writes /usr/local/bin/devbox as
# mode 711 (root:root, no read bit for others). It's a bash launcher, not
# a native binary, so bash can't read the shebang as non-root and exec
# fails with EACCES. Force 0755 so vscode can execute it.
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f \\
    && chmod 0755 /usr/local/bin/devbox

USER vscode
# Preinstall Nix in single-user mode BEFORE devbox gets a chance.
# \`devbox global install\` on a fresh system triggers Determinate's
# \`nix-installer\`, which defaults to multi-user (systemd-managed daemon)
# whenever sudo is available. Containers based on debian have sudo but
# no systemd, so the daemon never starts, and later \`nix\` commands fail
# with "cannot connect to socket at /nix/var/nix/daemon-socket/socket"
# and "opening lock file /nix/var/nix/db/big-lock: Permission denied".
# The classic nixos.org installer with --no-daemon reliably yields a
# single-user install that works under vscode's UID.
RUN curl -fsSL -L https://nixos.org/nix/install \\
    | sh -s -- --no-daemon --no-modify-profile --yes
ENV PATH="/home/vscode/.nix-profile/bin:\${PATH}"

# Split into two layers so the common case (user drops a tool into
# devbox.tools.json) doesn't invalidate the expensive stack install.
#
# Layer A — stack packages only. Cached whenever devbox.stack.json is
# unchanged. This is the ~11-minute step on a cold build; keeping it
# out of the same COPY as devbox.tools.json lets a tools-only edit
# skip it entirely.
COPY --chown=vscode:vscode devbox.stack.json /home/vscode/.local/share/devbox/global/default/devbox.json
RUN --mount=type=cache,target=/home/vscode/.cache/nix,uid=1000,gid=1000 \\
    . /home/vscode/.nix-profile/etc/profile.d/nix.sh \\
 && devbox global install

# Layer B — merge stack + user tools, install the delta. /nix/store from
# Layer A carries over via the image filesystem, so devbox here only
# downloads what's new in the merged config (usually just user additions).
# The jq program halts the build on version conflicts across the two files.
# devbox.loc[k] is the optional-file COPY idiom: picks up a committed
# devbox.lock without failing when absent.
COPY --chown=vscode:vscode devbox.stack.json devbox.tools.json /tmp/
COPY --chown=vscode:vscode devbox.loc[k] /home/vscode/.local/share/devbox/global/default/
RUN --mount=type=cache,target=/home/vscode/.cache/nix,uid=1000,gid=1000 \\
    jq -s '${merge_jq}' /tmp/devbox.stack.json /tmp/devbox.tools.json \\
    > /home/vscode/.local/share/devbox/global/default/devbox.json \\
 && . /home/vscode/.nix-profile/etc/profile.d/nix.sh \\
 && devbox global install \\
 && rm /tmp/devbox.stack.json /tmp/devbox.tools.json

# BuildKit --mount=type=cache above persists ~/.cache/nix (Nix's HTTP
# cache for .nar downloads) between builds on the same host. First cold
# build is unchanged (empty cache); subsequent stack changes reuse
# already-downloaded .nar files. Not portable to CI without a persistent
# cache action; harmless if absent (the RUN just downloads fresh).

USER root
# Hook packages into every shell via the sandcat profile.d sourcing
# machinery (app-init.sh sources /etc/profile.d/sandcat-*.sh into login
# shells and /etc/bash.bashrc). Source nix.sh first so \`devbox\` and
# the packages it manages resolve.
RUN printf '%s\\n' \\
    '. /home/vscode/.nix-profile/etc/profile.d/nix.sh 2>/dev/null || true' \\
    'if command -v devbox >/dev/null 2>&1; then' \\
    '    eval "\$(devbox global shellenv 2>/dev/null)" || true' \\
    'fi' > /etc/profile.d/sandcat-devbox.sh
USER vscode
EOF
}

# Applies devbox to a generated devcontainer directory:
#   * regenerates devbox.stack.json from resolved stacks + baseline;
#   * writes devbox.tools.json only if missing (guarded across init);
#   * expands __DEVBOX_INSTALL__ in Dockerfile.app.
#
# Args:
#   $1     - Path to devcontainer directory
#   $2..$N - Resolved stack names (empty is fine)
customize_devbox() {
	local devcontainer_dir=$1
	shift

	write_devbox_stack_json "$devcontainer_dir/devbox.stack.json" "$@"
	write_devbox_tools_json "$devcontainer_dir/devbox.tools.json"

	local block
	block=$(devbox_dockerfile_block)
	apply_template_placeholders "$devcontainer_dir/Dockerfile.app" \
		"__DEVBOX_INSTALL__" "$block"
}
