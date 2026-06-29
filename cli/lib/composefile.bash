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
#   - SANDCAT_MOUNT_CURSOR_CONFIG: "true" to mount host Cursor config (~/.cursor)
#   - SANDCAT_MOUNT_GIT_READONLY: "true" to mount .git directory as read-only
#   - SANDCAT_MOUNT_IDEA_READONLY: "true" to mount .idea directory as read-only
# Args:
#   $1 - Path to the settings file to mount, relative to the Docker Compose file directory
#   $2 - Path to the Docker Compose file to modify
#   $3 - The agent name (e.g., "claude")
#   $4 - The IDE name (e.g., "vscode", "jetbrains", "none") (optional)
#   $5 - The project name (used to construct workspace paths) (required)
#
customize_compose_file() {
	local settings_file=$1
	local compose_file=$2
	local agent=$3
	local ide=${4:-none}
	local project_name=$5

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
		cursor)
			add_cursor_config_volumes "$compose_file" "${SANDCAT_MOUNT_CURSOR_CONFIG:=true}"
			;;
	esac

	add_git_readonly_volume "$compose_file" "${SANDCAT_MOUNT_GIT_READONLY:=false}"
	add_idea_readonly_volume "$compose_file" "${SANDCAT_MOUNT_IDEA_READONLY:-false}"

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

# Adds Cursor config volume mounts to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active, false to add as comment
add_cursor_config_volumes() {
	local compose_file=$1
	local active=${2:-true}

	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/AGENTS.md:/home/vscode/.cursor/AGENTS.md:ro' "$active" 'Host Cursor config (optional)'
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/rules:/home/vscode/.cursor/rules:ro' "$active"
	# shellcheck disable=SC2016
	add_volume_entry "$compose_file" '${HOME}/.cursor/skills:/home/vscode/.cursor/skills:ro' "$active"
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

# Injects NetBird version and per-arch checksum build args into wg-client's
# compose build section, sourced from netbird.env (sibling to compose-proxy.yml).
# Args:
#   $1 - Path to compose-proxy.yml
apply_netbird_build_args() {
	require yq
	local compose_file=$1
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
		.services.\"wg-client\".build.args.NETBIRD_VERSION = \"${NETBIRD_VERSION}\" |
		.services.\"wg-client\".build.args.NETBIRD_SHA256_AMD64 = \"${NETBIRD_SHA256_AMD64}\" |
		.services.\"wg-client\".build.args.NETBIRD_SHA256_ARM64 = \"${NETBIRD_SHA256_ARM64}\"
	" "$compose_file"
}

# Adds NB_SETUP_KEY to the wg-client service's environment in the deployed
# compose-proxy.yml. wg-client-init.sh reads this at startup to enroll the
# container as a NetBird peer and start the daemon on wt0.
# Args:
#   $1 - Path to compose-proxy.yml
#   $2 - Optional NetBird management server URL
enable_netbird() {
	require yq
	# shellcheck source=netbird.bash
	source "$SCT_LIBDIR/netbird.bash"

	local compose_file=$1
	local netbird_management_url=${2:-}
	local enrollment_url

	local already_set
	already_set=$(yq '[(.services."wg-client".environment // [])[] | select(. == "NB_SETUP_KEY")] | length' "$compose_file")

	if [[ "$already_set" -eq 0 ]]; then
		yq -i '.services."wg-client".environment += ["NB_SETUP_KEY"]' "$compose_file"
	fi

	if [[ -n "$netbird_management_url" ]]; then
		enrollment_url=$(netbird_enrollment_management_url_from "$netbird_management_url")
		if [[ -n "$enrollment_url" ]]; then
			enrollment_url="$enrollment_url" \
				yq -i '
					.services."wg-client".environment = (
						(.services."wg-client".environment // [])
						| map(select(test("^NB_MANAGEMENT_URL=") | not))
					) + ["NB_MANAGEMENT_URL=" + env(enrollment_url)]
				' "$compose_file"
			if netbird_enrollment_url_uses_host_bypass "$enrollment_url"; then
				yq -i '
					.services."wg-client".environment = (
						(.services."wg-client".environment // [])
						| map(select(test("^NB_USE_LEGACY_ROUTING=") | not))
					) + ["NB_USE_LEGACY_ROUTING=true"]
				' "$compose_file"
			fi
			netbird_sync_local_server_exposed_address
		fi
	fi
}

# Adds capability-runtime sidecar include and agent socket mount/env to compose-all.yml.
# Idempotent: skips entries that are already present.
# Args:
#   $1 - Path to the devcontainer directory (parent of compose-all.yml)
enable_capability() {
	require yq
	local compose_dir=$1
	local compose_file="$compose_dir/compose-all.yml"

	local has_include
	has_include=$(yq '[.include[]? | select(.path == "sandcat/compose-capability.yml")] | length' "$compose_file")
	if [[ "$has_include" -eq 0 ]]; then
		yq -i '.include += [{"path": "sandcat/compose-capability.yml"}]' "$compose_file"
	fi

	# Legacy path nested under wg-runtime:/run/sandcat:ro — Docker cannot mount there.
	yq -i '
		.services.agent.volumes = (
			(.services.agent.volumes // [])
			| map(select(. != "capability-socket:/run/sandcat/capability:ro"))
		)
	' "$compose_file"
	yq -i '
		.services.agent.environment = (
			(.services.agent.environment // [])
			| map(select(. != "CAPABILITY_AGENT_SOCKET=/run/sandcat/capability/agent.sock"))
		)
	' "$compose_file"

	local has_volume
	has_volume=$(yq '[.services.agent.volumes[]? | select(. == "capability-socket:/run/sandcat-capability:ro")] | length' "$compose_file")
	if [[ "$has_volume" -eq 0 ]]; then
		yq -i '.services.agent.volumes += ["capability-socket:/run/sandcat-capability:ro"]' "$compose_file"
	fi

	local has_agent_id has_socket
	has_agent_id=$(yq '[.services.agent.environment[]? | select(. == "SANDCAT_AGENT_ID=devcontainer-agent")] | length' "$compose_file")
	has_socket=$(yq '[.services.agent.environment[]? | select(. == "CAPABILITY_AGENT_SOCKET=/run/sandcat-capability/agent.sock")] | length' "$compose_file")

	if [[ "$has_agent_id" -eq 0 || "$has_socket" -eq 0 ]]; then
		local env_additions=()
		if [[ "$has_agent_id" -eq 0 ]]; then
			env_additions+=("SANDCAT_AGENT_ID=devcontainer-agent")
		fi
		if [[ "$has_socket" -eq 0 ]]; then
			env_additions+=("CAPABILITY_AGENT_SOCKET=/run/sandcat-capability/agent.sock")
		fi
		local entry yq_array=""
		for entry in "${env_additions[@]}"; do
			yq_array+="\"${entry}\","
		done
		yq_array="[${yq_array%,}]"
		yq -i ".services.agent.environment = ((.services.agent.environment // []) + ${yq_array})" "$compose_file"
	fi
}
