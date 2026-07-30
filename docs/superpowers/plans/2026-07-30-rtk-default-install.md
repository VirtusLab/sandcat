# rtk default install — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install [rtk-ai/rtk](https://github.com/rtk-ai/rtk) by default into every sandcat sandbox and auto-run its per-agent init hook for `claude`, with a symmetric `--features no-rtk` / `SANDCAT_RTK=false` opt-out.

**Architecture:** New `cli/lib/rtk.bash` module exposes three functions (`sct_rtk_enabled`, `sct_rtk_docker_install_block`, `sct_rtk_user_init_block`). Existing per-agent dispatchers in `cli/lib/agents.bash` (`sct_agent_docker_install_block`, `sct_agent_user_init_block`) append rtk fragments to their emitted output when the feature is enabled. The `--features no-rtk` flag in `cli/libexec/init/init` (or `SANDCAT_RTK=false` env var) turns emission off end-to-end.

**Tech Stack:** Bash 5+, bats-core + bats-mock (existing test infra), Docker + Docker Compose (sandbox runtime), `install.sh` from `raw.githubusercontent.com/rtk-ai/rtk`.

## Global Constraints

- rtk **enabled by default** — `SANDCAT_RTK` unset is treated as `true`. Only `SANDCAT_RTK=false` disables.
- Opt-out is **symmetric across two channels**: `sandcat init --features no-rtk` and `SANDCAT_RTK=false sandcat init` produce identical output.
- **Only `claude` gets a rtk-init block in this iteration.** `cursor` (already in `sct_available_agents`) and future agents (codex etc.) do NOT get rtk init auto-run; the case falls through to a safe no-op. The rtk binary IS still installed into the image regardless of agent, because installation is agent-agnostic.
- **Unknown agents:** `sct_agent_docker_install_block` and `sct_agent_user_init_block` MUST continue to return empty output for the `*)` (unknown) branch — even with rtk enabled. This preserves the existing dispatch contract asserted by `cli/test/agents/agents.bats`.
- **Runtime init is idempotent** via a check for `~/.config/rtk/config.toml`. Failure is non-fatal (warn to stderr, continue).
- **Install method: install.sh in Dockerfile** — matches existing pattern for claude and cursor. No pinning in first iteration.

---

### Task 1: `sct_rtk_enabled` and skeleton of `cli/lib/rtk.bash`

**Files:**
- Create: `cli/lib/rtk.bash`
- Create: `cli/test/rtk/rtk.bats`

**Interfaces:**
- Produces: `sct_rtk_enabled()` — returns 0 when the rtk feature is enabled (default), 1 when disabled. Consumes only `$SANDCAT_RTK` env.

- [ ] **Step 1: Create test directory and write the failing test**

Create `cli/test/rtk/rtk.bats`:

```bash
#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

# Unit tests for cli/lib/rtk.bash — the rtk feature emission helpers.

setup() {
	load ../agents/test_helper
	# shellcheck source=../../lib/rtk.bash
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
}

@test "sct_rtk_enabled returns 0 when SANDCAT_RTK is unset (default on)" {
	unset SANDCAT_RTK
	run sct_rtk_enabled
	assert_success
}

@test "sct_rtk_enabled returns 0 when SANDCAT_RTK=true" {
	SANDCAT_RTK=true run sct_rtk_enabled
	assert_success
}

@test "sct_rtk_enabled returns 0 when SANDCAT_RTK is empty" {
	SANDCAT_RTK="" run sct_rtk_enabled
	assert_success
}

@test "sct_rtk_enabled returns 1 when SANDCAT_RTK=false" {
	SANDCAT_RTK=false run sct_rtk_enabled
	assert_failure
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: FAIL — `rtk.bash: no such file or directory`

- [ ] **Step 3: Create `cli/lib/rtk.bash` with `sct_rtk_enabled`**

Create `cli/lib/rtk.bash`:

```bash
#!/usr/bin/env bash
# rtk (Rust Token Killer, https://github.com/rtk-ai/rtk) install + init
# helpers. Emission is gated on SANDCAT_RTK (default: true). Consumed by
# the per-agent dispatchers in cli/lib/agents.bash so the rtk install RUN
# lands in Dockerfile.app and rtk init runs at container start.

# Returns 0 (enabled) when SANDCAT_RTK is unset or anything other than
# the literal string "false". Default-on posture: absent env var means
# the user has not explicitly opted out.
sct_rtk_enabled() {
	[[ "${SANDCAT_RTK:-true}" != "false" ]]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: PASS (4/4)

- [ ] **Step 5: Commit**

```bash
git add cli/lib/rtk.bash cli/test/rtk/rtk.bats
git commit -m "feat(cli): add rtk feature-flag helper (sct_rtk_enabled)"
```

---

### Task 2: `sct_rtk_docker_install_block`

**Files:**
- Modify: `cli/lib/rtk.bash`
- Modify: `cli/test/rtk/rtk.bats`

**Interfaces:**
- Consumes: `sct_rtk_enabled` (Task 1)
- Produces: `sct_rtk_docker_install_block()` — emits the Dockerfile `RUN` line that installs rtk when enabled; empty output when disabled.

- [ ] **Step 1: Add failing tests to `cli/test/rtk/rtk.bats`**

Append at end of the bats file:

```bash
@test "sct_rtk_docker_install_block emits install.sh RUN when enabled" {
	unset SANDCAT_RTK
	run sct_rtk_docker_install_block
	assert_success
	assert_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
	assert_output --partial "install.sh"
	assert_output --partial "RUN curl"
}

@test "sct_rtk_docker_install_block emits nothing when disabled" {
	SANDCAT_RTK=false run sct_rtk_docker_install_block
	assert_success
	assert_output ""
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: FAIL — `sct_rtk_docker_install_block: command not found` (2 tests)

- [ ] **Step 3: Add implementation to `cli/lib/rtk.bash`**

Append at end of `cli/lib/rtk.bash`:

```bash
# Emits the Dockerfile.app RUN block that installs the rtk binary
# globally via its official install script. Agent-agnostic — the same
# binary serves every supported agent; per-agent hook wiring happens
# at container start via sct_rtk_user_init_block.
#
# Emits an empty output when the feature is disabled so the caller can
# unconditionally append it to Dockerfile fragments.
sct_rtk_docker_install_block() {
	sct_rtk_enabled || return 0
	cat <<'EOF'
# Install rtk (Rust Token Killer) — compresses shell command output so AI
# agents consume fewer tokens per command. Disable at init time with
# `sandcat init --features no-rtk` or `SANDCAT_RTK=false`.
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh
EOF
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: PASS (6/6)

- [ ] **Step 5: Commit**

```bash
git add cli/lib/rtk.bash cli/test/rtk/rtk.bats
git commit -m "feat(cli): emit rtk install RUN block in Dockerfile.app when enabled"
```

---

### Task 3: `sct_rtk_user_init_block` — per-agent dispatch (claude only)

**Files:**
- Modify: `cli/lib/rtk.bash`
- Modify: `cli/test/rtk/rtk.bats`

**Interfaces:**
- Consumes: `sct_rtk_enabled` (Task 1)
- Produces: `sct_rtk_user_init_block(agent)` — for `claude` emits an idempotent `rtk init -g` block; empty for cursor/unknown/all other agents; empty when disabled.

- [ ] **Step 1: Add failing tests to `cli/test/rtk/rtk.bats`**

Append at end:

```bash
@test "sct_rtk_user_init_block: claude emits guarded rtk init -g" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block claude
	assert_success
	assert_output --partial "rtk init -g"
	assert_output --partial "command -v rtk"
	assert_output --partial ".config/rtk/config.toml"
	assert_output --partial "non-fatal"
}

@test "sct_rtk_user_init_block: cursor emits nothing (no rtk profile yet)" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block cursor
	assert_success
	assert_output ""
}

@test "sct_rtk_user_init_block: unknown emits nothing" {
	unset SANDCAT_RTK
	run sct_rtk_user_init_block unknown
	assert_success
	assert_output ""
}

@test "sct_rtk_user_init_block: claude emits nothing when disabled" {
	SANDCAT_RTK=false run sct_rtk_user_init_block claude
	assert_success
	assert_output ""
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: FAIL — `sct_rtk_user_init_block: command not found` (4 tests)

- [ ] **Step 3: Add implementation**

Append at end of `cli/lib/rtk.bash`:

```bash
# Emits the app-user-init.sh fragment that runs `rtk init` for the given
# agent, guarded to a one-time execution. Only `claude` has a wired case
# in this iteration; every other agent (cursor / unknown / future) gets
# a safe no-op so the binary is still available on PATH but rtk stays
# uninitialized until the case is added.
#
# Emits an empty output when the feature is disabled OR when the agent
# has no rtk profile.
#
# Args:
#   $1 - Agent name
sct_rtk_user_init_block() {
	local agent=$1
	sct_rtk_enabled || return 0
	case "$agent" in
		claude)
			cat <<'EOF'
# rtk (Rust Token Killer) — one-time hook config for Claude Code.
# `rtk init -g` writes a hook entry into ~/.claude/settings.json;
# idempotent once ~/.config/rtk/config.toml exists.
if command -v rtk >/dev/null 2>&1 && [ ! -f "$HOME/.config/rtk/config.toml" ]; then
    rtk init -g >/dev/null 2>&1 \
        || echo "sandcat: rtk init failed (non-fatal)" >&2
fi
EOF
			;;
		*)
			# No rtk profile wired for this agent — safe no-op. Binary is
			# still installed by sct_rtk_docker_install_block; user can
			# invoke `rtk init` manually.
			return 0
			;;
	esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/rtk/rtk.bats`
Expected: PASS (10/10 in rtk.bats)

- [ ] **Step 5: Commit**

```bash
git add cli/lib/rtk.bash cli/test/rtk/rtk.bats
git commit -m "feat(cli): emit rtk init block for claude in app-user-init.sh"
```

---

### Task 4: Wire rtk into `sct_agent_docker_install_block`

**Files:**
- Modify: `cli/lib/agents.bash`
- Modify: `cli/test/agents/agents.bats`

**Interfaces:**
- Consumes: `sct_rtk_docker_install_block` (Task 2)
- Produces: modified `sct_agent_docker_install_block(agent)` — for `claude` and `cursor` emits agent-specific install PLUS rtk install (when enabled); for unknown still emits empty.

The current `*)` branch of the case emits `echo ""` and falls through to any code after `esac`. If we append rtk after `esac`, unknown agents would ALSO get rtk emitted — breaking the "unknown returns empty" test. Fix: change `*)` to `return 0` so the function exits before the append.

- [ ] **Step 1: Extend `cli/test/agents/agents.bats` with new failing tests**

Locate the "Dockerfile install" section (near line 261) and add these tests immediately after the existing three:

```bash
@test "sct_agent_docker_install_block: claude append rtk install when enabled" {
	# shellcheck source=../../lib/rtk.bash
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_docker_install_block claude
	assert_output --partial "claude.ai/install.sh"
	assert_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}

@test "sct_agent_docker_install_block: claude skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_docker_install_block claude
	assert_output --partial "claude.ai/install.sh"
	refute_output --partial "raw.githubusercontent.com/rtk-ai/rtk"
}

@test "sct_agent_docker_install_block: unknown returns empty even with rtk enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_docker_install_block unknown
	assert_output ""
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: FAIL — the first new test fails (rtk not in claude output); the second passes accidentally; the third passes (still returns empty today). Focus is on test 1.

- [ ] **Step 3: Modify `cli/lib/agents.bash`**

Find `sct_agent_docker_install_block` (grep: `grep -n "^sct_agent_docker_install_block" cli/lib/agents.bash`). Update it as follows:

1. At top of the function, source rtk helpers:

```bash
sct_agent_docker_install_block() {
	local agent=$1
	# shellcheck source=./rtk.bash
	source "${BASH_SOURCE[0]%/*}/rtk.bash"
	case "$agent" in
```

2. Change the `*)` fallthrough to `return 0`:

```bash
		*)
			return 0
			;;
	esac
	sct_rtk_docker_install_block
}
```

Full expected shape of the function:

```bash
sct_agent_docker_install_block() {
	local agent=$1
	# shellcheck source=./rtk.bash
	source "${BASH_SOURCE[0]%/*}/rtk.bash"
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
			return 0
			;;
	esac
	sct_rtk_docker_install_block
}
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: PASS (all existing + 3 new; verify no regression in "unknown returns empty" test at line ~271)

- [ ] **Step 5: Run the full unit-test suite as a regression check**

Run: `cd cli && ./run-tests.bash`
Expected: PASS (no regressions elsewhere)

- [ ] **Step 6: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): append rtk install to agent Dockerfile block when enabled"
```

---

### Task 5: Wire rtk into `sct_agent_user_init_block`

**Files:**
- Modify: `cli/lib/agents.bash`
- Modify: `cli/test/agents/agents.bats`

**Interfaces:**
- Consumes: `sct_rtk_user_init_block` (Task 3)
- Produces: modified `sct_agent_user_init_block(agent)` — for `claude` emits onboarding-seed PLUS rtk init block; for `cursor` unchanged (rtk case not wired); for unknown still empty.

- [ ] **Step 1: Extend `cli/test/agents/agents.bats` with new failing tests**

After the "user init bootstrap" section (near line 295-309), add:

```bash
@test "sct_agent_user_init_block: claude appends rtk init when enabled" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block claude
	assert_output --partial "hasCompletedOnboarding"
	assert_output --partial "rtk init -g"
}

@test "sct_agent_user_init_block: claude skips rtk when SANDCAT_RTK=false" {
	source "$SCT_LIBDIR/rtk.bash"
	SANDCAT_RTK=false run sct_agent_user_init_block claude
	assert_output --partial "hasCompletedOnboarding"
	refute_output --partial "rtk init"
}

@test "sct_agent_user_init_block: cursor does NOT get rtk init (no profile yet)" {
	source "$SCT_LIBDIR/rtk.bash"
	unset SANDCAT_RTK
	run sct_agent_user_init_block cursor
	assert_output --partial "cursor-cli-config.json"
	refute_output --partial "rtk init"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: FAIL — the first new test fails ("rtk init" not found in claude output).

- [ ] **Step 3: Modify `cli/lib/agents.bash`**

Update `sct_agent_user_init_block` the same way as Task 4: source rtk.bash at top, change `*)` to `return 0`, append `sct_rtk_user_init_block "$agent"` after `esac`.

Full expected shape:

```bash
sct_agent_user_init_block() {
	local agent=$1
	# shellcheck source=./rtk.bash
	source "${BASH_SOURCE[0]%/*}/rtk.bash"
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
# ... (existing cursor block — leave unchanged) ...
EOF
			;;
		*)
			return 0
			;;
	esac
	sct_rtk_user_init_block "$agent"
}
```

Note: leave the existing cursor content byte-identical — only change is the `*)` fallthrough and the trailing rtk call.

- [ ] **Step 4: Run tests to verify all pass**

Run: `cd cli && ./run-tests.bash test/agents/agents.bats`
Expected: PASS

- [ ] **Step 5: Run the full unit-test suite as a regression check**

Run: `cd cli && ./run-tests.bash`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add cli/lib/agents.bash cli/test/agents/agents.bats
git commit -m "feat(cli): append rtk init to agent user-init block for claude"
```

---

### Task 6: Wire feature flag into `cli/libexec/init/init`

**Files:**
- Modify: `cli/libexec/init/init`
- Modify: `cli/test/init/init.bats`

**Interfaces:**
- Consumes: nothing external — orchestrates env export for downstream tasks.
- Produces: `sandcat init --features no-rtk` and `SANDCAT_RTK=false sandcat init` both export `SANDCAT_RTK=false` to sub-commands; default init exports `SANDCAT_RTK=true`. Summary line `RTK: installed|disabled` printed via `info` logger.

- [ ] **Step 1: Extend `cli/test/init/init.bats` with failing tests**

Add these tests after the existing feature tests (the file already has `--features tui`, `--features no-shared-cache` etc.):

```bash
@test "init --features no-rtk exports SANDCAT_RTK=false" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : echo \"RTK=\$SANDCAT_RTK\""

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-rtk" --secret-provider none
	assert_success
	assert_output --partial "RTK=false"
}

@test "init respects SANDCAT_RTK=false env var" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : echo \"RTK=\$SANDCAT_RTK\""

	SANDCAT_RTK=false run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "RTK=false"
}

@test "init default exports SANDCAT_RTK=true" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : echo \"RTK=\$SANDCAT_RTK\""

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "RTK=true"
}

@test "init summary reports rtk status" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	# default → installed
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "" --secret-provider none
	assert_success
	assert_output --partial "RTK:"
	assert_output --partial "installed"
}

@test "init --features no-rtk reports rtk disabled" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"
	stub devcontainer \
		"--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "no-rtk" --secret-provider none
	assert_success
	assert_output --partial "RTK:"
	assert_output --partial "disabled"
}

@test "init rejects bogus feature and lists no-rtk in expected values" {
	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --features "bogus" --secret-provider none
	assert_failure
	assert_output --partial "no-rtk"
}
```

Additionally, locate all `stub select_multiple` calls that pass the existing feature labels (search: `grep -n "'Select optional features" cli/test/init/init.bats`) and append `'no-rtk (do not install rtk shell hook)'` to each stub label list. There are 3 such stubs — update all three.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd cli && ./run-tests.bash test/init/init.bats`
Expected: FAIL — new tests fail; existing stub-based tests may also fail because the interactive picker now includes `no-rtk`, and the stub label list must include it.

- [ ] **Step 3: Modify `cli/libexec/init/init`**

Three concrete edits (line numbers relative to master; grep to find current positions):

**Edit A — Add `rtk_enabled` variable and feature parsing.** Find the section that defines `gitignore_enabled`… oh wait, that's on the other branch. On master this file just has feature flags for `tui` and `no-shared-cache`. Locate the comment block above `available_features` (grep: `grep -n "Optional non-provider features" cli/libexec/init/init`).

Insert a new line above `if [[ "$features_provided" != "true" ]]`:

```bash
	local rtk_enabled=${SANDCAT_RTK:-true}
```

Update the feature comment block to include the new feature.

Update `available_features=(...)` array in the interactive branch to include:

```bash
		"no-rtk (do not install rtk shell hook)"
```

Update the interactive `case` (inside `for f in $selected_features`) to include:

```bash
					no-rtk) rtk_enabled=false ;;
```

Update the CSV `case` (inside `for f in $features_csv`) to include:

```bash
					no-rtk) rtk_enabled=false ;;
```

Update the unknown-feature error message to include `no-rtk` in the "expected" list.

**Edit B — Export `SANDCAT_RTK` before calling `devcontainer`.**

Locate the block where `devcontainer` is called (grep: `grep -n "^	devcontainer " cli/libexec/init/init`). Immediately BEFORE that call, add:

```bash
	export SANDCAT_RTK="$rtk_enabled"
```

**Edit C — Add RTK line to the init summary.**

Locate the summary block (grep: `grep -n "Initialization complete" cli/libexec/init/init`). After the existing lines and BEFORE the `case "$secret_provider"` block, add:

```bash
	if [[ "$rtk_enabled" == "true" ]]; then
		echo "  RTK:              installed (disable with --features no-rtk)" | info
	else
		echo "  RTK:              disabled" | info
	fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd cli && ./run-tests.bash test/init/init.bats`
Expected: PASS (all existing + 6 new)

- [ ] **Step 5: Run the full unit-test suite as a regression check**

Run: `cd cli && ./run-tests.bash`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add cli/libexec/init/init cli/test/init/init.bats
git commit -m "feat(cli): wire --features no-rtk and SANDCAT_RTK into sandcat init"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `cli/README.md`

**Interfaces:** None — pure documentation.

- [ ] **Step 1: Add "RTK" subsection to `README.md`**

Locate the existing subsections under "Initialize the sandbox for your project" (grep: `grep -n "^#### " README.md`). Immediately after the "Customizing optional volume mounts" subsection (or wherever gitignore-defaults section lives if that PR merged first — coordinate branch order), add:

```markdown
#### RTK — LLM token compression for Claude Code

[rtk-ai/rtk](https://github.com/rtk-ai/rtk) ("Rust Token Killer") wraps
shell commands invoked by AI agents and compresses their output before
the agent reads it, cutting token consumption 60-90% on typical dev
commands (test runs, grep output, build logs). `sandcat init` installs
it into the sandbox and auto-configures the hook for Claude Code so it
works out of the box — no manual `rtk init` required.

**Opt out** if you'd rather run without it (e.g. debugging a shell
command's raw output):

```bash
sandcat init --features no-rtk ...
SANDCAT_RTK=false sandcat init ...
```

Both are equivalent — the env var is the scripted counterpart of the
interactive/CSV feature flag. When disabled, the rtk binary is not
installed into the image and no init hook is emitted for any agent.

Only `claude` gets automatic rtk init in this iteration. When `--agent
cursor` (or a future agent) is selected, the rtk binary is still
installed but its hook is not auto-configured; you can run `rtk init -g
--agent cursor` inside the container manually.
```

Also add a row to the `SANDCAT_*` env var table (grep: `grep -n "SANDCAT_MOUNT_SHARED_CACHE" README.md`):

```
| Any       | `SANDCAT_RTK`                 | `true` (see [RTK — LLM token compression for Claude Code](#rtk--llm-token-compression-for-claude-code)) |
```

- [ ] **Step 2: Update `cli/README.md`**

Locate the `--features` documentation line (grep: `grep -n "features" cli/README.md`). Append `no-rtk` to the CSV list of accepted values.

- [ ] **Step 3: Commit**

```bash
git add README.md cli/README.md
git commit -m "docs: document default rtk install and --features no-rtk opt-out"
```

---

### Task 8: Hands-on integration verification

**Files:**
- None (this is a manual verification task; results reported in commit or PR description)

**Interfaces:** None — validates end-to-end behavior.

Each of these scenarios runs against a real Docker sandbox — no stubs. Use a scratch project under `/tmp/sandcat-rtk-integ.XXXX`. The `sandcat` binary is at `/Users/seweryn.hejnowicz/projects/sandcat/cli/bin/sandcat` (or use `$SANDCAT_BIN`).

Every scenario below must be executed, and its outcome recorded, before the PR is opened.

- [ ] **Scenario 1 — Fresh install path**

```bash
SANDCAT_BIN=/Users/seweryn.hejnowicz/projects/sandcat/cli/bin/sandcat
TEST_ROOT=$(mktemp -d /tmp/sandcat-rtk-integ.XXXX)
cd "$TEST_ROOT" && mkdir proj1 && cd proj1 && git init -q
"$SANDCAT_BIN" init \
    --agent claude --ide vscode --name proj1 --path . \
    --stacks "" --secret-provider none --features "" --proxy web
"$SANDCAT_BIN" run --build   # first build
```

Then inside the running agent container:

```bash
command -v rtk               # expected: /usr/local/bin/rtk (or similar)
rtk --version                # expected: version string
cat ~/.claude/settings.json  # expected: contains rtk hook entry
ls ~/.config/rtk/config.toml # expected: file exists
```

Record all 4 outputs. All must succeed.

- [ ] **Scenario 2 — Restart idempotency**

Exit the container. Start again WITHOUT `--build`:

```bash
"$SANDCAT_BIN" run
```

Inside container:

```bash
sha256sum ~/.claude/settings.json    # record before
# (verify no "rtk init failed" warning in stderr from app-init.sh)
sha256sum ~/.claude/settings.json    # record after — must match before
```

Expected: settings.json unchanged (`rtk init` was skipped by the `config.toml` guard).

- [ ] **Scenario 3 — Opt-out at init**

```bash
cd "$TEST_ROOT" && mkdir proj-optout && cd proj-optout && git init -q
"$SANDCAT_BIN" init \
    --agent claude --ide vscode --name proj-optout --path . \
    --stacks "" --secret-provider none --features "no-rtk" --proxy web
"$SANDCAT_BIN" run --build
```

Inside container:

```bash
command -v rtk               # expected: FAIL (binary not installed)
cat ~/.claude/settings.json  # expected: no rtk hook entry (may not even exist)
```

- [ ] **Scenario 4 — Upgrade path**

Simulate a pre-feature container: from an earlier commit / branch without the rtk feature, run `sandcat init` + `sandcat run --build` on a scratch project. Then check out this feature branch:

```bash
cd "$TEST_ROOT" && mkdir proj-upgrade && cd proj-upgrade && git init -q
# From an earlier commit (before feat/rtk-default-install):
git -C /Users/seweryn.hejnowicz/projects/sandcat stash -u
git -C /Users/seweryn.hejnowicz/projects/sandcat checkout master
"$SANDCAT_BIN" init --agent claude --ide vscode --name proj-upgrade --path . --stacks "" --secret-provider none --features "" --proxy web
"$SANDCAT_BIN" run --build

# Now upgrade to feature branch:
git -C /Users/seweryn.hejnowicz/projects/sandcat checkout feat/rtk-default-install
"$SANDCAT_BIN" init --agent claude --ide vscode --name proj-upgrade --path . --stacks "" --secret-provider none --features "" --proxy web
"$SANDCAT_BIN" run --build
```

Inside container:

```bash
command -v rtk               # expected: present
cat ~/.claude/settings.json  # expected: rtk hook appended to existing content
```

- [ ] **Scenario 5 — Un-opting**

Continuing from Scenario 3 (project has `--features no-rtk` in prior init):

```bash
cd "$TEST_ROOT/proj-optout"
"$SANDCAT_BIN" init --agent claude --ide vscode --name proj-optout --path . --stacks "" --secret-provider none --features "" --proxy web
"$SANDCAT_BIN" run --build
```

Inside container:

```bash
command -v rtk               # expected: present
cat ~/.claude/settings.json  # expected: rtk hook now present
```

- [ ] **Cleanup**

```bash
rm -rf "$TEST_ROOT"
docker compose -p sandcat-proj1 down -v      # clean up test volumes
docker compose -p sandcat-proj-optout down -v
docker compose -p sandcat-proj-upgrade down -v
```

- [ ] **If all scenarios pass, no commit needed (all impl was done in Tasks 1-7).**

If any scenario fails, DO NOT proceed to the PR. Root-cause and fix, then re-run all 5.

---

## Post-implementation

After Task 8 succeeds:

1. Rebase the branch onto latest master (in case of conflicts with merged PR#82 or upstream changes).
2. Run the full test suite one final time: `cd cli && ./run-tests.bash`.
3. Push the branch and open a PR — title `feat(cli): install rtk by default with symmetric opt-out`. Body follows the pattern from PR#82 (Summary / Design notes / Test plan with all 5 integration scenarios marked done).
