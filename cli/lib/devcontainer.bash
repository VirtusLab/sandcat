#!/usr/bin/env bash

# shellcheck source=stacks.bash
source "$SCT_LIBDIR/stacks.bash"
# shellcheck source=agents.bash
source "$SCT_LIBDIR/agents.bash"
# shellcheck source=devbox.bash
source "$SCT_LIBDIR/devbox.bash"

# Replaces __PROJECT_NAME__ placeholder with the actual project name and
# selects the IDE-specific customizations block in devcontainer.json.
#
# Uses `sed` because `yq` does not support JSONC
# Args:
#   $1 - Path to the devcontainer.json file
#   $2 - Project name to substitute
#   $3 - IDE name: vscode | jetbrains | none (defaults to vscode)
customize_devcontainer_json() {
	local devcontainer_json=$1
	local project_name=$2
	local ide=${3:-vscode}

	# Use sed in a way that works on both BSD (macOS) and GNU (Linux)
	# Escape sed metacharacters in project_name (& and \ have special meaning)
	local escaped_name
	escaped_name=$(printf '%s' "$project_name" | sed 's/[&\\/]/\\&/g')
	sed -i.bak "s/__PROJECT_NAME__/${escaped_name}/g" "$devcontainer_json" && rm -f "${devcontainer_json}.bak"

	apply_ide_customizations "$devcontainer_json" "$ide"
}

# Rewrites the customizations block based on the selected IDE.
#
# The template wraps the vscode block with marker comment lines. Behavior:
#   - vscode:    strip marker lines, keep block as-is
#   - jetbrains: replace the vscode block with a JetBrains block
#   - none:      drop the entire customizations block
#
# Args:
#   $1 - Path to the devcontainer.json file
#   $2 - IDE name: vscode | jetbrains | none
apply_ide_customizations() {
	local file=$1
	local ide=$2

	local tmpfile="${file}.tmp"
	local in_block=0
	local line
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
			*"__CUSTOMIZATIONS_START__"*)
				in_block=1
				if [[ "$ide" == "jetbrains" ]]; then
					# JetBrains Gateway / IDE Services reads customizations.jetbrains.
					# `backend` selects which JetBrains product opens the project;
					# IntelliJ is a safe default and users can edit it per project.
					printf '\t"customizations": {\n\t\t"jetbrains": {\n\t\t\t"backend": "IntelliJ",\n\t\t\t"plugins": [],\n\t\t\t"settings": {}\n\t\t}\n\t}\n'
				fi
				continue
				;;
			*"__CUSTOMIZATIONS_END__"*)
				in_block=0
				continue
				;;
		esac
		if [[ $in_block -eq 0 || "$ide" == "vscode" ]]; then
			printf '%s\n' "$line"
		fi
	done < "$file" > "$tmpfile"
	mv "$tmpfile" "$file"
}

# Adds VS Code extensions for selected stacks to devcontainer.json.
# Replaces the // __STACK_EXTENSIONS__ placeholder line.
# Args:
#   $1 - Path to the devcontainer.json file
#   $@ - Stack names (remaining args)
customize_devcontainer_extensions() {
	local devcontainer_json=$1
	shift

	local ext_lines=""
	local stack ext
	for stack in "$@"; do
		ext=$(stack_extension "$stack")
		if [[ -n "$ext" ]]; then
			ext_lines="${ext_lines}				\"${ext}\","$'\n'
		fi
	done

	# Build the output file, replacing the placeholder line
	local tmpfile="${devcontainer_json}.tmp"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == *"__STACK_EXTENSIONS__"* ]]; then
			if [[ -n "$ext_lines" ]]; then
				printf '%s' "$ext_lines"
			fi
		else
			printf '%s\n' "$line"
		fi
	done < "$devcontainer_json" > "$tmpfile"
	mv "$tmpfile" "$devcontainer_json"
}

# Whole-line placeholder replacement.
#
# For each line in <file>: if the line contains <tokenN>, replace the *entire*
# line with <replacementN> (which may itself span multiple lines). When
# <replacementN> is empty, the placeholder line is dropped entirely.
#
# Tokens are matched in order; the first match per line wins.
#
# Args:
#   $1     - File to modify in place
#   $2..$N - Alternating <token> <replacement> pairs
apply_template_placeholders() {
	local file=$1
	shift

	local tokens=() replacements=()
	while [[ $# -ge 2 ]]; do
		tokens+=("$1")
		replacements+=("$2")
		shift 2
	done

	local tmpfile="${file}.tmp"
	local line i matched
	while IFS= read -r line || [[ -n "$line" ]]; do
		matched=0
		for i in "${!tokens[@]}"; do
			if [[ "$line" == *"${tokens[$i]}"* ]]; then
				matched=1
				if [[ -n "${replacements[$i]}" ]]; then
					printf '%s\n' "${replacements[$i]}"
				fi
				break
			fi
		done
		if [[ "$matched" == 0 ]]; then
			printf '%s\n' "$line"
		fi
	done < "$file" > "$tmpfile"
	mv "$tmpfile" "$file"
}

# In-line placeholder replacement.
#
# For each line: replace every occurrence of <tokenN> with <replacementN>.
# Use this when the placeholder is embedded inside a longer line (e.g. the
# mitmproxy command line) rather than occupying the whole line.
#
# Args:
#   $1     - File to modify in place
#   $2..$N - Alternating <token> <replacement> pairs
apply_inline_placeholders() {
	local file=$1
	shift

	local tokens=() replacements=()
	while [[ $# -ge 2 ]]; do
		tokens+=("$1")
		replacements+=("$2")
		shift 2
	done

	local tmpfile="${file}.tmp"
	local line i
	while IFS= read -r line || [[ -n "$line" ]]; do
		for i in "${!tokens[@]}"; do
			line="${line//${tokens[$i]}/${replacements[$i]}}"
		done
		printf '%s\n' "$line"
	done < "$file" > "$tmpfile"
	mv "$tmpfile" "$file"
}

# Adds stack-contributed environment variables (e.g. uv's TLS config for the
# python stack) to services.agent.environment in compose-all.yml.
# Args:
#   $1 - Path to compose-all.yml
#   $@ - Stack names (remaining args)
customize_compose_stack_environment() {
	local compose_file=$1
	shift

	local entries="" stack env
	for stack in "$@"; do
		env=$(stack_env_entries "$stack")
		[[ -n "$env" ]] && entries="${entries}${env}"$'\n'
	done

	merge_compose_agent_environment "$compose_file" "$entries"
}

# Merges KEY=value environment entries into services.agent.environment in
# compose-all.yml. Appends to any entries already present (rather than
# overwriting) so agent- and stack-contributed variables coexist regardless
# of call order. Building the array structurally avoids fragile
# line-counting in compose-all.yml. No-op when passed no entries — compose
# rejects `environment: {}`.
# Args:
#   $1 - Path to compose-all.yml
#   $2 - Newline-separated "KEY=value" entries (empty lines ignored)
merge_compose_agent_environment() {
	local compose_file=$1
	local entries=$2

	local entry yq_array=""
	while IFS= read -r entry; do
		[[ -z "$entry" ]] && continue
		# Wrap each entry as a JSON string for yq's expression parser;
		# escape backslashes and double quotes so KEY=VALUE pairs with
		# special characters round-trip correctly.
		local escaped="${entry//\\/\\\\}"
		escaped="${escaped//\"/\\\"}"
		yq_array+="\"${escaped}\","
	done <<< "$entries"
	[[ -z "$yq_array" ]] && return 0
	yq_array="[${yq_array%,}]"
	yq -i ".services.agent.environment = ((.services.agent.environment // []) + ${yq_array})" "$compose_file"
}

# Replaces provider-specific placeholders in generated templates.
# Args:
#   $1 - Path to devcontainer directory
#   $2 - Agent name
customize_agent_templates() {
	local devcontainer_dir=$1
	local agent=$2

	local extension settings_block environment_entries docker_install_block docker_home_prep_block user_init_block
	local mitm_addon_file mitm_http2 mitm_streaming_flags
	extension=$(sct_agent_vscode_extension "$agent")
	settings_block=$(sct_agent_devcontainer_settings_block "$agent")
	environment_entries=$(sct_agent_compose_environment_entries "$agent")
	docker_install_block=$(sct_agent_docker_install_block "$agent")
	docker_home_prep_block=$(sct_agent_docker_home_prep_block "$agent")
	user_init_block=$(sct_agent_user_init_block "$agent")
	mitm_streaming_flags=$(sct_agent_mitm_streaming_flags "$agent")
	case "$agent" in
		cursor)
			mitm_addon_file="mitmproxy_addon_cursor.py"
			mitm_http2="true"
			;;
		codex)
			mitm_addon_file="mitmproxy_addon_codex.py"
			mitm_http2="true"
			;;
		claude|*)
			mitm_addon_file="mitmproxy_addon_claude.py"
			mitm_http2="true"
			;;
	esac

	# Pre-format the extension entry so apply_template_placeholders can drop
	# the placeholder line wholesale when no extension is contributed.
	local extension_replacement=""
	if [[ -n "$extension" ]]; then
		extension_replacement=$(printf '\t\t\t\t"%s",' "$extension")
	fi

	apply_template_placeholders \
		"$devcontainer_dir/devcontainer.json" \
		"__AGENT_EXTENSION__" "$extension_replacement" \
		"__AGENT_SETTINGS__"  "$settings_block"

	merge_compose_agent_environment "$devcontainer_dir/compose-all.yml" "$environment_entries"

	apply_template_placeholders \
		"$devcontainer_dir/Dockerfile.app" \
		"__AGENT_DOCKER_INSTALL__"   "$docker_install_block" \
		"__AGENT_DOCKER_HOME_PREP__" "$docker_home_prep_block"

	apply_template_placeholders \
		"$devcontainer_dir/sandcat/scripts/app-user-init.sh" \
		"__AGENT_USER_INIT__" "$user_init_block"

	# mitmproxy command/addon placeholders are inline (embedded in the
	# `command:` line). When streaming flags expand to empty (Claude path),
	# the resulting double space between adjacent tokens is harmless for
	# shell argv splitting.
	apply_inline_placeholders \
		"$devcontainer_dir/sandcat/compose-proxy.yml" \
		"__AGENT_MITM_ADDON__"           "$mitm_addon_file" \
		"__MITM_HTTP2__"                 "$mitm_http2" \
		"__AGENT_MITM_STREAMING_FLAGS__" "$mitm_streaming_flags"
}
