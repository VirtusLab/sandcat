#!/usr/bin/env bash

# shellcheck source=require.bash
source "$SCT_LIBDIR/require.bash"
# shellcheck source=path.bash
source "$SCT_LIBDIR/path.bash"
# shellcheck source=constants.bash
source "$SCT_LIBDIR/constants.bash"
# shellcheck source=agents.bash
source "$SCT_LIBDIR/agents.bash"

# Customizes a Docker Compose file with settings and optional user configurations.
# Optional volumes are added as commented-out entries by default. Set environment
# variables to "true" before calling this function to add them as active mounts:
#   - SANDCAT_MOUNT_CLAUDE_CONFIG: "true" to mount host Claude config (~/.claude)
#   - SANDCAT_MOUNT_CODEX_CONFIG: "true" to mount host Codex config (~/.codex)
#   - SANDCAT_MOUNT_COPILOT_CONFIG: "true" to mount host Copilot config (~/.copilot/mcp-config.json
#     and ~/.copilot/session-state/)
#   - SANDCAT_MOUNT_CURSOR_CONFIG: "true" to mount host Cursor config (~/.cursor
#     customization read-only; workspace-scoped projects/<id>/ read-write;
#     mcp.json read-only). chats/, plugins/, and subagents/ stay in agent-home
#     so other workspaces' runtime state is not exposed. cli-config.json is
#     driven by cursor.cli in Sandcat settings (not host-mounted).
#   - SANDCAT_MOUNT_GIT_READONLY: "true" to mount .git directory as read-only
#   - SANDCAT_MOUNT_IDEA_READONLY: "true" to mount .idea directory as read-only
#   - SANDCAT_MOUNT_SHARED_CACHE: "true" (default) to mount shared JVM
#     dependency-cache volumes (Maven, Coursier, Gradle, Ivy, sbt).
#     Set to "false" to keep caches per-project inside agent-home.
# Args:
#   $1 - Path to the settings file to mount, relative to the Docker Compose file directory
#   $2 - Path to the Docker Compose file to modify
#   $3 - The agent name (e.g., "claude")
#   $4 - The IDE name (e.g., "vscode", "jetbrains", "none") (optional)
#   $5 - The project name (used to construct workspace paths) (required)
#   $6 - Space-separated resolved stack names (used to pick shared caches;
#        empty is fine — no caches added)
#
customize_compose_file() {
	local settings_file=$1
	local compose_file=$2
	local agent=$3
	local ide=${4:-none}
	local project_name=$5
	local stacks=${6:-}

	require yq

	local compose_dir
	compose_dir=$(dirname "$compose_file")

	verify_relative_path "$compose_dir" "$settings_file"

	if [[ $ide == "jetbrains" ]]
	then
		: "${SANDCAT_MOUNT_IDEA_READONLY:=true}"
	fi

	# Agent is declared by the included sandcat/compose-agent.yml. Declaring
	# it again in compose-all.yml makes Compose reject the project
	# ("conflicts with imported resource") — include copies resources into
	# the model, it never merges them (same rule as mitmproxy below). Write
	# user-facing agent mounts into the included file and re-base relative
	# paths one level deeper (sandcat/ → project root needs ../..).
	local agent_compose="$compose_dir/sandcat/compose-agent.yml"
	local agent_target="$compose_file"
	local project_rel=".."
	if [[ -f "$agent_compose" ]]
	then
		agent_target="$agent_compose"
		project_rel="../.."
	fi

	set_workspace "$agent_target" "$project_name" "$project_rel"

	# mitmproxy is declared by the included sandcat/compose-proxy.yml, so the
	# mount has to go there. Declaring the service here as well makes Compose
	# reject the project ("conflicts with imported resource") — include copies
	# resources into the model, it never merges them. The extra ".." re-bases
	# the path on the included file's own directory, which is how Compose
	# resolves relative paths inside it.
	local proxy_compose="$compose_dir/sandcat/compose-proxy.yml"
	if [[ -f "$proxy_compose" ]]
	then
		add_settings_volume "$proxy_compose" "../$settings_file"
	fi

	case "$agent" in
		claude)
			add_claude_config_volumes "$agent_target" "${SANDCAT_MOUNT_CLAUDE_CONFIG:=true}"
			;;
		codex)
			add_codex_config_volumes "$agent_target" "${SANDCAT_MOUNT_CODEX_CONFIG:=true}"
			;;
		copilot)
			add_copilot_config_volumes "$agent_target" "${SANDCAT_MOUNT_COPILOT_CONFIG:=true}"
			;;
		cursor)
			add_cursor_config_volumes "$agent_target" "${SANDCAT_MOUNT_CURSOR_CONFIG:=true}" "$project_name"
			;;
	esac

	add_git_readonly_volume "$agent_target" "${SANDCAT_MOUNT_GIT_READONLY:=false}" "$project_rel"
	add_idea_readonly_volume "$agent_target" "${SANDCAT_MOUNT_IDEA_READONLY:-false}" "$project_rel"

	local -a stacks_arr=()
	if [[ -n "$stacks" ]]; then
		read -ra stacks_arr <<< "$stacks"
	fi
	add_shared_cache_volumes "$agent_target" "${SANDCAT_MOUNT_SHARED_CACHE:=true}" "${stacks_arr[@]+"${stacks_arr[@]}"}"

	if [[ $ide == "jetbrains" ]]
	then
		add_jetbrains_capabilities "$agent_target"
	fi

	strip_entry_blank_lines "$agent_target"
	if [[ -f "$proxy_compose" ]]
	then
		strip_entry_blank_lines "$proxy_compose"
	fi
}

# Removes blank lines between volume entries/comments.
# yq inserts blank lines between foot comments and the next sibling.
# When a blank line is followed by an indented line, strip the blank line
# via substitution to keep the indented line intact.
# Args:
#   $1 - Path to the Docker Compose file
strip_entry_blank_lines() {
	local compose_file=$1

	sed '/^$/{ N; /^\n[[:space:]]/{ s/^\n//; }; }' "$compose_file" > "$compose_file.tmp" && mv "$compose_file.tmp" "$compose_file"
}

# Configures the mitmproxy image and secret-backend environment for compose-proxy.yml.
#
# Environment entries are appended (idempotent), never assigned as a fresh array —
# otherwise a later call would wipe NetBird passthrough vars such as NB_SETUP_KEY
# that enable_netbird() injects for the Dockerfile.mitmproxy variant.
#
# When mitmproxy already builds from Dockerfile.mitmproxy, the stock/op/pass
# image pin is skipped so NetBird enrollment keeps its custom entrypoint.
#
# Args:
#   $1 - Path to the compose-proxy.yml file
#   $2 - Secret provider: none | 1password | protonpass
apply_secret_provider() {
	require yq
	local compose_file=$1
	local provider=${2:-none}
	local token_env=""
	local provider_image=""

	case "$provider" in
	none)
		return 0
		;;
	1password)
		token_env="OP_SERVICE_ACCOUNT_TOKEN"
		provider_image="ghcr.io/virtuslab/sandcat-mitmproxy-op:${SCT_MITMPROXY_VERSION}"
		;;
	protonpass)
		token_env="PROTON_PASS_PERSONAL_ACCESS_TOKEN"
		provider_image="ghcr.io/virtuslab/sandcat-mitmproxy-pass:${SCT_MITMPROXY_VERSION}"
		;;
	*)
		echo "Unknown secret provider: $provider" >&2
		return 1
		;;
	esac

	local dockerfile
	dockerfile=$(yq -r '.services.mitmproxy.build.dockerfile // ""' "$compose_file")
	if [[ "$dockerfile" == "Dockerfile.mitmproxy" ]]; then
		# NetBird already replaced image: with a build. Pinning image: here would
		# be ignored by compose and the provider CLI would be missing from the
		# built image, so pass the provider variant in as the build base instead.
		provider_image="$provider_image" yq -i '
			.services.mitmproxy.build.args.BASE_IMAGE = env(provider_image)
		' "$compose_file"
	else
		provider_image="$provider_image" yq -i '
			.services.mitmproxy.image = env(provider_image)
		' "$compose_file"
	fi

	local has_token
	has_token=$(yq "[(.services.mitmproxy.environment // [])[] | select(. == \"$token_env\")] | length" "$compose_file")
	if [[ "$has_token" -eq 0 ]]; then
		token_env="$token_env" yq -i '
			.services.mitmproxy.environment = ((.services.mitmproxy.environment // []) + [env(token_env)])
		' "$compose_file"
	fi
}
# Switches the mitmproxy service from web UI to console (mitmdump) mode.
# Replaces the mitmweb command with mitmdump, strips mitmweb-only flags
# (--web-host and --set web_password), and removes the web UI port.
# mitmdump logs flows as text to stdout, viewable via docker compose logs.
# Args:
#   $1 - Path to the compose-proxy.yml file
set_proxy_tui_mode() {
	require yq
	local compose_file=$1

	yq -i '
		.services.mitmproxy.command |= (
			sub("^mitmweb\\b", "mitmdump") |
			sub("\\s+--web-host\\s+\\S+", "") |
			sub("\\s+--set\\s+web_password=\\S+", "")
		) |
		del(.services.mitmproxy.ports)
	' "$compose_file"
}

# Sets the project name in a Docker Compose file.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - Project name
set_project_name() {
	require yq
	local compose_file=$1
	local project_name=$2

	project_name="$project_name" yq -i '. = {"name": env(project_name)} * .' "$compose_file"
}

# Adds settings volume mount to the proxy service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - Path to the settings file (relative to compose file)
add_settings_volume() {
	require yq
	local compose_file=$1
	local settings_file=$2

	local settings_dir
	settings_dir=$(dirname "$settings_file")

	settings_dir="$settings_dir" yq -i \
		'.services.mitmproxy.volumes += [env(settings_dir) + ":/config/project:ro"]' "$compose_file"

	add_foot_comment "$compose_file" ".services.mitmproxy.volumes" \
		'Project-level settings (.sandcat/ directory). If the directory does
not exist on the host, Docker creates an empty one and the addon
simply finds no files — no error.'
}

# Adds a foot comment to the last item in a YAML array.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - YAML path to the array (e.g., ".services.agent.volumes")
#   $3 - Comment text to add
add_foot_comment() {
	require yq
	local compose_file=$1
	local array_path=$2
	local comment=$3

	local item_count
	item_count=$(yq "$array_path | length" "$compose_file")

	if [[ $item_count -eq 0 ]]
	then
		echo "${FUNCNAME[0]}: Cannot add foot comment to empty array at $array_path" >&2
		return 1
	fi

	array_path="$array_path" comment="$comment" yq -i '
			(eval(env(array_path)) | .[-1]) foot_comment = (
				((eval(env(array_path)) | .[-1] | foot_comment) // "") + "\n" + strenv(comment) | sub("^\n", "")
			)' "$compose_file"
}

# Adds a foot comment to the last volume entry in the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - Comment text to add
add_volume_foot_comment() {
	local compose_file=$1
	local comment=$2

	add_foot_comment "$compose_file" ".services.agent.volumes" "$comment"
}

# Adds one or more agent volume entries in a single yq -i.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active entries, false to add as foot comments
#   $3.. - Repeating (volume_entry, comment) pairs. Comment may be empty.
add_volume_entries() {
	require yq
	local compose_file=$1
	local active=$2
	shift 2

	[[ $# -gt 0 ]] || return 0

	local -a entries=() comments=()
	while [[ $# -gt 0 ]]; do
		entries+=("$1")
		shift
		if [[ $# -gt 0 ]]; then
			comments+=("$1")
			shift
		else
			comments+=("")
		fi
	done

	if [[ $active != "true" ]]; then
		local foot="" i
		for i in "${!entries[@]}"; do
			if [[ -n "${comments[$i]}" ]]; then
				foot+="${comments[$i]}"$'\n'"- ${entries[$i]}"$'\n'
			else
				foot+="- ${entries[$i]}"$'\n'
			fi
		done
		add_volume_foot_comment "$compose_file" "${foot%$'\n'}"
		return
	fi

	local n=${#entries[@]}
	local expr='.services.agent.volumes += ['
	local i varname from_end
	for i in "${!entries[@]}"; do
		varname="SCT_VOL_${i}"
		export "$varname=${entries[$i]}"
		expr+="env(${varname}),"
	done
	expr="${expr%,}]"
	for i in "${!entries[@]}"; do
		[[ -n "${comments[$i]}" ]] || continue
		varname="SCT_VOLC_${i}"
		export "$varname=${comments[$i]}"
		from_end=$((n - i))
		expr+=" | (.services.agent.volumes | .[-${from_end}]) head_comment = strenv(${varname})"
	done
	yq -i "$expr" "$compose_file"
	for i in "${!entries[@]}"; do
		unset -v "SCT_VOL_${i}" "SCT_VOLC_${i}"
	done
}

# Adds a volume entry to the agent service, either as active or commented.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - Volume entry (e.g., "../.git:/workspace/.git:ro")
#   $3 - true to add as active entry, false to add as comment
#   $4 - Optional description comment
add_volume_entry() {
	local compose_file=$1
	local volume_entry=$2
	local active=$3
	local comment=${4:-}

	add_volume_entries "$compose_file" "$active" "$volume_entry" "$comment"
}

# Adds Claude config volume mounts to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_claude_config_volumes() {
	local compose_file=$1
	local active=${2:-true}

	# shellcheck disable=SC2016
	add_volume_entries "$compose_file" "$active" \
		'${HOME}/.claude/CLAUDE.md:/home/vscode/.claude/CLAUDE.md:ro' 'Host Claude config (optional)' \
		'${HOME}/.claude/agents:/home/vscode/.claude/agents:ro' '' \
		'${HOME}/.claude/commands:/home/vscode/.claude/commands:ro' ''
}

# Adds Codex config volume mounts to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_codex_config_volumes() {
	local compose_file=$1
	local active=${2:-true}

	# shellcheck disable=SC2016
	add_volume_entries "$compose_file" "$active" \
		'${HOME}/.codex/AGENTS.md:/home/vscode/.codex-host/AGENTS.md:ro' 'Host Codex config (optional) — copied into writable ~/.codex/AGENTS.md by app-user-init.sh so rtk can patch it' \
		'${HOME}/.codex/skills:/home/vscode/.codex/skills:ro' '' \
		'${HOME}/.codex/commands:/home/vscode/.codex/commands:ro' ''
}

# Adds Copilot config volume mounts to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_copilot_config_volumes() {
	local compose_file=$1
	local active=${2:-true}

	# session-state is read-write: Copilot CLI persists chat session events
	# there (events.jsonl per session UUID). Read-only mount fails with
	# EROFS on every prompt. Same trust posture as other host-mounted agent
	# data — user chose to bind-mount, we honor read+write.
	# shellcheck disable=SC2016
	add_volume_entries "$compose_file" "$active" \
		'${HOME}/.copilot/mcp-config.json:/home/vscode/.copilot/mcp-config.json:ro' 'Host Copilot MCP config (optional)' \
		'${HOME}/.copilot/session-state:/home/vscode/.copilot/session-state:rw' ''
}

# Adds Cursor config volume mounts to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
#   $3 - Sandcat project name (scopes projects/ to this workspace only)
add_cursor_config_volumes() {
	local compose_file=$1
	local active=$2
	local project_name=$3
	local project_id
	project_id=$(sct_cursor_workspace_project_id "$project_name")

	# Workspace-scoped runtime state — only this sandcat project's Cursor
	# projects/<id>/ tree is mounted (agent transcripts, terminals, etc.).
	# chats/, plugins/, and subagents/ remain in agent-home to avoid leaking
	# other workspaces' data from the host profile.
	# shellcheck disable=SC2016
	add_volume_entries "$compose_file" "$active" \
		'${HOME}/.cursor/AGENTS.md:/home/vscode/.cursor/AGENTS.md:ro' 'Host Cursor config (optional)' \
		'${HOME}/.cursor/rules:/home/vscode/.cursor/rules:ro' '' \
		'${HOME}/.cursor/skills:/home/vscode/.cursor/skills:ro' '' \
		'${HOME}/.cursor/commands:/home/vscode/.cursor/commands:ro' '' \
		'${HOME}/.cursor/hooks.json:/home/vscode/.cursor/hooks.json:ro' '' \
		'${HOME}/.cursor/hooks:/home/vscode/.cursor/hooks:ro' '' \
		'${HOME}/.cursor/agents:/home/vscode/.cursor/agents:ro' '' \
		'${HOME}/.cursor/mcp.json:/home/vscode/.cursor/mcp.json:ro' '' \
		"\${HOME}/.cursor/projects/${project_id}:/home/vscode/.cursor/projects/${project_id}" ''
}


# Adds .git directory mount as read-only to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
#   $3 - Relative path from that compose file to the project root (default: ..)
add_git_readonly_volume() {
	local compose_file=$1
	local active=${2:-true}
	local project_rel=${3:-..}

	add_volume_entry "$compose_file" "${project_rel}/.git:/workspace/.git:ro" "$active" 'Read-only Git directory'
}

# Adds .idea directory mount as read-only to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
#   $3 - Relative path from that compose file to the project root (default: ..)
add_idea_readonly_volume() {
	local compose_file=$1
	local active=${2:-true}
	local project_rel=${3:-..}

	add_volume_entry "$compose_file" "${project_rel}/.idea:/workspace/.idea:ro" "$active" 'Read-only IntelliJ IDEA project directory'
}

# Adds shared-cache mount entries + top-level external volume declarations
# for the caches contributed by the selected stacks. Each stack decides
# which caches it wants via stack_shared_cache_volumes() (see stacks.bash);
# a project with no matching stack gets no shared-cache mounts at all.
#
# Volumes carry dependency caches that persist across all sandcat sandboxes
# on the host, so multiple projects don't re-download the same JARs. They
# are declared `external: true` so `sandcat compose down -v` on one project
# doesn't wipe caches other projects rely on. The `sandcat run` wrapper
# creates them lazily (idempotent) so users don't have to pre-create them.
#
# When active=false, matching mount lines are added as comments (matches
# the existing pattern for optional mounts) so the user can uncomment or
# re-enable later, and no external volumes are declared.
#
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add active mounts, false to add commented entries
#   $3..$N - Resolved stack names (dependencies already expanded)
add_shared_cache_volumes() {
	require yq
	# shellcheck source=stacks.bash
	source "$SCT_LIBDIR/stacks.bash"

	local compose_file=$1
	local active=${2:-true}
	shift 2

	# Collect unique cache entries contributed by any selected stack.
	# Stacks like scala pull java in via stack_deps, so their caches
	# arrive here through the resolved list — no need to walk deps again.
	local -a entries=()
	local stack line seen
	for stack in "$@"; do
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			seen=false
			for existing in "${entries[@]+"${entries[@]}"}"; do
				[[ "$existing" == "$line" ]] && seen=true && break
			done
			[[ "$seen" == "false" ]] && entries+=("$line")
		done < <(stack_shared_cache_volumes "$stack")
	done

	[[ ${#entries[@]} -eq 0 ]] && return 0

	local -a vol_args=()
	local entry name path first=true
	for entry in "${entries[@]}"; do
		name=${entry%%:*}
		path=${entry#*:}
		if [[ $first == true ]]; then
			first=false
			vol_args+=("$name:$path" 'Shared dependency caches for the selected stacks (SANDCAT_MOUNT_SHARED_CACHE=false to disable)')
		else
			vol_args+=("$name:$path" "")
		fi
	done
	add_volume_entries "$compose_file" "$active" "${vol_args[@]}"

	# Declare each cache as an external volume with a stable host-scoped
	# name so multiple compose projects reference the same physical volume.
	if [[ $active == "true" ]]; then
		local expr='.' i=0 varname
		for entry in "${entries[@]}"; do
			name=${entry%%:*}
			varname="SCT_CACHENAME_${i}"
			export "$varname=$name"
			expr+=" | .volumes[env(${varname})] = {\"external\": true, \"name\": env(${varname})}"
			i=$((i + 1))
		done
		yq -i "$expr" "$compose_file"
		i=0
		for entry in "${entries[@]}"; do
			unset -v "SCT_CACHENAME_${i}"
			i=$((i + 1))
		done
	fi
}

# Sets the working directory and adds workspace volume mounts for the agent service.
# Args:
#   $1 - Path to the Docker Compose file that declares services.agent
#   $2 - Project name (used to construct /workspaces/<project_name>)
#   $3 - Relative path from that compose file to the project root (default: ..)
set_workspace() {
	require yq
	local compose_file=$1
	local project_name=$2
	local project_rel=${3:-..}

	local workspace="/workspaces/$project_name"
	local vol_code="${project_rel}:${workspace}"
	local vol_dc="${project_rel}/.devcontainer:${workspace}/.devcontainer:ro"
	local vol_sandcat="\${SANDCAT_AGENT_SANDCAT:?}:${workspace}/.sandcat:ro"
	local c_code="Mount the project's code"
	local c_dc="Read-only devcontainer directory"
	local c_sandcat='Filtered settings copy (SANDCAT_AGENT_SANDCAT; never the live .sandcat)'

	project_name="$project_name" \
	vol_code="$vol_code" \
	vol_dc="$vol_dc" \
	vol_sandcat="$vol_sandcat" \
	c_code="$c_code" \
	c_dc="$c_dc" \
	c_sandcat="$c_sandcat" \
	yq -i '
		.services.agent.working_dir = "/workspaces/" + env(project_name) |
		.services.agent.volumes += [env(vol_code), env(vol_dc), env(vol_sandcat)] |
		(.services.agent.volumes | .[-3]) head_comment = strenv(c_code) |
		(.services.agent.volumes | .[-2]) head_comment = strenv(c_dc) |
		(.services.agent.volumes | .[-1]) head_comment = strenv(c_sandcat)
	' "$compose_file"
}

# Adds JetBrains-specific capabilities to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
add_jetbrains_capabilities() {
	require yq
	local compose_file=$1

	yq -i '
		.services.agent.cap_add += ["DAC_OVERRIDE", "CHOWN", "FOWNER"] |
		(.services.agent.cap_add[] | select(. == "DAC_OVERRIDE")) head_comment = "JetBrains IDE: bypass file permission checks on mounted volumes" |
		(.services.agent.cap_add[] | select(. == "CHOWN")) head_comment = "JetBrains IDE: change ownership of IDE cache and state files" |
		(.services.agent.cap_add[] | select(. == "FOWNER")) head_comment = "JetBrains IDE: bypass ownership checks on IDE-managed files"
	' "$compose_file"
}

# Reads the merged `upstream_ca_bundles` list from user settings
# (~/.config/sandcat/settings.json) and project settings.local.json,
# printing absolute paths one per line. Empty output if unconfigured.
# Args:
#   $1 - Project directory (contains .sandcat/settings.local.json if used)
read_upstream_ca_bundles() {
	require yq
	local project_dir=$1

	local user_settings="${HOME}/.config/sandcat/settings.json"
	local project_local="${project_dir}/.sandcat/settings.local.json"

	local out=""
	local f
	for f in "$user_settings" "$project_local"; do
		[[ -f "$f" ]] || continue
		# `(.upstream_ca_bundles // []) | .[]` yields one line per array entry
		# and empty output when the key is missing or the array is empty. yq's
		# stderr is discarded so a corrupted settings file (invalid JSON) is
		# treated as "nothing configured" rather than aborting init.
		local piece
		piece=$(yq -r '(.upstream_ca_bundles // []) | .[]' "$f" 2>/dev/null || true)
		[[ -n "$piece" ]] && out+="${piece}"$'\n'
	done
	# Strip trailing newline; leave inner newlines as separators.
	printf '%s' "${out%$'\n'}"
}

# Validates a single upstream CA bundle path. Prints an error to stderr and
# returns 1 on failure; returns 0 silently on success.
# Args:
#   $1 - Path to check
validate_upstream_ca_bundle() {
	local path=$1
	if [[ "$path" != /* ]]; then
		echo "upstream_ca_bundles: expected absolute path, got '$path'" >&2
		return 1
	fi
	if [[ ! -e "$path" ]]; then
		echo "upstream_ca_bundles: file not found: $path" >&2
		return 1
	fi
	if [[ ! -r "$path" ]]; then
		echo "upstream_ca_bundles: file not readable: $path" >&2
		return 1
	fi
	if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$path"; then
		echo "upstream_ca_bundles: no PEM certificate block in $path" >&2
		return 1
	fi
	return 0
}

# Adds the user's upstream CA bundles as read-only bind-mounts on the
# mitmproxy service and rewrites the entrypoint to install them into the
# container's system trust store before docker-entrypoint.sh drops
# privileges. No-op when no bundles are configured. Validates each path
# before touching the compose file — on any failure, the compose file is
# left unchanged.
# Args:
#   $1 - Path to compose-proxy.yml
#   $2 - Project directory
apply_upstream_ca_bundles() {
	require yq
	local compose_file=$1
	local project_dir=$2

	local bundles=()
	local line
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -n "$line" ]] || continue
		bundles+=("$line")
	done < <(read_upstream_ca_bundles "$project_dir")

	[[ ${#bundles[@]} -eq 0 ]] && return 0

	# Fail fast if any bundle is invalid — do not touch compose file.
	local b
	for b in "${bundles[@]}"; do
		validate_upstream_ca_bundle "$b" || return 1
	done

	# Build the list of new volume entries. Naming: NNN-<basename>.crt.
	local yq_array="" idx=0 host basename mount
	for b in "${bundles[@]}"; do
		host="$b"
		basename=$(basename "$host")
		basename="${basename%.*}"
		mount=$(printf '%s:/upstream-ca/%03d-%s.crt:ro' "$host" "$idx" "$basename")
		# JSON-string escape backslashes and quotes.
		local escaped="${mount//\\/\\\\}"
		escaped="${escaped//\"/\\\"}"
		yq_array+="\"${escaped}\","
		idx=$((idx + 1))
	done
	yq_array="[${yq_array%,}]"

	yq -i ".services.mitmproxy.volumes = ((.services.mitmproxy.volumes // []) + ${yq_array})" "$compose_file"

	# Prepend CA installation to whatever entrypoint the template already
	# defines, rather than substituting a fixed one. The template's
	# entrypoint also publishes the CA cert to the agent-facing
	# mitmproxy-public volume (#25), and the healthcheck gates on that file —
	# replacing it wholesale would stop the stack from ever becoming healthy.
	# Reading it back also means template changes don't silently regress here.
	#
	# Two separate installs are required because mitmproxy loads its trust
	# store from certifi (mitmproxy/net/tls.py calls certifi.where()), not
	# the OS store — so update-ca-certificates alone does not make mitmproxy
	# trust our CAs on the upstream leg. We append to certifi's bundle too.
	local existing_entrypoint
	existing_entrypoint=$(yq -r '.services.mitmproxy.entrypoint[2] // ""' "$compose_file")
	if [[ -z "$existing_entrypoint" ]]; then
		echo "upstream_ca_bundles: mitmproxy entrypoint not found in $compose_file" >&2
		return 1
	fi

	# `|| exit 1` rather than chaining with `&&`: the template's entrypoint
	# ends in `… & exec docker-entrypoint.sh`, and `&` binds looser than
	# `&&`, so an `&&` join would put the CA install inside the backgrounded
	# list and race mitmproxy's start. Running it as its own statement keeps
	# it synchronous, and the explicit exit keeps it fail-loud: a broken
	# mount halts the container instead of starting with unpatched trust.
	local ca_install='cp /upstream-ca/*.crt /usr/local/share/ca-certificates/ && update-ca-certificates >/dev/null && cat /upstream-ca/*.crt >> "$(python3 -c '"'"'import certifi; print(certifi.where())'"'"')"'
	local new_entrypoint="${ca_install} || exit 1; ${existing_entrypoint}"
	new_entrypoint="$new_entrypoint" yq -i \
		'.services.mitmproxy.entrypoint = ["/bin/sh", "-c", strenv(new_entrypoint), "sh"]' \
		"$compose_file"
}

# Injects NetBird version and per-arch checksum build args into a service's
# compose build section, sourced from netbird.env (sibling to the compose file).
# Args:
#   $1 - Path to compose file
#   $2 - Service name (default: wg-client)
apply_netbird_build_args() {
	require yq
	local compose_file=$1
	local service_name=${2:-wg-client}
	local netbird_env
	netbird_env="$(dirname "$compose_file")/netbird.env"

	if [[ ! -f "$netbird_env" ]]; then
		echo "netbird.env not found beside compose file: $netbird_env" >&2
		return 1
	fi

	# shellcheck disable=SC1090
	source "$netbird_env"

	: "${NETBIRD_VERSION:?NETBIRD_VERSION missing from $netbird_env}"
	: "${NETBIRD_SHA256_AMD64:?NETBIRD_SHA256_AMD64 missing from $netbird_env}"
	: "${NETBIRD_SHA256_ARM64:?NETBIRD_SHA256_ARM64 missing from $netbird_env}"

	yq -i "
		.services.\"${service_name}\".build.args.NETBIRD_VERSION = \"${NETBIRD_VERSION}\" |
		.services.\"${service_name}\".build.args.NETBIRD_SHA256_AMD64 = \"${NETBIRD_SHA256_AMD64}\" |
		.services.\"${service_name}\".build.args.NETBIRD_SHA256_ARM64 = \"${NETBIRD_SHA256_ARM64}\"
	" "$compose_file"
}

# Wires NetBird enrollment into the mitmproxy service in compose-proxy.yml.
# mitmproxy is the sole NetBird mesh participant in the agent stack; wg-client
# remains a pure tunnel shim (wg0 only). Traffic always flows:
#   agent → wg0 (wg-client) → mitmproxy L7 inspect → internet or wt0 mesh.
#
# When NetBird is enabled, this function:
#   1. Switches mitmproxy from the stock image to a build using Dockerfile.mitmproxy
#      (which installs the pinned NetBird binary and mitmproxy-init.sh entrypoint).
#   2. Removes the compose-level entrypoint override. mitmproxy-init.sh
#      restores master's CA publish, dns.conf clear, and docker-entrypoint.sh.
#   3. Adds cap_add: [NET_ADMIN] and the WireGuard src_valid_mark sysctl.
#   4. Adds NB_SETUP_KEY (and optionally NB_MANAGEMENT_URL) to the environment.
#   5. Injects NetBird build args (version + per-arch checksums) from netbird.env.
#   6. Adds extra_hosts host.docker.internal:172.17.0.1 so STUN hits docker0
#      (Colima host-gateway is the LAN IP; UDP hairpin fails). Do not set
#      server.stuns — that disables the embedded listener.
#
# Args:
#   $1 - Path to compose-proxy.yml
#   $2 - Optional NetBird management server URL
#   $3 - NetBird peer hostname for mitmproxy (required for project-scoped naming)
enable_netbird() {
	require yq
	# shellcheck source=netbird.bash
	source "$SCT_LIBDIR/netbird.bash"

	local compose_file=$1
	local netbird_management_url=${2:-}
	local peer_name=${3:-}
	local enrollment_url

	[[ -n "$peer_name" ]] || {
		echo "enable_netbird: peer name (\$3) is required (e.g. myapp-sandbox-proxy)" >&2
		return 1
	}

	mkdir -p "$(dirname "$compose_file")/scripts"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/netbird-peer-lifecycle.sh" \
		"$(dirname "$compose_file")/scripts/"

	# Switch mitmproxy from image: to build: using Dockerfile.mitmproxy.
	# Idempotent: skip if a build section is already present.
	local has_build
	has_build=$(yq '(.services.mitmproxy | has("build"))' "$compose_file")
	if [[ "$has_build" != "true" ]]; then
		# Carry the pinned image over as the build base. apply_secret_provider
		# runs first, so this is where a provider variant (pass/op) would
		# otherwise be dropped, taking pass-cli / op with it.
		local base_image
		base_image=$(yq -r '.services.mitmproxy.image // ""' "$compose_file")
		yq -i '
			del(.services.mitmproxy.image) |
			del(.services.mitmproxy.entrypoint) |
			.services.mitmproxy.build = {"context": ".", "dockerfile": "Dockerfile.mitmproxy"}
		' "$compose_file"
		if [[ -n "$base_image" ]]; then
			base_image="$base_image" yq -i '
				.services.mitmproxy.build.args.BASE_IMAGE = env(base_image)
			' "$compose_file"
		fi
	fi

	# Caps, sysctls, extra_hosts, env passthrough, and the state volume in one
	# idempotent write. Each field is rewritten as "existing minus this key,
	# plus this key" so a second enable_netbird does not duplicate entries.
	# src_valid_mark is matched by name only; `== '...=1'` segfaults some yq
	# builds. extra_hosts always use docker0: Colima's host-gateway is the VM
	# LAN IP and UDP hairpin to STUN times out. Do not set server.stuns —
	# that disables the embedded listener.
	# No jq `if`/`then`/`end`: mikefarah yq's lexer rejects it here.
	peer_name="$peer_name" yq -i '
		.services.mitmproxy.cap_add = (
			((.services.mitmproxy.cap_add // []) | map(select(. != "NET_ADMIN")))
			+ ["NET_ADMIN"]
		) |
		.services.mitmproxy.sysctls = (
			((.services.mitmproxy.sysctls // []) | map(select(test("src_valid_mark") | not)))
			+ ["net.ipv4.conf.all.src_valid_mark=1"]
		) |
		.services.mitmproxy.extra_hosts = (
			((.services.mitmproxy.extra_hosts // [])
				| map(select(test("^host.docker.internal:") | not)))
			+ ["host.docker.internal:172.17.0.1"]
		) |
		.services.mitmproxy.environment = (
			((.services.mitmproxy.environment // [])
				| map(select(
					. != "NB_SETUP_KEY"
					and . != "NB_API_TOKEN"
					and (test("^NB_PEER_NAME=") | not)
				))
				+ ["NB_SETUP_KEY", "NB_API_TOKEN", "NB_PEER_NAME=" + env(peer_name)]
			)
		) |
		.services."wg-client".environment = (
			(.services."wg-client".environment // [])
			| map(select(
				. != "NB_SETUP_KEY"
				and (test("^NB_MANAGEMENT_URL=") | not)
				and (test("^NB_USE_LEGACY_ROUTING=") | not)
			))
		) |
		.services.mitmproxy.volumes = (
			((.services.mitmproxy.volumes // [])
				| map(select(. != "netbird-mitmproxy-state:/var/lib/netbird")))
			+ ["netbird-mitmproxy-state:/var/lib/netbird"]
		) |
		.volumes."netbird-mitmproxy-state" = (.volumes."netbird-mitmproxy-state" // {})
	' "$compose_file"

	# Default mesh DNS domain unless the compose file already sets one.
	local has_dns_domain
	has_dns_domain=$(yq '[(.services.mitmproxy.environment // [])[] | select(test("^NETBIRD_DNS_DOMAIN="))] | length' "$compose_file")
	if [[ "$has_dns_domain" -eq 0 ]]; then
		yq -i '.services.mitmproxy.environment += ["NETBIRD_DNS_DOMAIN=netbird.selfhosted"]' "$compose_file"
	fi

	# Remove an empty environment block left after stripping the last entries.
	local wg_env_len
	wg_env_len=$(yq '[.services."wg-client".environment[]?] | length' "$compose_file")
	if [[ "$wg_env_len" -eq 0 ]]; then
		yq -i 'del(.services."wg-client".environment)' "$compose_file"
	fi


	if [[ -n "$netbird_management_url" ]]; then
		enrollment_url=$(netbird_enrollment_management_url_from "$netbird_management_url")
		if [[ -n "$enrollment_url" ]]; then
			enrollment_url="$enrollment_url" \
				yq -i '
					.services.mitmproxy.environment = (
						(.services.mitmproxy.environment // [])
						| map(select(test("^NB_MANAGEMENT_URL=") | not))
					) + ["NB_MANAGEMENT_URL=" + env(enrollment_url)]
				' "$compose_file"
			if netbird_enrollment_url_uses_host_bypass "$enrollment_url"; then
				yq -i '
					.services.mitmproxy.environment = (
						(.services.mitmproxy.environment // [])
						| map(select(test("^NB_USE_LEGACY_ROUTING=") | not))
					) + ["NB_USE_LEGACY_ROUTING=true"]
				' "$compose_file"
			fi
		else
			# localhost/127.0.0.1 resolves to the container itself, so no
			# NB_MANAGEMENT_URL is emitted. netbird then falls back to its
			# api.netbird.io default and rejects a self-hosted setup key with
			# "invalid setup-key" — warn rather than fail silently.
			echo "mitmproxy has no NB_MANAGEMENT_URL: $netbird_management_url is not reachable from inside the container." | warning
			echo "  NetBird would enroll against the cloud default (https://api.netbird.io) and reject a self-hosted setup key." | warning
			echo "  Set netbird_enrollment_management_url to a container-reachable address in $(sct_home)/settings.json:" | warning
			echo "    \"netbird_enrollment_management_url\": \"http://<docker-host-ip>:33073\"" | warning
			echo "  Then re-run: sandcat init --netbird ..." | warning
		fi
	fi

	# Inject pinned NetBird build args (version + per-arch checksums) from netbird.env.
	apply_netbird_build_args "$compose_file" "mitmproxy"
}
