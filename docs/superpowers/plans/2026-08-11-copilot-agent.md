# GitHub Copilot Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `copilot` as a fourth first-class sandcat agent (alongside claude/cursor/codex), so `sandcat init --agent copilot ...` produces a working, network-isolated, secret-substituting sandbox for the `@github/copilot` CLI.

**Architecture:** Fork the Codex-integration pattern from PR#87. Every per-agent case statement in `cli/lib/agents.bash` gets a `copilot` branch; new user-settings template + mitmproxy addon file; Node.js 22 + `@github/copilot` npm package installed at Dockerfile build time; VS Code extensions `GitHub.copilot` and `GitHub.copilot-chat` added to devcontainer.json when IDE is vscode. Placeholder substitution model (env `COPILOT_GITHUB_TOKEN=SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN` → mitmproxy swap in Authorization header) is byte-for-byte identical to Codex/Claude.

**Tech Stack:** bash + yq for CLI, Node.js 22 (via NodeSource) + `@github/copilot` npm package at Dockerfile build, mitmproxy Python addon (thin wrapper on SandcatAddon), bats for CLI tests.

## Global Constraints

- Agent name in `sct_available_agents`: `copilot` (space-separated addition to `"claude cursor codex"`).
- Secret name: `COPILOT_GITHUB_TOKEN`. Placeholder: `SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN`. Hosts allowlist: `["api.github.com", "*.github.com", "*.githubcopilot.com", "*.githubusercontent.com"]`.
- Install path: NodeSource `setup_22.x` + `npm install -g @github/copilot` — under `USER root`, with `USER vscode` restored before block ends.
- Config directory: `~/.copilot/` (host: `$HOME/.copilot/`). Optional bind-mount gated by env var `SANDCAT_MOUNT_COPILOT_CONFIG` (default true — matches other agents). Sub-paths bind read-only: `mcp-config.json`, `session-state/`.
- VS Code extensions in devcontainer.json when `ide=vscode`: `GitHub.copilot`, `GitHub.copilot-chat`.
- mitmproxy addon file: `mitmproxy_addon_copilot.py` — thin wrapper `addons = [SandcatAddon()]`, no streaming flags initially. Task 6 verifies; if SSE breaks, revisit.
- No RTK integration in v1: `sct_rtk_user_init_block copilot` falls through to `*)` no-op, same as codex.
- Backwards compat: existing agents unchanged, absent-`copilot` project init unchanged.

---

### Task 1: Add `copilot` to the agents registry + basic dispatchers

**Files:**
- Modify: `cli/lib/agents.bash`
- Test: `cli/test/agents/agents.bats`

**Interfaces:**
- Consumes: nothing new (existing dispatcher pattern).
- Produces:
  - `sct_available_agents` returns `"claude cursor codex copilot"`.
  - `sct_is_valid_agent copilot` returns 0.
  - `sct_agent_mount_env_var copilot` echoes `SANDCAT_MOUNT_COPILOT_CONFIG`.
  - `sct_agent_host_config_paths copilot` echoes `$HOME/.copilot/mcp-config.json` and `$HOME/.copilot/session-state/` (one per line).
  - `sct_agent_api_key_help copilot` echoes `COPILOT_GITHUB_TOKEN  fine-grained GitHub PAT with "Copilot Requests" permission (or $(gh auth token))`.
  - `sct_agent_op_api_key_help copilot` echoes 1Password ref example.
  - `sct_agent_post_user_settings_hook copilot` no-ops (return 0).

- [ ] **Step 1: Write the failing tests**

Append to `cli/test/agents/agents.bats`:

```bash
@test "sct_available_agents includes copilot" {
	run sct_available_agents
	assert_success
	assert_output --partial "copilot"
}

@test "sct_is_valid_agent accepts copilot" {
	run sct_is_valid_agent copilot
	assert_success
}

@test "sct_agent_mount_env_var returns SANDCAT_MOUNT_COPILOT_CONFIG for copilot" {
	run sct_agent_mount_env_var copilot
	assert_success
	assert_output "SANDCAT_MOUNT_COPILOT_CONFIG"
}

@test "sct_agent_host_config_paths returns copilot paths" {
	run sct_agent_host_config_paths copilot ""
	assert_success
	assert_line --partial ".copilot/mcp-config.json"
	assert_line --partial ".copilot/session-state/"
}

@test "sct_agent_api_key_help returns COPILOT_GITHUB_TOKEN line" {
	run sct_agent_api_key_help copilot
	assert_success
	assert_output --partial "COPILOT_GITHUB_TOKEN"
	assert_output --partial "Copilot Requests"
}

@test "sct_agent_op_api_key_help returns 1Password ref for copilot" {
	run sct_agent_op_api_key_help copilot
	assert_success
	assert_output --partial 'COPILOT_GITHUB_TOKEN'
	assert_output --partial 'op://vault'
}

@test "sct_agent_post_user_settings_hook copilot is a no-op" {
	run sct_agent_post_user_settings_hook copilot
	assert_success
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./support/bats/bin/bats test/agents/agents.bats -f "copilot"`
Expected: FAIL — copilot not yet registered.

- [ ] **Step 3: Implement in `cli/lib/agents.bash`**

Replace `sct_available_agents`:

```bash
sct_available_agents() {
	echo "claude cursor codex copilot"
}
```

Add `copilot)` cases to:
- `sct_agent_mount_env_var` → `echo "SANDCAT_MOUNT_COPILOT_CONFIG"`
- `sct_agent_host_config_paths` (heredoc):
  ```bash
  copilot)
      cat <<'EOF'
  $HOME/.copilot/mcp-config.json
  $HOME/.copilot/session-state/
  EOF
      ;;
  ```
- `sct_agent_api_key_help` → `echo 'COPILOT_GITHUB_TOKEN  fine-grained GitHub PAT with "Copilot Requests" permission (or $(gh auth token))'`
- `sct_agent_op_api_key_help` → `echo 'COPILOT_GITHUB_TOKEN  "op": "op://vault/GitHub Copilot Token/credential"'`
- `sct_agent_post_user_settings_hook`: fall through to `*)` no-op — no explicit case needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./support/bats/bin/bats test/agents/agents.bats -f "copilot"`
Expected: PASS (7/7).

- [ ] **Step 5: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): register copilot in agents dispatcher + basic hooks"
```

---

### Task 2: VS Code extensions + mitmproxy addon + docker environment

**Files:**
- Modify: `cli/lib/agents.bash` (continued)
- Test: `cli/test/agents/agents.bats` (continued)

**Interfaces:**
- Consumes: Task 1's dispatcher plumbing.
- Produces:
  - `sct_agent_vscode_extension copilot` returns `"GitHub.copilot GitHub.copilot-chat"` (two extensions, space-separated — the existing consumers already handle multi-token output for stacks; verify by inspecting the caller).
  - `sct_agent_devcontainer_settings_block copilot` empty output (no forced VS Code settings).
  - `sct_agent_compose_environment_entries copilot` empty output.
  - `sct_agent_mitm_streaming_flags copilot` empty output (default buffered, verified in Task 6).

- [ ] **Step 1: Check whether `sct_agent_vscode_extension` callers accept multi-token output**

Read `cli/lib/devcontainer.bash` and `cli/libexec/init/devcontainer` — grep for `sct_agent_vscode_extension` and see if consumers iterate over the output as a list or treat it as a single extension ID. If single-ID only, change plan to `GitHub.copilot` only (chat extension omitted; user can add manually) and document that choice in the report.

- [ ] **Step 2: Write the failing tests**

Append to `cli/test/agents/agents.bats`:

```bash
@test "sct_agent_vscode_extension returns GitHub.copilot for copilot" {
	run sct_agent_vscode_extension copilot
	assert_success
	assert_output --partial "GitHub.copilot"
}

@test "sct_agent_devcontainer_settings_block for copilot is empty" {
	run sct_agent_devcontainer_settings_block copilot
	assert_success
	# Empty output — no forced settings.
	[ -z "$output" ]
}

@test "sct_agent_compose_environment_entries for copilot is empty" {
	run sct_agent_compose_environment_entries copilot
	assert_success
	[ -z "$output" ]
}

@test "sct_agent_mitm_streaming_flags for copilot is empty" {
	run sct_agent_mitm_streaming_flags copilot
	assert_success
	[ -z "$output" ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd cli && ./support/bats/bin/bats test/agents/agents.bats -f "copilot"`
Expected: FAIL — dispatchers don't yet handle copilot.

- [ ] **Step 4: Implement in `cli/lib/agents.bash`**

Add `copilot)` cases to:
- `sct_agent_vscode_extension` — based on Step 1 finding:
  - If callers accept multi-token: `echo "GitHub.copilot GitHub.copilot-chat"`.
  - If single-token only: `echo "GitHub.copilot"` and log a report note.
- `sct_agent_devcontainer_settings_block` → fall through to `*)` empty.
- `sct_agent_compose_environment_entries` → add `copilot` to the existing `cursor|codex|*)` empty branch (either explicit or by fallthrough — verify with the existing branch structure).
- `sct_agent_mitm_streaming_flags` → add `copilot` to the existing `claude|codex|*)` empty branch.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd cli && ./support/bats/bin/bats test/agents/agents.bats -f "copilot"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): copilot dispatcher — VS Code ext, compose env, mitm flags"
```

---

### Task 3: Docker install + home-prep + user-init blocks

**Files:**
- Modify: `cli/lib/agents.bash`
- Test: `cli/test/agents/agents.bats`

**Interfaces:**
- Consumes: previous dispatcher context.
- Produces:
  - `sct_agent_docker_install_block copilot` emits a `USER root` → NodeSource setup + `apt-get install nodejs` → `npm install -g @github/copilot` → `USER vscode` block.
  - `sct_agent_docker_home_prep_block copilot` emits `RUN mkdir -p /home/vscode/.copilot`.
  - `sct_agent_user_init_block copilot` emits: `copilot --version >/dev/null 2>&1 || warn` health check.

- [ ] **Step 1: Write the failing tests**

Append:

```bash
@test "sct_agent_docker_install_block copilot installs Node.js 22 + @github/copilot" {
	run sct_agent_docker_install_block copilot
	assert_success
	assert_output --partial "setup_22.x"
	assert_output --partial "nodejs"
	assert_output --partial "npm install -g @github/copilot"
	assert_output --partial "USER root"
	assert_output --partial "USER vscode"
}

@test "sct_agent_docker_home_prep_block copilot pre-creates ~/.copilot" {
	run sct_agent_docker_home_prep_block copilot
	assert_success
	assert_output --partial "mkdir -p /home/vscode/.copilot"
}

@test "sct_agent_user_init_block copilot runs a copilot --version health check" {
	run sct_agent_user_init_block copilot
	assert_success
	assert_output --partial "copilot --version"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./support/bats/bin/bats test/agents/agents.bats -f "copilot"`
Expected: FAIL — copilot cases missing.

- [ ] **Step 3: Implement in `cli/lib/agents.bash`**

`sct_agent_docker_install_block` — add:

```bash
copilot)
    cat <<'EOF'
# Install Node.js 22 (Copilot CLI requires Node.js 20+).
# NodeSource setup script is the shortest path to a current Node on the
# vscode base image (Debian). Runs as root; USER is restored to vscode
# before the block ends.
USER root
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*
# Install GitHub Copilot CLI.
RUN npm install -g @github/copilot
USER vscode
EOF
    ;;
```

`sct_agent_docker_home_prep_block` — add:

```bash
copilot)
    cat <<'EOF'
# Pre-create ~/.copilot so Docker bind-mounts don't create it as root-owned.
RUN mkdir -p /home/vscode/.copilot
EOF
    ;;
```

`sct_agent_user_init_block` — add:

```bash
copilot)
    cat <<'EOF'
# Copilot CLI reads $COPILOT_GITHUB_TOKEN directly from environment —
# sandcat.env has already been sourced with the placeholder or
# 1Password-resolved value. Basic health check on first start;
# failure is non-fatal.
if command -v copilot >/dev/null 2>&1; then
    copilot --version >/dev/null 2>&1 \
        || echo "sandcat: copilot --version failed (non-fatal)" >&2
fi
EOF
    ;;
```

Then let the existing `sct_rtk_user_init_block "$agent"` call fall through — it hits the `*)` no-op case for `copilot`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./support/bats/bin/bats test/agents/agents.bats -f "copilot"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): copilot Dockerfile blocks — Node.js 22 + @github/copilot"
```

---

### Task 4: `add_copilot_config_volumes` in composefile.bash

**Files:**
- Modify: `cli/lib/composefile.bash`
- Test: `cli/test/composefile/composefile.bats`

**Interfaces:**
- Consumes: existing `add_volume_entry`, `add_volume_foot_comment`.
- Produces:
  - `add_copilot_config_volumes <compose_file> <active>` — adds three optional bind-mounts to the agent service:
    - `${HOME}/.copilot/mcp-config.json:/home/vscode/.copilot/mcp-config.json:ro`
    - `${HOME}/.copilot/session-state:/home/vscode/.copilot/session-state:ro`
    Each rendered active (uncommented) when `$active == "true"`, or commented placeholder otherwise (matching how Codex/Claude/Cursor do it).
  - Wired into `customize_compose_file`'s `case "$agent"` so it fires for `copilot`.

- [ ] **Step 1: Write the failing tests**

Append to `cli/test/composefile/composefile.bats` (or the closest existing per-agent-config test file — read the file to find the pattern used for codex):

```bash
@test "add_copilot_config_volumes adds mcp-config.json when active" {
	local compose_file="$BATS_TEST_TMPDIR/compose-all.yml"
	echo 'services: {agent: {volumes: []}}' > "$compose_file"

	add_copilot_config_volumes "$compose_file" true

	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.copilot/mcp-config.json:/home/vscode/.copilot/mcp-config.json:ro")' "$compose_file"
}

@test "add_copilot_config_volumes adds session-state when active" {
	local compose_file="$BATS_TEST_TMPDIR/compose-all.yml"
	echo 'services: {agent: {volumes: []}}' > "$compose_file"

	add_copilot_config_volumes "$compose_file" true

	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.copilot/session-state:/home/vscode/.copilot/session-state:ro")' "$compose_file"
}

@test "add_copilot_config_volumes emits commented entries when active=false" {
	local compose_file="$BATS_TEST_TMPDIR/compose-all.yml"
	echo 'services: {agent: {volumes: []}}' > "$compose_file"

	add_copilot_config_volumes "$compose_file" false

	# No active mounts.
	run yq -e '.services.agent.volumes[] | select(. | test("copilot"))' "$compose_file"
	assert_failure
	# Commented placeholder present.
	grep -q ".copilot" "$compose_file"
}

@test "customize_compose_file wires copilot config volumes for copilot agent" {
	local compose_file="$BATS_TEST_TMPDIR/compose-all.yml"
	cp "$SCT_TEMPLATEDIR/devcontainer/compose-all.yml" "$compose_file"

	SANDCAT_MOUNT_COPILOT_CONFIG=true \
		customize_compose_file ".sandcat/settings.json" "$compose_file" copilot none proj ""

	yq -e '.services.agent.volumes[] | select(. == "${HOME}/.copilot/mcp-config.json:/home/vscode/.copilot/mcp-config.json:ro")' "$compose_file"
}
```

Match the existing codex-test pattern for setup — read `cli/test/composefile/composefile.bats` first to see how `add_codex_config_volumes` was tested and follow the same idiom.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./support/bats/bin/bats test/composefile/composefile.bats -f "copilot"`
Expected: FAIL — function not defined.

- [ ] **Step 3: Implement `add_copilot_config_volumes` in `cli/lib/composefile.bash`**

Model after `add_codex_config_volumes` (search the file). Roughly:

```bash
# Adds Copilot config-directory volumes to the agent service.
# Args:
#   $1 - Path to the Docker Compose file
#   $2 - true to add as active entries, false to add as commented placeholders
add_copilot_config_volumes() {
	require yq
	local compose_file=$1
	local active=$2

	add_volume_entry "$compose_file" '${HOME}/.copilot/mcp-config.json:/home/vscode/.copilot/mcp-config.json:ro' "$active" 'Host Copilot MCP config (optional)'
	add_volume_entry "$compose_file" '${HOME}/.copilot/session-state:/home/vscode/.copilot/session-state:ro' "$active" 'Host Copilot session state (optional)'
}
```

Wire into `customize_compose_file`'s `case "$agent"`:

```bash
case "$agent" in
    ...
    copilot)
        add_copilot_config_volumes "$compose_file" "${SANDCAT_MOUNT_COPILOT_CONFIG:=true}"
        ;;
esac
```

Also update the header comment listing `SANDCAT_MOUNT_*` env vars.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./support/bats/bin/bats test/composefile/composefile.bats -f "copilot"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cli/lib/composefile.bash cli/test/composefile/composefile.bats
git commit -m "feat(cli): add_copilot_config_volumes for the agent service"
```

---

### Task 5: User settings template + mitmproxy addon

**Files:**
- Create: `cli/templates/settings-user-copilot.json`
- Create: `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_copilot.py`
- Modify: `cli/libexec/init/init` (add copilot to `user_settings_template_path`, if it's a case-based dispatcher)
- Modify: `cli/lib/devcontainer.bash` (or wherever `mitm_addon_file` for the agent is selected — see codex for the pattern)
- Test: `cli/test/init/init.bats` (settings template selection), `cli/test/init/extensions.bats` (mitm addon selection)

**Interfaces:**
- Consumes: existing SandcatAddon Python class.
- Produces:
  - New template files at the paths above.
  - `sandcat init --agent copilot` copies `settings-user-copilot.json` to `~/.config/sandcat/settings.json` on first run.
  - Renders the mitmproxy addon path `mitmproxy_addon_copilot.py` into `compose-proxy.yml` (via existing placeholder replacement).

- [ ] **Step 1: Create the settings template**

`cli/templates/settings-user-copilot.json`:

```json
{
  "env": {},
  "secrets": {
    "COPILOT_GITHUB_TOKEN": {
      "value": "",
      "hosts": ["api.github.com", "*.github.com", "*.githubcopilot.com", "*.githubusercontent.com"]
    }
  },
  "network": [
    {"action": "allow", "host": "*.github.com"},
    {"action": "allow", "host": "github.com"},
    {"action": "allow", "host": "*.githubusercontent.com"},
    {"action": "allow", "host": "*.githubcopilot.com"}
  ]
}
```

- [ ] **Step 2: Create the mitmproxy addon**

`cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_copilot.py`:

```python
"""
Copilot-focused mitmproxy addon: network access rules and secret substitution.

Loaded via: mitmweb -s /scripts/mitmproxy_addon_copilot.py

Thin wrapper around the shared :mod:`mitmproxy_addon_common` library.
GitHub Copilot CLI sends chat completions over HTTPS to
``api.<tier>.githubcopilot.com`` with SSE streaming responses; requests
are plain JSON, so the base ``SandcatAddon`` class's buffered-body
behaviour handles both the streaming response and the placeholder
leak check on requests. No streaming flags required (unlike Cursor).

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

- [ ] **Step 3: Write tests for settings-template selection + addon rendering**

Read the existing `test_settings_template_path` (or however it's tested for codex) in `cli/test/init/init.bats` and extend the parametric assertions to cover copilot. Same for `mitmproxy_addon_codex.py` presence checks in `cli/test/init/extensions.bats` — add copilot equivalents.

Example additions:

```bash
@test "user_settings_template_path returns copilot template for copilot" {
	# ... setup that lets user_settings_template_path be sourced
	run user_settings_template_path copilot
	assert_success
	assert_output --partial "settings-user-copilot.json"
}

@test "customize_agent_templates sets copilot mitmproxy defaults" {
	# ... standard setup
	customize_agent_templates "$BATS_TEST_TMPDIR" "copilot"

	run grep '/scripts/mitmproxy_addon_copilot.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success
}
```

- [ ] **Step 4: Run tests to verify they fail**

Expected: FAIL — template file exists but the dispatcher hasn't been extended yet.

- [ ] **Step 5: Wire into init flow**

In `cli/libexec/init/init` (or `agents.bash`), the `user_settings_template_path` function should already work by convention if it builds the path from `$agent`. Verify with `settings-user-<agent>.json` lookup — no code change needed if template naming matches.

In `cli/lib/devcontainer.bash` (or wherever `mitm_addon_file` is selected — grep for `mitmproxy_addon_codex.py` to find the switch), add:

```bash
copilot)
    mitm_addon_file="mitmproxy_addon_copilot.py"
    ;;
```

- [ ] **Step 6: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add cli/templates/settings-user-copilot.json \
        cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_copilot.py \
        cli/libexec/init/init cli/lib/devcontainer.bash \
        cli/test/init/init.bats cli/test/init/extensions.bats
git commit -m "feat(cli): copilot settings template + mitmproxy addon"
```

---

### Task 6: Hands-on integration verification

**Files:** No source files. Produces evidence for the PR body.

**Interfaces:**
- Consumes: everything above.
- Produces: PASS/FAIL log for each scenario. If SSE handling fails, adds `sct_agent_mitm_streaming_flags copilot` with Cursor-style flags (Task 2 leaves this branch empty pending this verification).

- [ ] **Step 1: Init a scratch project + build**

```bash
TEST=$(mktemp -d /tmp/copilot-e2e.XXXX); cd "$TEST" && mkdir proj && cd proj && git init -q
sandcat init --agent copilot --ide none --name copilot-e2e --path . \
  --stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web
# Configure the token in user settings
CGT=$(gh auth token)  # or use a fine-grained PAT with "Copilot Requests"
yq -i -o json ".secrets.COPILOT_GITHUB_TOKEN.value = \"$CGT\"" ~/.config/sandcat/settings.json
docker compose -f .devcontainer/compose-all.yml up -d --build
```

Expect: build succeeds (Node.js 22 + @github/copilot installed). All three containers healthy after ~30s.

- [ ] **Step 2: Verify Copilot CLI is available in the agent container**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent copilot --version
```

Expect: prints `GitHub Copilot CLI 1.0.X` — non-zero exit means Node.js/npm install didn't put binary on PATH.

- [ ] **Step 3: Verify auth via env var placeholder substitution**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -c \
  'env | grep COPILOT_GITHUB_TOKEN'
```

Expect: env var value is `SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN` (NOT the real token).

- [ ] **Step 4: End-to-end prompt**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -lc \
  'copilot -p "reply with exactly the word PONG" --allow-all-tools'
```

Expect: exits 0, response contains `PONG`. Chat completion round-trip through mitmproxy succeeds.

- [ ] **Step 5: mitmproxy logs — placeholder substitution and streaming behavior**

```bash
docker compose -f .devcontainer/compose-all.yml logs mitmproxy | tail -40
```

Expect:
- Requests to `api.github.com` and `api.individual.githubcopilot.com` visible.
- No `403 Access Denied` from the network allowlist.
- No occurrence of the literal string `SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN` in forwarded traffic (placeholder was substituted).
- No SSE-related errors (`stream aborted`, `timeout_read exceeded`, etc.). If any appear, Task 2's `sct_agent_mitm_streaming_flags` needs to be revisited for copilot.

- [ ] **Step 6: Non-allowlisted host is blocked**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent \
  curl -sSI --max-time 5 https://example.com/ 2>&1 | head -3
```

Expect: HTTP 403 (from mitmproxy — not on allowlist) or a connection reset.

- [ ] **Step 7: Teardown + record findings**

```bash
docker compose -f .devcontainer/compose-all.yml down
```

Write results (all 6 steps) into `.superpowers/sdd/2026-08-11-copilot-agent/task-6-report.md` for the PR body.

If Step 5 revealed SSE issues, dispatch a follow-up fix to Task 2 adding streaming flags for `copilot`:

```bash
case "$agent" in
    cursor|copilot)
        echo "--set stream_large_bodies=1m --set connection_strategy=lazy --set anticomp=true --set timeout_read=300"
        ;;
    claude|codex|*)
        echo ""
        ;;
esac
```

Re-run Step 4 to confirm; if still failing, escalate as BLOCKED.

---

### Task 7: README documentation

**Files:**
- Modify: `README.md`, `cli/README.md`

**Interfaces:** Docs only. No code.

- [ ] **Step 1: `README.md` — add Copilot to the supported-agents section**

Find the section listing claude / cursor / codex (grep `--agent claude`). Add a subsection for `--agent copilot`, similar structure:

- One-line summary
- How to get a fine-grained PAT with "Copilot Requests" permission (github.com/settings/personal-access-tokens)
- Alternative: `COPILOT_GITHUB_TOKEN=$(gh auth token)` for a quick start with an existing `gh` login
- Note: adds ~120MB to image size due to Node.js 22 install
- Link to Copilot CLI docs (`https://docs.github.com/copilot/how-tos/copilot-cli`)

- [ ] **Step 2: `cli/README.md` — supported-agents list**

Find the line listing supported agents (usually one-line summary). Add `copilot`.

- [ ] **Step 3: Commit**

```bash
git add README.md cli/README.md
git commit -m "docs: document copilot as a supported agent"
```

---

## Out of scope for this plan

- Copilot Business/Enterprise-specific UX (auto-detecting tier and setting `COPILOT_GH_HOST`). Users can set this env var manually via `env` in settings.json; a first-class flag can wait for demand.
- RTK integration for Copilot (rtk lacks `--agent copilot` today). No-op branch in `sct_rtk_user_init_block` matches the codex path.
- BYOK custom-provider config (`COPILOT_PROVIDER_*` env vars). Advanced use case; users can pass through via `env` block in settings.json.
- 1Password / Proton Pass secret-backend explicit reference examples beyond the generic template — the `sct_agent_op_api_key_help` line covers the pattern.
- Any placeholder-substitution changes to `mitmproxy_addon_common.py`. Copilot uses Bearer in Authorization header — identical to Codex — no addon common-code changes required.
