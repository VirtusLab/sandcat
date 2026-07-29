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
# time via jq. Same-name entries (matching pkgname before '@') in
# devbox.tools.json override the stack default. Cross-family collisions where
# both files ship packages that provide the same file (e.g. `openjdk17` vs
# `temurin-bin-25` both providing bin/java) are resolved by re-adding the
# tools entries to the Nix profile with a higher priority — Nix then picks
# the tools package when materializing bin/java, JAVA_HOME, etc.
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
  "//": "User-managed devbox packages. Add extras here — sandcat init does not overwrite this file. Merged with devbox.stack.json at image build time; entries here override same-named packages from the stack, and win cross-family collisions via a Nix priority bump (e.g. put openjdk17@latest here to replace the stack's temurin-bin-25 as the active Java).",
  "packages": []
}
EOF
}

# jq program that merges two devbox configs into one. When both files
# list a package with the same name (part before '@'), the entry from
# devbox.tools.json wins — that's the primary way to override a stack
# default (e.g. `nodejs@22.5.1` in tools replaces stack's `nodejs@lts`).
#
# For cross-family collisions (e.g. tools ships `openjdk17@latest` while
# stack ships `temurin-bin-25@latest`, both providing bin/java), the merge
# keeps both packages — the Dockerfile then bumps the Nix priority of
# tools entries so they win the file collision at profile-materialization
# time. See devbox_dockerfile_block() for the priority bump step.
#
# Emitted as a SINGLE LINE so it can be embedded directly inside a `RUN`
# command — Docker parses each backslash-continued line as an instruction,
# so a multi-line jq program would confuse the parser.
_devbox_merge_jq() {
	printf '%s' 'def pkgname: split("@")[0]; (.[1].packages // []) as $tools | ($tools | map(pkgname)) as $tnames | {packages: (((.[0].packages // []) | map(select(pkgname as $n | $tnames | index($n) | not))) + $tools | unique)}'
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

# Layer B — merge stack + user tools, install the delta, and bump the
# Nix priority of tools entries so they win file collisions against stack
# entries (e.g. tools' openjdk17 wins over stack's temurin-bin-25 for
# bin/java). /nix/store from Layer A carries over via the image filesystem,
# so devbox here only downloads what's new in the merged config.
#
# Tools override behavior:
#   * Same package name (jq): the merge drops stack's entry; tools' entry
#     is the only one devbox installs. No priority bump needed.
#   * Cross-family collision (openjdk17 vs temurin-bin-25): merge keeps
#     both; devbox installs both; then we snapshot which manifest entries
#     appeared in this layer (tools additions) and re-add each of their
#     store paths with --priority 3. Nix priority-based collision then
#     picks the priority-3 entry, and the sandcat Java block resolves
#     JAVA_HOME through bin/java to the tools JDK.
#
# devbox.loc[k] is the optional-file COPY idiom: picks up a committed
# devbox.lock without failing when absent.
COPY --chown=vscode:vscode devbox.stack.json devbox.tools.json /tmp/
COPY --chown=vscode:vscode devbox.loc[k] /home/vscode/.local/share/devbox/global/default/
RUN --mount=type=cache,target=/home/vscode/.cache/nix,uid=1000,gid=1000 \\
    NIX_PROFILE=\$HOME/.local/share/devbox/global/default/.devbox/nix/profile/default \\
 && jq -r '[.. | .storePaths? // empty] | flatten | .[]' \$NIX_PROFILE/manifest.json \\
    | sort -u > /tmp/paths.before.txt \\
 && jq -s '${merge_jq}' /tmp/devbox.stack.json /tmp/devbox.tools.json \\
    > /home/vscode/.local/share/devbox/global/default/devbox.json \\
 && . /home/vscode/.nix-profile/etc/profile.d/nix.sh \\
 && devbox global install \\
 && jq -r '[.. | .storePaths? // empty] | flatten | .[]' \$NIX_PROFILE/manifest.json \\
    | sort -u > /tmp/paths.after.txt \\
 && comm -23 /tmp/paths.after.txt /tmp/paths.before.txt > /tmp/tools-paths.txt \\
 && while IFS= read -r storepath; do \\
      [ -n "\$storepath" ] || continue; \\
      nix --extra-experimental-features "nix-command flakes" \\
          profile add --priority 3 --profile \$NIX_PROFILE "\$storepath"; \\
    done < /tmp/tools-paths.txt \\
 && rm /tmp/devbox.stack.json /tmp/devbox.tools.json /tmp/paths.before.txt /tmp/paths.after.txt /tmp/tools-paths.txt

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
