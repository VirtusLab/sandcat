# Codex agent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add [OpenAI Codex CLI](https://github.com/openai/codex) as a third first-class agent in sandcat, alongside `claude` and `cursor`.

**Architecture:** Extend `sct_available_agents` to include `codex`; add a `codex)` arm to every `sct_agent_*` dispatcher in `cli/lib/agents.bash`; ship a settings template and a claude-style mitmproxy addon for OpenAI REST traffic; extend the rtk feature with a codex case (which works out of the box because codex config lives in the writable `agent-home` volume, unlike cursor's read-only `hooks.json`).

**Tech Stack:** Bash 5+, bats-core + bats-mock (existing test infra), Docker + Docker Compose, official `chatgpt.com/codex/install.sh`, Python mitmproxy addon wrapping `mitmproxy_addon_common.SandcatAddon`.

## Global Constraints

- Auth in this iteration is `OPENAI_API_KEY` only (secret-substituted at mitmproxy). No ChatGPT sign-in (`chatgpt.com`, `auth.openai.com`) is added to the allowlist.
- Codex install goes to `/usr/local/bin/codex` with `CODEX_HOME=/opt/codex-home` at build time only. `ENV` MUST NOT be used — it would leak into runtime; use inline `VAR=val` prefix on `sh` (not `curl`) so install.sh actually sees the env vars.
- Runtime `CODEX_HOME` remains unset — codex must read user config from `~/.codex/` (agent-home volume).
- Host mounts follow the claude pattern: `~/.codex/AGENTS.md`, `~/.codex/skills/`, `~/.codex/commands/` read-only. `config.toml`, `.credentials.json`, `history.jsonl`, `log/`, `packages/` stay in agent-home.
- `sct_agent_mitm_streaming_flags codex` returns empty — codex uses plain HTTP/1.1 REST + SSE, buffered body enables placeholder leak checks (claude-style).
- rtk hook idempotency guard for codex greps `~/.codex/config.toml` for the string `rtk hook codex` (matches what `rtk init --agent codex` writes).
- VS Code extension ID for codex: `openai.chatgpt`.
- Bash alias `codex-yolo="codex --yolo"` in `.bashrc`, matching the `claude-yolo` pattern.
- Unknown agents MUST continue returning empty output for every dispatcher (existing contract in `cli/test/agents/agents.bats` — do not regress).

---

### Task 1: Register codex + trivial case-arm dispatchers

**Files:**
- Modify: `cli/lib/agents.bash` — 8 case blocks
- Modify: `cli/test/agents/agents.bats` — 8 new tests

**Interfaces:**
- Consumes: nothing (foundation task).
- Produces:
  - `sct_available_agents` now emits `"claude cursor codex"`.
  - `sct_is_valid_agent codex` returns 0.
  - `sct_agent_mount_env_var codex` → `SANDCAT_MOUNT_CODEX_CONFIG`.
  - `sct_agent_api_key_help codex` → `OPENAI_API_KEY   your OpenAI API key (for Codex CLI)`.
  - `sct_agent_op_api_key_help codex` → `OPENAI_API_KEY   "op": "op://vault/OpenAI API Key/credential"`.
  - `sct_agent_vscode_extension codex` → `openai.chatgpt`.
  - `sct_agent_devcontainer_settings_block codex` → empty.
  - `sct_agent_compose_environment_entries codex` → empty.
  - `sct_agent_mitm_streaming_flags codex` → empty.
  - `sct_agent_post_user_settings_hook codex` → no-op (`return 0`).

- [ ] **Step 1: Add failing tests to `cli/test/agents/agents.bats`**

Update the existing `sct_available_agents` test and add 8 new tests. First update the existing one at line 22:

```bash
@test "sct_available_agents lists claude, cursor and codex" {
	run sct_available_agents
	assert_success
	assert_output "claude cursor codex"
}

@test "sct_is_valid_agent accepts codex" {
	run sct_is_valid_agent codex
	assert_success
}
```

Then append these tests to the appropriate sections (near existing claude/cursor tests for each dispatcher — grep the file for the current dispatcher name to find the right spot):

```bash
@test "sct_agent_mount_env_var: codex" {
	run sct_agent_mount_env_var codex
	assert_output "SANDCAT_MOUNT_CODEX_CONFIG"
}

@test "sct_agent_api_key_help: codex" {
	run sct_agent_api_key_help codex
	assert_output --partial "OPENAI_API_KEY"
	assert_output --partial "Codex CLI"
}

@test "sct_agent_op_api_key_help: codex" {
	run sct_agent_op_api_key_help codex
	assert_output --partial "OPENAI_API_KEY"
	assert_output --partial "op://vault/OpenAI API Key/credential"
}

@test "sct_agent_vscode_extension: codex" {
	run sct_agent_vscode_extension codex
	assert_output "openai.chatgpt"
}

@test "sct_agent_devcontainer_settings_block: codex returns empty" {
	run sct_agent_devcontainer_settings_block codex
	assert_output ""
}

@test "sct_agent_compose_environment_entries: codex returns empty" {
	run sct_agent_compose_environment_entries codex
	assert_output ""
}

@test "sct_agent_mitm_streaming_flags: codex returns empty" {
	run sct_agent_mitm_streaming_flags codex
	assert_output ""
}

@test "sct_agent_post_user_settings_hook: codex is a no-op" {
	# Should not fail even without any codex-specific helper defined.
	run sct_agent_post_user_settings_hook codex
	assert_success
	assert_output ""
}
```

Also update the existing "sct_is_valid_agent rejects unknown agent" — the assertion stays green (unknown ≠ codex), no change needed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: FAIL — 9 new tests fail because codex isn't wired yet.

- [ ] **Step 3: Modify `cli/lib/agents.bash`**

**Edit A** — change `sct_available_agents` at line 7:

```bash
sct_available_agents() {
	echo "claude cursor codex"
}
```

**Edit B** — add `codex)` arm to `sct_agent_mount_env_var` (~line 40):

```bash
sct_agent_mount_env_var() {
	local agent=$1
	case "$agent" in
		claude) echo "SANDCAT_MOUNT_CLAUDE_CONFIG" ;;
		cursor) echo "SANDCAT_MOUNT_CURSOR_CONFIG" ;;
		codex)  echo "SANDCAT_MOUNT_CODEX_CONFIG"  ;;
		*)      echo "" ;;
	esac
}
```

**Edit C** — add `codex)` arm to `sct_agent_api_key_help` (~line 179):

```bash
sct_agent_api_key_help() {
	local agent=$1
	case "$agent" in
		claude) echo "ANTHROPIC_API_KEY  your Anthropic API key (for Claude Code)" ;;
		cursor) echo "CURSOR_API_KEY     your Cursor API key (for Cursor CLI)" ;;
		codex)  echo "OPENAI_API_KEY     your OpenAI API key (for Codex CLI)" ;;
		*)      echo "ANTHROPIC_API_KEY  API key for your selected agent" ;;
	esac
}
```

**Edit D** — restructure `sct_agent_op_api_key_help` (~line 193) so `codex` gets a distinct arm and the `claude|*)` fallthrough is preserved:

```bash
sct_agent_op_api_key_help() {
	local agent=$1
	case "$agent" in
		cursor)
			echo "CURSOR_API_KEY     \"op\": \"op://vault/Cursor API Key/credential\""
			;;
		codex)
			echo "OPENAI_API_KEY     \"op\": \"op://vault/OpenAI API Key/credential\""
			;;
		claude|*)
			echo "ANTHROPIC_API_KEY  \"op\": \"op://vault/Anthropic API Key/credential\""
			;;
	esac
}
```

**Edit E** — add `codex)` arm to `sct_agent_post_user_settings_hook` (~line 215):

```bash
sct_agent_post_user_settings_hook() {
	local agent=$1
	case "$agent" in
		cursor)
			if declare -F ensure_cursor_user_settings_defaults >/dev/null; then
				ensure_cursor_user_settings_defaults
			fi
			;;
		codex)
			return 0
			;;
		*)
			return 0
			;;
	esac
}
```

**Edit F** — add `codex)` arm to `sct_agent_vscode_extension` (~line 232):

```bash
sct_agent_vscode_extension() {
	local agent=$1
	case "$agent" in
		claude) echo "anthropic.claude-code" ;;
		cursor) echo "anysphere.cursor" ;;
		codex)  echo "openai.chatgpt"       ;;
		*)      echo "" ;;
	esac
}
```

**Edit G** — add `codex)` arm to `sct_agent_devcontainer_settings_block` (~line 244):

```bash
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
		codex)
			# No forced VS Code settings for codex in this iteration.
			echo ""
			;;
		*)
			echo ""
			;;
	esac
}
```

**Edit H** — restructure `sct_agent_compose_environment_entries` (~line 279) so `codex` returns empty explicitly:

```bash
sct_agent_compose_environment_entries() {
	local agent=$1
	case "$agent" in
		claude)
			echo "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
			;;
		cursor|codex|*)
			echo ""
			;;
	esac
}
```

**Edit I** — restructure `sct_agent_mitm_streaming_flags` (~line 357) so `codex` returns empty explicitly (claude-style):

```bash
sct_agent_mitm_streaming_flags() {
	local agent=$1
	case "$agent" in
		cursor)
			echo "--set stream_large_bodies=1m --set connection_strategy=lazy --set anticomp=true --set timeout_read=300"
			;;
		claude|codex|*)
			echo ""
			;;
	esac
}
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: PASS (all existing + 9 new)

- [ ] **Step 5: Run full suite for regression check**

Run: `cd cli && ./run-tests.bash`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): register codex agent + trivial dispatcher arms"
```

---

### Task 2: Host config paths + ensure_host_agent_config_paths for codex

**Files:**
- Modify: `cli/lib/agents.bash` — `sct_agent_host_config_paths`
- Modify: `cli/test/agents/agents.bats` — 3 new tests

**Interfaces:**
- Consumes: `sct_agent_mount_env_var codex` = `SANDCAT_MOUNT_CODEX_CONFIG` (Task 1).
- Produces:
  - `sct_agent_host_config_paths codex` emits: `$HOME/.codex/AGENTS.md`, `$HOME/.codex/skills/`, `$HOME/.codex/commands/` (each on its own line, matching the existing claude convention).
  - `ensure_host_agent_config_paths codex "<project-name>"` creates those paths on the host with empty content when missing (uses existing `_ensure_host_agent_config_file` fallback for markdown files).

- [ ] **Step 1: Add failing tests to `cli/test/agents/agents.bats`**

Add near the existing `sct_agent_host_config_paths: cursor lists ...` test:

```bash
@test "sct_agent_host_config_paths: codex lists ~/.codex entries" {
	run sct_agent_host_config_paths codex
	assert_output --partial '$HOME/.codex/AGENTS.md'
	assert_output --partial '$HOME/.codex/skills/'
	assert_output --partial '$HOME/.codex/commands/'
	refute_output --partial '$HOME/.codex/config.toml'
	refute_output --partial '$HOME/.codex/.credentials.json'
}

@test "ensure_host_agent_config_paths: creates codex paths under HOME" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"

	export SANDCAT_MOUNT_CODEX_CONFIG=true
	ensure_host_agent_config_paths codex

	[[ -d "$HOME/.codex/skills" ]]
	[[ -d "$HOME/.codex/commands" ]]
	[[ -f "$HOME/.codex/AGENTS.md" ]]
}

@test "ensure_host_agent_config_paths: codex opt-out via SANDCAT_MOUNT_CODEX_CONFIG=false" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"

	export SANDCAT_MOUNT_CODEX_CONFIG=false
	ensure_host_agent_config_paths codex

	# Nothing should have been created on the host.
	[[ ! -d "$HOME/.codex" ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: FAIL — 3 new tests fail (codex arm missing in host_config_paths).

- [ ] **Step 3: Modify `cli/lib/agents.bash`**

Add `codex)` arm to `sct_agent_host_config_paths` (~line 64):

```bash
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
		codex)
			cat <<'EOF'
$HOME/.codex/skills/
$HOME/.codex/commands/
$HOME/.codex/AGENTS.md
EOF
			;;
		*)
			echo ""
			;;
	esac
}
```

`_ensure_host_agent_config_file` already has a `*)` default (line 133-135) that creates empty files. That is fine for codex's `AGENTS.md`. No change needed to that helper.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): declare codex host config mount paths"
```

---

### Task 3: Docker install block for codex

**Files:**
- Modify: `cli/lib/agents.bash` — `sct_agent_docker_install_block`
- Modify: `cli/test/agents/agents.bats` — 3 new tests

**Interfaces:**
- Consumes: nothing new.
- Produces: `sct_agent_docker_install_block codex` emits Dockerfile lines that install codex to `/usr/local/bin` with `CODEX_HOME=/opt/codex-home` (at install time only) so the resolved symlink target survives the agent-home volume mask.

- [ ] **Step 1: Add failing tests to `cli/test/agents/agents.bats`**

Near existing `sct_agent_docker_install_block: cursor installs cursor cli`:

```bash
@test "sct_agent_docker_install_block: codex installs codex to /usr/local/bin" {
	unset SANDCAT_RTK
	run sct_agent_docker_install_block codex
	assert_output --partial "chatgpt.com/codex/install.sh"
	assert_output --partial "CODEX_INSTALL_DIR=/usr/local/bin"
	assert_output --partial "CODEX_HOME=/opt/codex-home"
	assert_output --partial "USER root"
	assert_output --partial "USER vscode"
	# Env vars must be inline on `sh` (not `ENV`) — otherwise CODEX_HOME
	# would leak to runtime.
	refute_output --partial "ENV CODEX_HOME"
	refute_output --partial "ENV CODEX_INSTALL_DIR"
}

@test "sct_agent_docker_install_block: codex append rtk install when enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_docker_install_block codex
	assert_output --partial "chatgpt.com/codex/install.sh"
	assert_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}

@test "sct_agent_docker_install_block: codex skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_docker_install_block codex
	assert_output --partial "chatgpt.com/codex/install.sh"
	refute_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: FAIL — 3 new tests fail (codex arm missing in docker_install_block).

- [ ] **Step 3: Modify `cli/lib/agents.bash`**

Add `codex)` arm to `sct_agent_docker_install_block` (~line 294) BEFORE the `*)` return:

```bash
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
		codex)
			cat <<'EOF'
# Install Codex CLI (OpenAI). CODEX_INSTALL_DIR + CODEX_HOME point at
# system paths only for the install.sh invocation so the resolved
# symlink target survives the agent-home volume mask on upgrade.
# Env vars go on the `sh` end of the pipe (not `curl`) so install.sh
# actually sees them; using inline `VAR=val` (not `ENV`) keeps them
# out of the image environment — at runtime CODEX_HOME is unset and
# codex reads user config from ~/.codex/ (agent-home, per-sandbox).
USER root
RUN curl -fsSL https://chatgpt.com/codex/install.sh | \
    CODEX_INSTALL_DIR=/usr/local/bin CODEX_HOME=/opt/codex-home sh
USER vscode
EOF
			;;
		*)
			return 0
			;;
	esac
	sct_rtk_docker_install_block
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): install codex to /usr/local/bin with build-time CODEX_HOME"
```

---

### Task 4: Docker home prep + user init blocks for codex

**Files:**
- Modify: `cli/lib/agents.bash` — `sct_agent_docker_home_prep_block`, `sct_agent_user_init_block`
- Modify: `cli/test/agents/agents.bats` — 4 new tests

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `sct_agent_docker_home_prep_block codex` emits `mkdir -p /home/vscode/.codex` + `codex-yolo` bash alias.
  - `sct_agent_user_init_block codex` emits a `codex --version` health check (non-fatal on failure), then `sct_rtk_user_init_block codex` appended after `esac`.

- [ ] **Step 1: Add failing tests to `cli/test/agents/agents.bats`**

Near existing home-prep and user-init tests:

```bash
@test "sct_agent_docker_home_prep_block: codex pre-creates ~/.codex and codex-yolo alias" {
	run sct_agent_docker_home_prep_block codex
	assert_output --partial "/home/vscode/.codex"
	assert_output --partial 'alias codex-yolo="codex --yolo"'
}

@test "sct_agent_user_init_block: codex runs version health check" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block codex
	assert_output --partial "codex --version"
	assert_output --partial "non-fatal"
}

@test "sct_agent_user_init_block: codex appends rtk init when enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block codex
	assert_output --partial "codex --version"
	assert_output --partial "rtk init -g --hook-only --auto-patch --agent codex"
}

@test "sct_agent_user_init_block: codex skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_user_init_block codex
	assert_output --partial "codex --version"
	refute_output --partial "rtk init"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: FAIL — 4 new tests fail.

- [ ] **Step 3: Modify `cli/lib/agents.bash`**

Add `codex)` arm to `sct_agent_docker_home_prep_block` (~line 319):

```bash
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
		codex)
			cat <<'EOF'
# Pre-create ~/.codex so Docker bind-mounts (AGENTS.md, skills/, commands/)
# don't cause it to be created as root-owned.
RUN mkdir -p /home/vscode/.codex
RUN echo 'alias codex-yolo="codex --yolo"' >> /home/vscode/.bashrc
EOF
			;;
		*)
			echo ""
			;;
	esac
}
```

Add `codex)` arm to `sct_agent_user_init_block` (~line 372) BEFORE the `*)` return:

```bash
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
		codex)
			cat <<'EOF'
# Codex CLI is installed at build time (Dockerfile.app). Codex reads
# $OPENAI_API_KEY directly from the environment — sandcat.env has already
# been sourced with the placeholder or 1Password-resolved value.
# Basic health check on first start; failure is non-fatal.
if command -v codex >/dev/null 2>&1; then
    codex --version >/dev/null 2>&1 \
        || echo "sandcat: codex --version failed (non-fatal)" >&2
fi
EOF
			;;
		*)
			return 0
			;;
	esac
	sct_rtk_user_init_block "$agent"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): codex Dockerfile home prep + user-init health check"
```

---

### Task 5: Settings template for codex

**Files:**
- Create: `cli/templates/settings-user-codex.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a settings template file that `create_user_settings` in `cli/libexec/init/init` will copy on first init when `--agent codex` is selected. Contains `OPENAI_API_KEY` secret placeholder and a network allowlist scoped to `api.openai.com` + GitHub.

There are no unit tests directly for the template file — its content is verified end-to-end by `cli/test/init/init.bats` (via `create_user_settings` → template lookup by `user_settings_template_path`). If the file is missing, init errors out with `Missing user settings template for agent 'codex'`, which is a natural failing signal in later tasks. This task therefore skips its own bats test.

- [ ] **Step 1: Create `cli/templates/settings-user-codex.json`**

```json
{
  "env": {},
  "secrets": {
    "OPENAI_API_KEY": {
      "value": "",
      "hosts": ["api.openai.com"]
    },
    "GITHUB_TOKEN": {
      "value": "",
      "hosts": ["github.com", "*.github.com", "*.githubusercontent.com"]
    }
  },
  "network": [
    {"action": "allow", "host": "*.github.com"},
    {"action": "allow", "host": "github.com"},
    {"action": "allow", "host": "*.githubusercontent.com"},
    {"action": "allow", "host": "api.openai.com"}
  ]
}
```

- [ ] **Step 2: Validate JSON**

Run: `jq empty cli/templates/settings-user-codex.json`
Expected: exit 0, no output. Any JSON syntax error surfaces here.

- [ ] **Step 3: Commit**

```bash
git add cli/templates/settings-user-codex.json
git commit -m "feat(cli): settings template for codex agent (OPENAI_API_KEY + api.openai.com)"
```

---

### Task 6: mitmproxy addon for codex + dispatch

**Files:**
- Create: `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_codex.py`
- Modify: `cli/lib/devcontainer.bash` — dispatch around line 195 that picks the addon file per agent

**Interfaces:**
- Consumes: `mitmproxy_addon_common.SandcatAddon` (existing shared module — no changes).
- Produces:
  - `mitmproxy_addon_codex.py` — thin wrapper file loaded by mitmweb via `-s /scripts/mitmproxy_addon_codex.py`.
  - Devcontainer emission for `--agent codex` now uses `mitm_addon_file="mitmproxy_addon_codex.py"` and `mitm_http2="true"`.

- [ ] **Step 1: Create `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_codex.py`**

```python
"""
Codex-focused mitmproxy addon: network access rules and secret substitution.

Loaded via: mitmweb -s /scripts/mitmproxy_addon_codex.py

This is a thin wrapper around the shared :mod:`mitmproxy_addon_common`
library. Codex uses OpenAI's REST API (Chat Completions endpoint, plain
JSON with SSE streaming on the response) — the default buffered-body
behaviour of the base ``SandcatAddon`` class is sufficient, and buffering
enables the placeholder leak check that the common addon runs on request
payloads.

On startup, reads settings from up to three layers (lowest to highest
precedence): user (``~/.config/sandcat/settings.json``), project
(``.sandcat/settings.json``), and local (``.sandcat/settings.local.json``).
Env vars and secrets are merged (higher precedence wins on conflict).
Network rules are concatenated (highest precedence first).

Network rules are evaluated top-to-bottom, first match wins, default deny.
Secret placeholders are replaced with real values only for allowed hosts.
"""

from mitmproxy_addon_common import SandcatAddon

addons = [SandcatAddon()]
```

- [ ] **Step 2: Locate and update dispatch in `cli/lib/devcontainer.bash`**

Find the existing `case "$agent" in` block that maps agent → mitm addon file (grep: `grep -n 'mitmproxy_addon_' cli/lib/devcontainer.bash | head`). Replace it with a version that includes codex:

```bash
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
```

- [ ] **Step 3: Add a bats test if `cli/test/devcontainer/` exists**

Check first: `ls cli/test/devcontainer/ 2>/dev/null`. If the directory exists with existing tests for the compose/devcontainer emission, add a test asserting that with `agent=codex` the emitted config references `mitmproxy_addon_codex.py`. If no such test infrastructure exists (only static file tests), skip this step — the integration test in Task 10 covers it.

- [ ] **Step 4: Run full suite as a regression check**

Run: `cd cli && ./run-tests.bash`
Expected: PASS (no regressions; new file is not directly unit-tested here).

- [ ] **Step 5: Commit**

```bash
git add cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_codex.py cli/lib/devcontainer.bash
git commit -m "feat(cli): mitmproxy addon for codex + devcontainer dispatch"
```

---

### Task 7: rtk case for codex

**Files:**
- Modify: `cli/lib/rtk.bash` — `sct_rtk_user_init_block`
- Modify: `cli/test/rtk/rtk.bats` — 2 new tests

**Interfaces:**
- Consumes: `sct_rtk_enabled` (existing).
- Produces: `sct_rtk_user_init_block codex` emits a guarded `rtk init -g --hook-only --auto-patch --agent codex`; empty when disabled or the hook is already in `~/.codex/config.toml`.

- [ ] **Step 1: Add failing tests to `cli/test/rtk/rtk.bats`**

Append at end (after existing cursor tests):

```bash
@test "sct_rtk_user_init_block: codex emits guarded rtk init --agent codex" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block codex
	assert_success
	assert_output --partial "rtk init -g"
	assert_output --partial "--hook-only"
	assert_output --partial "--auto-patch"
	assert_output --partial "--agent codex"
	assert_output --partial "command -v rtk"
	assert_output --partial "rtk hook codex"
	assert_output --partial ".codex/config.toml"
	assert_output --partial "non-fatal"
}

@test "sct_rtk_user_init_block: codex emits nothing when disabled" {
	SANDCAT_RTK=false run sct_rtk_user_init_block codex
	assert_success
	assert_output ""
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: FAIL — 2 new tests fail; the "disabled" one accidentally passes because the current `*)` returns empty, but the "emits guarded" test fails.

- [ ] **Step 3: Modify `cli/lib/rtk.bash`**

Add `codex)` arm to `sct_rtk_user_init_block` — insert between the `cursor)` and `*)` arms:

```bash
		codex)
			cat <<'EOF'
# rtk (Rust Token Killer) — one-time hook config for Codex CLI.
# `rtk init -g --hook-only --auto-patch --agent codex` patches
# ~/.codex/config.toml with the rtk hook. ~/.codex/ lives in the
# agent-home volume (not bind-mounted), so init runs and persists
# out of the box — unlike cursor's read-only hooks.json.
# Idempotency: skipped once the hook string is already present.
if command -v rtk >/dev/null 2>&1 && ! grep -q 'rtk hook codex' "$HOME/.codex/config.toml" 2>/dev/null; then
    rtk init -g --hook-only --auto-patch --agent codex >/dev/null 2>&1 \
        || echo "sandcat: rtk init failed (non-fatal)" >&2
fi
EOF
			;;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: PASS

- [ ] **Step 5: Run full suite for regression check**

Run: `cd cli && ./run-tests.bash`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add cli/lib/rtk.bash cli/test/rtk/rtk.bats
git commit -m "feat(cli): rtk auto-init for codex (works out of the box)"
```

---

### Task 8: init.bats stub updates + codex init tests

**Files:**
- Modify: `cli/test/init/init.bats`

**Interfaces:**
- Consumes: everything wired in Tasks 1-7 is now visible to the init CLI.
- Produces: `cli/test/init/init.bats` verifies that `--agent codex` works end-to-end, hosts paths are pre-created / not pre-created based on `SANDCAT_MOUNT_CODEX_CONFIG`, and interactive picker stubs still pattern-match with the new agent option.

- [ ] **Step 1: Locate all stubs that need updating**

Interactive tests that stub `select_option` for `Select agent:` need `codex` appended to the accepted values so the pattern match still works. Grep to find them:

```bash
grep -n "'Select agent:' claude cursor" cli/test/init/init.bats
```

Every match's line becomes `'Select agent:' claude cursor codex : echo <chosen>`.

- [ ] **Step 2: Add failing tests + update stubs in `cli/test/init/init.bats`**

Update every existing occurrence of the `Select agent:` stub to include `codex`. For example:

```bash
	stub select_option \
		"'Select agent:' claude cursor codex : echo claude" \
		...
```

Then append these new tests (near existing `init accepts cursor as valid --agent value` — grep to find location):

```bash
@test "init accepts codex as valid --agent value" {
	stub settings \
		"$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
}

@test "init pre-creates host paths for codex config mount" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	# Directories/files pre-created so Docker won't materialise them as root-owned.
	[[ -d "$HOME/.codex/skills" ]]
	[[ -d "$HOME/.codex/commands" ]]
	[[ -f "$HOME/.codex/AGENTS.md" ]]
}

@test "init skips host pre-creation when SANDCAT_MOUNT_CODEX_CONFIG=false" {
	export SANDCAT_MOUNT_CODEX_CONFIG=false

	stub settings "$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success

	[[ ! -d "$HOME/.codex" ]]
}

@test "init summary for codex mentions OPENAI_API_KEY" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json codex vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent codex --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent codex --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --proxy web --features "" --secret-provider none
	assert_success
	assert_output --partial "OPENAI_API_KEY"
	assert_output --partial "Codex CLI"
}
```

- [ ] **Step 3: Run tests to verify all pass**

Run: `cd cli && ./run-tests.bash test/init/init.bats`
Expected: PASS (existing tests still green thanks to stub updates; new codex tests green because Tasks 1-4 wired everything).

- [ ] **Step 4: Run full suite for regression check**

Run: `cd cli && ./run-tests.bash`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add cli/test/init/init.bats
git commit -m "test(cli): cover codex init flow + update select_option stubs"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md`
- Modify: `cli/README.md`

**Interfaces:** None — pure documentation.

- [ ] **Step 1: Update `README.md`**

**Edit A** — update the "Available stacks" and "Selecting scala" area of the "Initialize the sandbox" section to reference codex. Grep for the sentence that lists agents (e.g. `--agent claude|cursor`) and add `codex`.

**Edit B** — in the section listing agents (look for the existing paragraph that starts with "Available agents" or similar, near the `--agent` documentation), add codex to the list with a one-liner: `codex (OpenAI Codex CLI — https://github.com/openai/codex)`.

**Edit C** — add a new subsection under "Initialize the sandbox for your project" (mirror the structure of the cursor documentation) titled "Codex CLI". Content:

```markdown
##### Codex CLI (`--agent codex`)

Sandcat installs [OpenAI's Codex CLI](https://github.com/openai/codex)
into every codex-agent sandbox and wires `OPENAI_API_KEY` through the
mitmproxy secret substitution layer. Codex reads its config from
`~/.codex/config.toml` (per-sandbox, agent-home volume) and picks up
the API key directly from the environment — no `codex login` required.

**Setup:**

```bash
sandcat init --agent codex --ide vscode
# Edit ~/.config/sandcat/settings.json — set secrets.OPENAI_API_KEY.value
sandcat run
codex "explain this codebase"
```

**Bash alias:** `codex-yolo` (= `codex --yolo`) is available in every
codex sandbox for parity with `claude-yolo`.

**Host config sharing** (optional, default on): `~/.codex/AGENTS.md`,
`~/.codex/skills/`, and `~/.codex/commands/` are bind-mounted read-only
from the host into the container, matching how `~/.claude/` is handled.
The rest of `~/.codex/` (config.toml, credentials, history) lives in
the container's agent-home volume — per-sandbox persistent, per-sandbox
isolated. Opt out with `SANDCAT_MOUNT_CODEX_CONFIG=false`.

**RTK integration:** the rtk hook auto-installs for codex on first
container start; unlike cursor's host-side workflow, codex's
`~/.codex/config.toml` is writable inside the sandbox so
`rtk init --agent codex` succeeds immediately.

**Auth model:** first iteration supports `OPENAI_API_KEY` only.
ChatGPT sign-in (`chatgpt.com` / `auth.openai.com`) is not in the
default allowlist — users who want that flow can add the hosts to
`.sandcat/settings.local.json` and run `codex login` manually inside
the container.
```

**Edit D** — env-var table: add row for `SANDCAT_MOUNT_CODEX_CONFIG` next to the existing `SANDCAT_MOUNT_CURSOR_CONFIG` row. Grep for `SANDCAT_MOUNT_CURSOR_CONFIG` to find the table.

- [ ] **Step 2: Update `cli/README.md`**

Grep for `--agent` documentation. Update the accepted-values list from `claude, cursor` to `claude, cursor, codex`.

- [ ] **Step 3: Commit**

```bash
git add README.md cli/README.md
git commit -m "docs: document codex agent (setup, host mounts, rtk, auth)"
```

---

### Task 10: Hands-on integration verification

**Files:** None (manual verification; results reported to the user)

**Interfaces:** None.

Each scenario runs against a real Docker sandbox. Use a scratch project under `/tmp/sandcat-codex-integ.XXXX`. `$SANDCAT` is `/Users/seweryn.hejnowicz/projects/sandcat/cli/bin/sandcat`.

- [ ] **Scenario 1 — Fresh install path**

```bash
SANDCAT=/Users/seweryn.hejnowicz/projects/sandcat/cli/bin/sandcat
TEST_ROOT=$(mktemp -d /tmp/sandcat-codex-integ.XXXX)
cd "$TEST_ROOT" && mkdir proj-default && cd proj-default && git init -q
"$SANDCAT" init \
    --agent codex --ide vscode --name codex-default --path . \
    --stacks "" --secret-provider none --features "" --proxy web
```

Expected in output: `RTK: installed (disable with --features no-rtk)`.

Then:

```bash
"$SANDCAT" run --build -- bash -c '
    command -v codex             # → /usr/local/bin/codex
    codex --version              # → version string
    ls -la /usr/local/bin/codex  # symlink target should be under /opt/codex-home
    echo $CODEX_HOME             # empty at runtime (not leaked from build)
'
```

- [ ] **Scenario 2 — rtk hook auto-init**

Same project. After the first `sandcat run --build`:

```bash
"$SANDCAT" run -- bash -c '
    cat ~/.codex/config.toml | grep -A2 "rtk hook codex"
'
```

Expected: hook entry present.

Restart without rebuild:

```bash
"$SANDCAT" run -- bash -c 'sha256sum ~/.codex/config.toml'
"$SANDCAT" run -- bash -c 'sha256sum ~/.codex/config.toml'
```

Expected: identical hashes across the two runs — guard blocks re-init.

- [ ] **Scenario 3 — codex-yolo alias**

```bash
"$SANDCAT" run -- bash -lc 'type codex-yolo'
```

Expected: `codex-yolo is aliased to 'codex --yolo'` (login shell exposes the alias via `.bashrc`).

- [ ] **Scenario 4 — Host mount pre-creation**

Ensure host `~/.codex/` files exist after `sandcat init` (the test project just used its own PROJECT_DIR, but init still pre-creates host mounts for the running user's `$HOME`):

```bash
ls -la "$HOME/.codex/AGENTS.md" "$HOME/.codex/skills/" "$HOME/.codex/commands/"
```

Expected: all three exist (created with empty content / empty dirs).

In the container, verify they are bind-mounted read-only:

```bash
"$SANDCAT" run -- bash -c '
    ls -la ~/.codex/AGENTS.md
    touch ~/.codex/AGENTS.md 2>&1 || echo "correctly read-only"
'
```

Expected: `touch` fails with EROFS or permission denied.

- [ ] **Scenario 5 — Opt-out from host mount**

```bash
cd "$TEST_ROOT" && mkdir proj-optout && cd proj-optout && git init -q
SANDCAT_MOUNT_CODEX_CONFIG=false "$SANDCAT" init \
    --agent codex --ide vscode --name codex-optout --path . \
    --stacks "" --secret-provider none --features "" --proxy web

"$SANDCAT" run --build -- bash -c '
    # No bind mount → ~/.codex/AGENTS.md should not exist (agent-home is empty
    # for that path)
    [ -e ~/.codex/AGENTS.md ] && echo "unexpected: present" || echo "OK: not mounted"
'
```

- [ ] **Scenario 6 — Regression: claude and cursor still work**

Two more scratch projects:

```bash
cd "$TEST_ROOT" && mkdir proj-claude && cd proj-claude && git init -q
"$SANDCAT" init --agent claude --ide none --name codex-regress-claude --path . \
    --stacks "" --secret-provider none --features "" --proxy web
"$SANDCAT" run --build -- bash -c 'command -v claude'

cd "$TEST_ROOT" && mkdir proj-cursor && cd proj-cursor && git init -q
"$SANDCAT" init --agent cursor --ide none --name codex-regress-cursor --path . \
    --stacks "" --secret-provider none --features "" --proxy web
"$SANDCAT" run --build -- bash -c 'command -v cursor-agent || command -v cursor'
```

Expected: both continue installing their respective agent binaries. Registering codex did not regress claude or cursor.

- [ ] **Cleanup**

```bash
for p in codex-default codex-optout codex-regress-claude codex-regress-cursor; do
    docker compose -p "$p" down -v 2>/dev/null || true
done
rm -rf "$TEST_ROOT"
```

- [ ] **If all scenarios pass, no commit needed.** If any scenario fails, do NOT proceed to PR. Root-cause and fix; the fix goes into the task whose deliverable caused the failure.

---

## Post-implementation

After Task 10 succeeds:

1. Rebase onto latest `origin/master` (in case of concurrent merges).
2. Run the full test suite one final time.
3. Push the branch and open a PR — title `feat(cli): add codex as third supported agent`. Body follows the pattern from PR #83 (Summary / Design notes / Test plan with all scenarios checked).
