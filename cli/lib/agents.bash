#!/usr/bin/env bash

# Returns supported agents as a space-separated list.
sct_available_agents() {
	echo "claude cursor"
}

# Returns 0 if agent is valid.
# Args:
#   $1 - Agent name
sct_is_valid_agent() {
	local agent=$1
	local item
	for item in $(sct_available_agents); do
		if [[ "$item" == "$agent" ]]; then
			return 0
		fi
	done
	return 1
}

# Maps sandcat project_name to Cursor's ~/.cursor/projects/<id> directory.
# Cursor encodes the workspace path /workspaces/<name> by dropping the leading
# slash and replacing path separators with hyphens (e.g. workspaces-foo-bar).
#
# Args:
#   $1 - Sandcat project name (workspace is /workspaces/<name>)
sct_cursor_workspace_project_id() {
	local project_name=$1
	local workspace="/workspaces/$project_name"
	printf '%s' "${workspace#/}" | tr '/' '-'
}

# Returns the optional config mount env var for an agent.
# Args:
#   $1 - Agent name
sct_agent_mount_env_var() {
	local agent=$1
	case "$agent" in
		claude) echo "SANDCAT_MOUNT_CLAUDE_CONFIG" ;;
		cursor) echo "SANDCAT_MOUNT_CURSOR_CONFIG" ;;
		*)      echo "" ;;
	esac
}

# Pre-creates the host paths that the optional agent config mounts will bind
# read-only into the container. Without this, Docker materialises any missing
# bind source as a root-owned empty directory in the user's $HOME — annoying
# to clean up and confusing because the directory shows up out of nowhere.
#
# Each path on its own line. Lines ending with '/' are treated as directories.
# Files are created when missing; JSON config files get minimal valid defaults
# (empty files break Cursor CLI parsing and Sandcat's jq bootstrap). Markdown
# files (AGENTS.md, CLAUDE.md) may remain empty. Pre-creating only happens when
# the agent's mount env var is "true" (or unset, which defaults to true via
# customize_compose_file).
#
# Args:
#   $1 - Agent name
#   $2 - Sandcat project name (required for cursor workspace-scoped paths)
sct_agent_host_config_paths() {
	local agent=$1
	local project_name=${2:-}
	case "$agent" in
		claude)
			cat <<'EOF'
$HOME/.claude/agents/
$HOME/.claude/commands/
$HOME/.claude/CLAUDE.md
EOF
			;;
		cursor)
			local project_id
			project_id=$(sct_cursor_workspace_project_id "$project_name")
			cat <<EOF
\$HOME/.cursor/rules/
\$HOME/.cursor/skills/
\$HOME/.cursor/commands/
\$HOME/.cursor/agents/
\$HOME/.cursor/hooks/
\$HOME/.cursor/projects/${project_id}/
\$HOME/.cursor/AGENTS.md
\$HOME/.cursor/hooks.json
\$HOME/.cursor/mcp.json
EOF
			;;
		*)
			echo ""
			;;
	esac
}

# Creates a host config file when missing or zero-length. Existing non-empty
# files are left untouched (atime-only touch). JSON files get minimal valid
# defaults so Docker bind-mounts a file, not a directory, and Cursor CLI can
# parse the mount target.
#
# Args:
#   $1 - Agent name
#   $2 - Absolute path to the file
_ensure_host_agent_config_file() {
	local agent=$1
	local path=$2

	if [[ -s "$path" ]]; then
		touch -a "$path"
		return 0
	fi

	case "$agent" in
		cursor)
			case "$(basename "$path")" in
			cli-config.json)
				printf '%s\n' '{"version":1}' >"$path"
				;;
			hooks.json)
				printf '%s\n' '{"hooks":{}}' >"$path"
				;;
			mcp.json)
				printf '%s\n' '{"mcpServers":{}}' >"$path"
				;;
			AGENTS.md)
				: >"$path"
				;;
			*)
				: >"$path"
				;;
			esac
			;;
		*)
			: >"$path"
			;;
	esac
}

# Pre-creates host config paths for the selected agent so Docker doesn't have
# to invent them as root-owned. No-op when the user opts out of the optional
# config mount via SANDCAT_MOUNT_<AGENT>_CONFIG=false.
#
# Args:
#   $1 - Agent name
#   $2 - Sandcat project name (used for cursor workspace-scoped host paths)
ensure_host_agent_config_paths() {
	local agent=$1
	local project_name=${2:-}
	local mount_var
	mount_var=$(sct_agent_mount_env_var "$agent")
	if [[ -z "$mount_var" ]]; then
		return 0
	fi

	# Match the default in customize_compose_file: missing/unset means true.
	local mount_value="${!mount_var:-true}"
	if [[ "$mount_value" != "true" ]]; then
		return 0
	fi

	local line expanded
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Expand $HOME and other simple env vars without invoking eval on
		# untrusted input (the values come from this file, not user input).
		expanded="${line//\$HOME/$HOME}"
		if [[ "$expanded" == */ ]]; then
			mkdir -p "${expanded%/}"
		else
			mkdir -p "$(dirname "$expanded")"
			_ensure_host_agent_config_file "$agent" "$expanded"
		fi
	done < <(sct_agent_host_config_paths "$agent" "$project_name")
}

# Returns one-line API key help text for init output.
# Args:
#   $1 - Agent name
sct_agent_api_key_help() {
	local agent=$1
	case "$agent" in
		claude) echo "ANTHROPIC_API_KEY  your Anthropic API key (for Claude Code)" ;;
		cursor) echo "CURSOR_API_KEY     your Cursor API key (for Cursor CLI)" ;;
		*)      echo "ANTHROPIC_API_KEY  API key for your selected agent" ;;
	esac
}

# Returns the 1Password reference example for the agent's primary API key,
# rendered as the user-settings line shown in init's "next steps" section.
#
# Args:
#   $1 - Agent name
sct_agent_op_api_key_help() {
	local agent=$1
	case "$agent" in
		cursor)
			echo "CURSOR_API_KEY     \"op\": \"op://vault/Cursor API Key/credential\""
			;;
		claude|*)
			echo "ANTHROPIC_API_KEY  \"op\": \"op://vault/Anthropic API Key/credential\""
			;;
	esac
}

# Hook fired right after `init` creates the user-settings file, used by
# agents that need to seed agent-specific defaults into the JSON without
# overwriting user-provided values.
#
# Implementations need access to sct_home (constants.bash) and live in
# `init` (e.g. ensure_cursor_user_settings_defaults). The hook just
# dispatches to the right helper or no-ops for agents that don't need one.
#
# Args:
#   $1 - Agent name
sct_agent_post_user_settings_hook() {
	local agent=$1
	case "$agent" in
		cursor)
			if declare -F ensure_cursor_user_settings_defaults >/dev/null; then
				ensure_cursor_user_settings_defaults
			fi
			;;
		*)
			return 0
			;;
	esac
}

# Returns extension id for a selected agent.
# Args:
#   $1 - Agent name
sct_agent_vscode_extension() {
	local agent=$1
	case "$agent" in
		claude) echo "anthropic.claude-code" ;;
		cursor) echo "anysphere.cursor" ;;
		*)      echo "" ;;
	esac
}

# Returns devcontainer settings block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_devcontainer_settings_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
				// Sandcat provides the security boundary (network isolation,
				// secret substitution, iptables kill-switch), so permission
				// prompts inside the container add friction without meaningful
				// security benefit. Remove these if you prefer interactive
				// permission approval.
				"claudeCode.allowDangerouslySkipPermissions": true,
				"claudeCode.initialPermissionMode": "bypassPermissions",
				// Optional: override the default Claude model.
				"claudeCode.selectedModel": "opus"
EOF
			;;
		cursor)
			cat <<'EOF'
				// Cursor CLI support currently uses compatibility defaults for
				// auth/network config. Add Cursor-specific settings here if needed.
EOF
			;;
		*)
			echo ""
			;;
	esac
}

# Returns the agent's services.agent environment entries as KEY=VALUE lines,
# one per line. The caller is responsible for emitting the YAML `environment:`
# key only when the result is non-empty — Docker Compose rejects an empty
# `environment: {}` block.
#
# Args:
#   $1 - Agent name
sct_agent_compose_environment_entries() {
	local agent=$1
	case "$agent" in
		claude)
			echo "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
			;;
		cursor|*)
			echo ""
			;;
	esac
}

# Returns Dockerfile install block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_docker_install_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
# Install Claude Code (native binary — no Node.js required).
RUN curl -fsSL https://claude.ai/install.sh | bash
EOF
			;;
		cursor)
			cat <<'EOF'
# Install Cursor CLI.
RUN curl https://cursor.com/install -fsS | bash
EOF
			;;
		*)
			echo ""
			;;
	esac
}

# Returns Dockerfile config-home preparation block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_docker_home_prep_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
# Pre-create ~/.claude so Docker bind-mounts (CLAUDE.md, agents/, commands/)
# don't cause it to be created as root-owned.
RUN mkdir -p /home/vscode/.claude
RUN echo 'alias claude-yolo="claude --dangerously-skip-permissions"' >> /home/vscode/.bashrc
EOF
			;;
		cursor)
			cat <<'EOF'
# Pre-create Cursor config directories so optional host config mounts do not
# create them as root-owned.
RUN mkdir -p /home/vscode/.cursor /home/vscode/.config/cursor
EOF
			;;
		*)
			echo ""
			;;
	esac
}

# Returns mitmproxy --set flags that affect streaming-body handling.
#
# Cursor's API uses Connect/HTTP-2 streaming for agent calls. Mitmproxy needs
# stream_large_bodies (don't buffer >1MB), connection_strategy=lazy, anticomp,
# and a long read timeout to keep those streams stable.
#
# Claude's traffic is plain JSON request/response, so leaving the body
# buffered means _substitute_secrets in the addon can run a content-based
# placeholder leak check (see mitmproxy_addon_common.py:_substitute_secrets).
# Returning the flags for Claude would weaken that check, so the dispatcher
# returns an empty string for Claude and the unknown-agent fallback.
#
# Args:
#   $1 - Agent name
sct_agent_mitm_streaming_flags() {
	local agent=$1
	case "$agent" in
		cursor)
			echo "--set stream_large_bodies=1m --set connection_strategy=lazy --set anticomp=true --set timeout_read=300"
			;;
		claude|*)
			echo ""
			;;
	esac
}

# Returns app-user-init bootstrap block for selected agent.
# Args:
#   $1 - Agent name
sct_agent_user_init_block() {
	local agent=$1
	case "$agent" in
		claude)
			cat <<'EOF'
# Seed the onboarding flag so Claude Code uses the API key without interactive
# setup. Only written when the user configured an ANTHROPIC_API_KEY secret.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo '{"hasCompletedOnboarding":true}' > "$HOME/.claude.json"
fi

# Claude Code is installed at build time (Dockerfile.app).
# Background update so it doesn't block startup.
(claude install >/dev/null 2>&1 &)
EOF
			;;
		cursor)
			cat <<'EOF'
# Cursor auth uses the placeholder value from sandcat.env. The mitmproxy addon
# substitutes it with the real secret on allowed outbound Cursor requests.

# Apply Sandcat-managed Cursor CLI settings. mitmproxy merges settings.json
# `cursor.cli` at startup and writes /mitmproxy-config/cursor-cli-config.json;
# deep-merge that fragment into agent-home cli-config.json so Sandcat-owned
# keys win while other Cursor-written keys (model, permissions, etc.) persist.
# API keys belong in secrets.CURSOR_API_KEY — not cursor.cli or cli-config.json.
SANDCAT_CURSOR_CLI="/mitmproxy-config/cursor-cli-config.json"
if [ -f "$SANDCAT_CURSOR_CLI" ] && command -v jq >/dev/null 2>&1; then
    sandcat_cli="$(jq -c 'if type == "object" then . else {} end' "$SANDCAT_CURSOR_CLI" 2>/dev/null || echo '{}')"
    if [ "$sandcat_cli" != "{}" ] && [ -n "$sandcat_cli" ]; then
        for CURSOR_CLI_CONFIG in "$HOME/.config/cursor/cli-config.json" "$HOME/.cursor/cli-config.json"; do
            mkdir -p "$(dirname "$CURSOR_CLI_CONFIG")"
            if [ ! -s "$CURSOR_CLI_CONFIG" ]; then
                echo '{}' > "$CURSOR_CLI_CONFIG"
            fi
            tmp="$(mktemp)"
            if jq -s '.[0] * .[1]' "$CURSOR_CLI_CONFIG" <(echo "$sandcat_cli") > "$tmp"; then
                cat "$tmp" > "$CURSOR_CLI_CONFIG" \
                    || echo "Warning: failed to apply Sandcat cursor.cli to $CURSOR_CLI_CONFIG" >&2
            else
                echo "Warning: failed to merge Sandcat cursor.cli into $CURSOR_CLI_CONFIG" >&2
            fi
            rm -f "$tmp"
        done
    fi
else
    if [ -f "$SANDCAT_CURSOR_CLI" ]; then
        echo "Warning: jq not found; cannot apply Sandcat cursor.cli settings" >&2
    fi
fi
EOF
			;;
		*)
			echo ""
			;;
	esac
}
