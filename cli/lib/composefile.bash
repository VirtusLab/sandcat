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

	strip_entry_blank_lines "$compose_file"
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
		provider_image="ghcr.io/virtuslab/sandcat-mitmproxy-op:latest"
		;;
	protonpass)
		token_env="PROTON_PASS_PERSONAL_ACCESS_TOKEN"
		provider_image="ghcr.io/virtuslab/sandcat-mitmproxy-pass:latest"
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

# Copies proxy-peer compose stack, registers its include, and injects NetBird
# build args. Without the include the copied file is inert and the proxy-peer
# service never joins the stack.
# Idempotent: skips the include when already present.
# Args:
#   $1 - Path to the devcontainer directory (parent of sandcat/)
enable_proxy_peer() {
	require yq
	local compose_dir=$1
	local src="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy-peer.yml"
	local dst="$compose_dir/sandcat/compose-proxy-peer.yml"
	cp "$src" "$dst"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/Dockerfile.proxy-peer" "$compose_dir/sandcat/"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-init.sh" "$compose_dir/sandcat/scripts/"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-hello.py" "$compose_dir/sandcat/scripts/"
	apply_netbird_build_args "$dst" "proxy-peer"

	local compose_file="$compose_dir/compose-all.yml"
	local has_include
	has_include=$(yq '[.include[]? | select(.path == "sandcat/compose-proxy-peer.yml")] | length' "$compose_file")
	if [[ "$has_include" -eq 0 ]]; then
		yq -i '.include += [{"path": "sandcat/compose-proxy-peer.yml"}]' "$compose_file"
	fi
}

# Wires NetBird enrollment into the mitmproxy service in compose-proxy.yml.
# mitmproxy is the sole NetBird mesh participant in the agent stack; wg-client
# remains a pure tunnel shim (wg0 only). Traffic always flows:
#   agent → wg0 (wg-client) → mitmproxy L7 inspect → internet or wt0 mesh.
#
# When NetBird is enabled, this function:
#   1. Switches mitmproxy from the stock image to a build using Dockerfile.mitmproxy
#      (which installs the pinned NetBird binary and mitmproxy-init.sh entrypoint).
#   2. Removes the compose-level entrypoint override (mitmproxy-init.sh handles it).
#   3. Adds cap_add: [NET_ADMIN] and the WireGuard src_valid_mark sysctl.
#   4. Adds NB_SETUP_KEY (and optionally NB_MANAGEMENT_URL) to the environment.
#   5. Injects NetBird build args (version + per-arch checksums) from netbird.env.
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

	# Add NET_ADMIN capability (required for `ip link add wt0 type wireguard`).
	local has_net_admin
	has_net_admin=$(yq '[(.services.mitmproxy.cap_add // [])[] | select(. == "NET_ADMIN")] | length' "$compose_file")
	if [[ "$has_net_admin" -eq 0 ]]; then
		yq -i '.services.mitmproxy.cap_add += ["NET_ADMIN"]' "$compose_file"
	fi

	# src_valid_mark sysctl is needed for WireGuard fwmark routing on wt0.
	# Scope the check to mitmproxy — wg-client already declares the same sysctl,
	# so a file-wide grep would skip adding it here and leave wt0 unusable.
	# Match via test() on the key name only; avoid == with a literal '=1'
	# suffix, which segfaults certain yq versions.
	local has_src_valid_mark
	has_src_valid_mark=$(yq '[(.services.mitmproxy.sysctls // [])[] | select(test("src_valid_mark"))] | length' "$compose_file")
	if [[ "$has_src_valid_mark" -eq 0 ]]; then
		yq -i '.services.mitmproxy.sysctls += ["net.ipv4.conf.all.src_valid_mark=1"]' "$compose_file"
	fi

	# Add NB_SETUP_KEY to mitmproxy environment (value provided at runtime via env).
	# sandcat compose/run export the key from layered settings (user/project/local);
	# without this passthrough the container only sees ~/.config/sandcat/settings.json
	# and misses project-level netbird_enrollment_key.
	local already_set
	already_set=$(yq '[(.services.mitmproxy.environment // [])[] | select(. == "NB_SETUP_KEY")] | length' "$compose_file")
	if [[ "$already_set" -eq 0 ]]; then
		yq -i '.services.mitmproxy.environment = ((.services.mitmproxy.environment // []) + ["NB_SETUP_KEY"])' "$compose_file"
	fi

	# Drop stale NetBird env from wg-client (pre–NetBird-on-mitmproxy layout).
	yq -i '
		.services."wg-client".environment = (
			(.services."wg-client".environment // [])
			| map(select(
				. != "NB_SETUP_KEY"
				and (test("^NB_MANAGEMENT_URL=") | not)
				and (test("^NB_USE_LEGACY_ROUTING=") | not)
			))
		)
	' "$compose_file"
	# Remove an empty environment block left after stripping the last entries.
	local wg_env_len
	wg_env_len=$(yq '[.services."wg-client".environment[]?] | length' "$compose_file")
	if [[ "$wg_env_len" -eq 0 ]]; then
		yq -i 'del(.services."wg-client".environment)' "$compose_file"
	fi

	# Publish the mesh DNS domain so the mitmproxy addon can emit it to sandcat.env
	# and the agent can form peer FQDNs without hard-coding the domain.
	# Default is netbird.selfhosted; override by editing the compose file or
	# by passing a custom NETBIRD_DNS_DOMAIN in docker-compose.override.yml.
	local has_dns_domain
	has_dns_domain=$(yq '[(.services.mitmproxy.environment // [])[] | select(test("^NETBIRD_DNS_DOMAIN="))] | length' "$compose_file")
	if [[ "$has_dns_domain" -eq 0 ]]; then
		yq -i '.services.mitmproxy.environment += ["NETBIRD_DNS_DOMAIN=netbird.selfhosted"]' "$compose_file"
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
			netbird_sync_local_server_exposed_address
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

	# Replace any prior NB_PEER_NAME=* then set the project-scoped value.
	peer_name="$peer_name" yq -i '
		.services.mitmproxy.environment = (
			(.services.mitmproxy.environment // [])
			| map(select(test("^NB_PEER_NAME=") | not))
		) + ["NB_PEER_NAME=" + env(peer_name)]
	' "$compose_file"

	local has_api_token
	has_api_token=$(yq '[(.services.mitmproxy.environment // [])[] | select(. == "NB_API_TOKEN")] | length' "$compose_file")
	if [[ "$has_api_token" -eq 0 ]]; then
		yq -i '.services.mitmproxy.environment = ((.services.mitmproxy.environment // []) + ["NB_API_TOKEN"])' "$compose_file"
	fi

	local has_state_vol
	has_state_vol=$(yq '[(.services.mitmproxy.volumes // [])[] | select(. == "netbird-mitmproxy-state:/var/lib/netbird")] | length' "$compose_file")
	if [[ "$has_state_vol" -eq 0 ]]; then
		yq -i '.services.mitmproxy.volumes += ["netbird-mitmproxy-state:/var/lib/netbird"]' "$compose_file"
	fi
	yq -i '.volumes."netbird-mitmproxy-state" = (.volumes."netbird-mitmproxy-state" // {})' "$compose_file"

	# Inject pinned NetBird build args (version + per-arch checksums) from netbird.env.
	apply_netbird_build_args "$compose_file" "mitmproxy"
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

	# Start capability-runtime whenever agent starts (devcontainer reopen, sandcat run).
	local has_dep
	has_dep=$(yq '.services.agent.depends_on.capability-runtime.condition // ""' "$compose_file")
	if [[ "$has_dep" != "service_started" ]]; then
		yq -i '.services.agent.depends_on.capability-runtime.condition = "service_started"' "$compose_file"
	fi

	# The L7 revoke socket gets its own volume, shared by capability-runtime and
	# mitmproxy alone — never the agent, whose vscode user shares uid 1000 with
	# mitmproxy and would therefore satisfy the socket's 0600 mode. Declared here
	# as well because a capability-only project has no compose-proxy.yml.
	local cap_compose="$compose_dir/sandcat/compose-capability.yml"
	local has_revoke_vol
	has_revoke_vol=$(yq '[.volumes | keys[]? | select(. == "l7-revoke-socket")] | length' "$cap_compose")
	if [[ "$has_revoke_vol" -eq 0 ]]; then
		yq -i '.volumes.l7-revoke-socket = {}' "$cap_compose"
	fi

	local proxy_compose="$compose_dir/sandcat/compose-proxy.yml"
	if [[ -f "$proxy_compose" ]]; then
		local has_cap_vol has_proxy_revoke_vol
		has_cap_vol=$(yq '[.volumes | keys[]? | select(. == "capability-socket")] | length' "$proxy_compose")
		if [[ "$has_cap_vol" -eq 0 ]]; then
			yq -i '.volumes.capability-socket = {}' "$proxy_compose"
		fi

		has_proxy_revoke_vol=$(yq '[.volumes | keys[]? | select(. == "l7-revoke-socket")] | length' "$proxy_compose")
		if [[ "$has_proxy_revoke_vol" -eq 0 ]]; then
			yq -i '.volumes.l7-revoke-socket = {}' "$proxy_compose"
		fi

		local has_mitm_cap_vol has_l7_client has_l7_record has_mitm_agent_id
		has_mitm_cap_vol=$(yq '[.services.mitmproxy.volumes[]? | select(. == "capability-socket:/run/sandcat-capability")] | length' "$proxy_compose")
		if [[ "$has_mitm_cap_vol" -eq 0 ]]; then
			yq -i '.services.mitmproxy.volumes += ["capability-socket:/run/sandcat-capability"]' "$proxy_compose"
		fi

		has_l7_client=$(yq '[.services.mitmproxy.volumes[]? | select(. == "./scripts/l7_record_client.py:/scripts/l7_record_client.py:ro")] | length' "$proxy_compose")
		if [[ "$has_l7_client" -eq 0 ]]; then
			yq -i '.services.mitmproxy.volumes += ["./scripts/l7_record_client.py:/scripts/l7_record_client.py:ro"]' "$proxy_compose"
		fi

		local has_l7_revoke
		has_l7_revoke=$(yq '[.services.mitmproxy.volumes[]? | select(. == "./scripts/l7_revoke_rpc.py:/scripts/l7_revoke_rpc.py:ro")] | length' "$proxy_compose")
		if [[ "$has_l7_revoke" -eq 0 ]]; then
			yq -i '.services.mitmproxy.volumes += ["./scripts/l7_revoke_rpc.py:/scripts/l7_revoke_rpc.py:ro"]' "$proxy_compose"
		fi

		has_l7_record=$(yq '[.services.mitmproxy.environment[]? | select(. == "CAPABILITY_L7_RECORD")] | length' "$proxy_compose")
		if [[ "$has_l7_record" -eq 0 ]]; then
			yq -i '.services.mitmproxy.environment = ((.services.mitmproxy.environment // []) + ["CAPABILITY_L7_RECORD"])' "$proxy_compose"
		fi

		has_mitm_agent_id=$(yq '[.services.mitmproxy.environment[]? | select(. == "SANDCAT_AGENT_ID=devcontainer-agent")] | length' "$proxy_compose")
		if [[ "$has_mitm_agent_id" -eq 0 ]]; then
			yq -i '.services.mitmproxy.environment = ((.services.mitmproxy.environment // []) + ["SANDCAT_AGENT_ID=devcontainer-agent"])' "$proxy_compose"
		fi

		local has_mitm_revoke_vol has_mitm_revoke_socket
		has_mitm_revoke_vol=$(yq '[.services.mitmproxy.volumes[]? | select(. == "l7-revoke-socket:/run/sandcat-l7-revoke")] | length' "$proxy_compose")
		if [[ "$has_mitm_revoke_vol" -eq 0 ]]; then
			yq -i '.services.mitmproxy.volumes += ["l7-revoke-socket:/run/sandcat-l7-revoke"]' "$proxy_compose"
		fi

		has_mitm_revoke_socket=$(yq '[.services.mitmproxy.environment[]? | select(. == "MITMPROXY_REVOKE_SOCKET=/run/sandcat-l7-revoke/l7-revoke.sock")] | length' "$proxy_compose")
		if [[ "$has_mitm_revoke_socket" -eq 0 ]]; then
			yq -i '.services.mitmproxy.environment = ((.services.mitmproxy.environment // []) + ["MITMPROXY_REVOKE_SOCKET=/run/sandcat-l7-revoke/l7-revoke.sock"])' "$proxy_compose"
		fi
	fi

	_enable_capability_mcp_config "$(dirname "$compose_dir")" "$compose_dir/devcontainer.json"
}

# Writes .cursor/mcp.json and patches devcontainer remoteEnv for capability MCP.
# Args:
#   $1 - Project root (parent of .devcontainer)
#   $2 - Path to devcontainer.json
_enable_capability_mcp_config() {
	local project_path=$1
	local devcontainer_json=$2
	local mcp_dir="$project_path/.cursor"

	mkdir -p "$mcp_dir"
	cat >"$mcp_dir/mcp.json" <<'EOF'
{
  "mcpServers": {
    "sandcat-capability": {
      "command": "capability-mcp-bridge",
      "args": [],
      "env": {
        "SANDCAT_AGENT_ID": "devcontainer-agent",
        "CAPABILITY_AGENT_SOCKET": "/run/sandcat-capability/agent.sock"
      }
    }
  }
}
EOF

	if [[ ! -f "$devcontainer_json" ]] || grep -q 'SANDCAT_AGENT_ID' "$devcontainer_json"; then
		return 0
	fi

	# JSONC devcontainer.json — inject remoteEnv keys after GIT_ASKPASS.
	sed -i.bak \
		's|"GIT_ASKPASS": ""|"GIT_ASKPASS": "",\
		"SANDCAT_AGENT_ID": "devcontainer-agent",\
		"CAPABILITY_AGENT_SOCKET": "/run/sandcat-capability/agent.sock"|' \
		"$devcontainer_json"
	rm -f "${devcontainer_json}.bak"
}
