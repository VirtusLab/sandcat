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

	set_workspace "$compose_file" "$project_name"

	add_settings_volume "$compose_file" "$settings_file"

	case "$agent" in
		claude)
			add_claude_config_volumes "$compose_file" "${SANDCAT_MOUNT_CLAUDE_CONFIG:=true}"
			;;
		codex)
			add_codex_config_volumes "$compose_file" "${SANDCAT_MOUNT_CODEX_CONFIG:=true}"
			;;
		cursor)
			add_cursor_config_volumes "$compose_file" "${SANDCAT_MOUNT_CURSOR_CONFIG:=true}" "$project_name"
			;;
	esac

	add_git_readonly_volume "$compose_file" "${SANDCAT_MOUNT_GIT_READONLY:=false}"
	add_idea_readonly_volume "$compose_file" "${SANDCAT_MOUNT_IDEA_READONLY:-false}"

	local -a stacks_arr=()
	if [[ -n "$stacks" ]]; then
		read -ra stacks_arr <<< "$stacks"
	fi
	add_shared_cache_volumes "$compose_file" "${SANDCAT_MOUNT_SHARED_CACHE:=true}" "${stacks_arr[@]+"${stacks_arr[@]}"}"

	if [[ $ide == "jetbrains" ]]
	then
		add_jetbrains_capabilities "$compose_file"
	fi

	# Remove blank lines between volume entries/comments.
	# yq inserts blank lines between foot comments and the next sibling.
	# When a blank line is followed by an indented line, strip the blank line
	# via substitution to keep the indented line intact.
	sed '/^$/{ N; /^\n[[:space:]]/{ s/^\n//; }; }' "$compose_file" > "$compose_file.tmp" && mv "$compose_file.tmp" "$compose_file"
}

# Configures the mitmproxy image and secret-backend environment for compose-proxy.yml.
# Args:
#   $1 - Path to the compose-proxy.yml file
#   $2 - Secret provider: none | 1password | protonpass
apply_secret_provider() {
	require yq
	local compose_file=$1
	local provider=${2:-none}

	case "$provider" in
	none)
		return 0
		;;
	1password)
		yq -i '
			.services.mitmproxy.image = "ghcr.io/virtuslab/sandcat-mitmproxy-op:latest" |
			.services.mitmproxy.environment = ["OP_SERVICE_ACCOUNT_TOKEN"]
		' "$compose_file"
		;;
	protonpass)
		yq -i '
			.services.mitmproxy.image = "ghcr.io/virtuslab/sandcat-mitmproxy-pass:latest" |
			.services.mitmproxy.environment = ["PROTON_PASS_PERSONAL_ACCESS_TOKEN"]
		' "$compose_file"
		;;
	*)
		echo "Unknown secret provider: $provider" >&2
		return 1
		;;
	esac
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

# Adds a volume entry to the agent service, either as active or commented.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - Volume entry (e.g., "../.git:/workspace/.git:ro")
#   $3 - true to add as active entry, false to add as comment
#   $4 - Optional description comment
add_volume_entry() {
	require yq
	local compose_file=$1
	local volume_entry=$2
	local active=$3
	local comment=${4:-}

	if [[ $active == "true" ]]
	then
		volume_entry="$volume_entry" yq -i \
			'.services.agent.volumes += [env(volume_entry)]' "$compose_file"
		if [[ -n $comment ]]
		then
			comment="$comment" yq -i \
				'(.services.agent.volumes | .[-1]) head_comment = strenv(comment)' "$compose_file"
		fi
	else
		if [[ -n $comment ]]
		then
			add_volume_foot_comment "$compose_file" "$comment"$'\n'"- $volume_entry"
		else
			add_volume_foot_comment "$compose_file" "- $volume_entry"
		fi
	fi
}

# Adds Claude config volume mounts to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_claude_config_volumes() {
	local compose_file=$1
	local active=${2:-true}

	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.claude/CLAUDE.md:/home/vscode/.claude/CLAUDE.md:ro' "$active" 'Host Claude config (optional)'
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.claude/agents:/home/vscode/.claude/agents:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.claude/commands:/home/vscode/.claude/commands:ro' "$active"
}

# Adds Codex config volume mounts to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_codex_config_volumes() {
	local compose_file=$1
	local active=${2:-true}

	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.codex/AGENTS.md:/home/vscode/.codex-host/AGENTS.md:ro' "$active" 'Host Codex config (optional) — copied into writable ~/.codex/AGENTS.md by app-user-init.sh so rtk can patch it'
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.codex/skills:/home/vscode/.codex/skills:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.codex/commands:/home/vscode/.codex/commands:ro' "$active"
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

	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/AGENTS.md:/home/vscode/.cursor/AGENTS.md:ro' "$active" 'Host Cursor config (optional)'
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/rules:/home/vscode/.cursor/rules:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/skills:/home/vscode/.cursor/skills:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/commands:/home/vscode/.cursor/commands:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/hooks.json:/home/vscode/.cursor/hooks.json:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/hooks:/home/vscode/.cursor/hooks:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/agents:/home/vscode/.cursor/agents:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/mcp.json:/home/vscode/.cursor/mcp.json:ro' "$active"
	# Workspace-scoped runtime state — only this sandcat project's Cursor
	# projects/<id>/ tree is mounted (agent transcripts, terminals, etc.).
	# chats/, plugins/, and subagents/ remain in agent-home to avoid leaking
	# other workspaces' data from the host profile.
	add_volume_entry "$compose_file" \
		"\${HOME}/.cursor/projects/${project_id}:/home/vscode/.cursor/projects/${project_id}" \
		"$active"
}


# Adds .git directory mount as read-only to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_git_readonly_volume() {
	local compose_file=$1
	local active=${2:-true}

	add_volume_entry "$compose_file" '../.git:/workspace/.git:ro' "$active" 'Read-only Git directory'
}

# Adds .idea directory mount as read-only to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_idea_readonly_volume() {
	local compose_file=$1
	local active=${2:-true}

	add_volume_entry "$compose_file" '../.idea:/workspace/.idea:ro' "$active" 'Read-only IntelliJ IDEA project directory'
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

	local entry name path first=true
	for entry in "${entries[@]}"; do
		name=${entry%%:*}
		path=${entry#*:}
		if [[ $first == true ]]; then
			first=false
			add_volume_entry "$compose_file" "$name:$path" "$active" 'Shared dependency caches for the selected stacks (SANDCAT_MOUNT_SHARED_CACHE=false to disable)'
		else
			add_volume_entry "$compose_file" "$name:$path" "$active"
		fi
	done

	# Declare each cache as an external volume with a stable host-scoped
	# name so multiple compose projects reference the same physical volume.
	if [[ $active == "true" ]]; then
		for entry in "${entries[@]}"; do
			name=${entry%%:*}
			name="$name" yq -i \
				'.volumes[env(name)] = {"external": true, "name": env(name)}' \
				"$compose_file"
		done
	fi
}

# Sets the working directory and adds workspace volume mounts for the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - Project name (used to construct /workspaces/<project_name>)
set_workspace() {
	require yq
	local compose_file=$1
	local project_name=$2

	local workspace="/workspaces/$project_name"

	project_name="$project_name" yq -i \
		'.services.agent.working_dir = "/workspaces/" + env(project_name)' "$compose_file"

	add_volume_entry "$compose_file" "..:${workspace}" "true" "Mount the project's code"
	add_volume_entry "$compose_file" "../.devcontainer:${workspace}/.devcontainer:ro" "true" "Read-only devcontainer directory"
	add_volume_entry "$compose_file" "../.sandcat:${workspace}/.sandcat:ro" "true" "Read-only settings directory"
}

# Adds JetBrains-specific capabilities to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
add_jetbrains_capabilities() {
	require yq
	local compose_file=$1

	yq -i '.services.agent.cap_add += ["DAC_OVERRIDE", "CHOWN", "FOWNER"]' "$compose_file"
	yq -i '(.services.agent.cap_add[] | select(. == "DAC_OVERRIDE")) head_comment = "JetBrains IDE: bypass file permission checks on mounted volumes"' "$compose_file"
	yq -i '(.services.agent.cap_add[] | select(. == "CHOWN")) head_comment = "JetBrains IDE: change ownership of IDE cache and state files"' "$compose_file"
	yq -i '(.services.agent.cap_add[] | select(. == "FOWNER")) head_comment = "JetBrains IDE: bypass ownership checks on IDE-managed files"' "$compose_file"
}
