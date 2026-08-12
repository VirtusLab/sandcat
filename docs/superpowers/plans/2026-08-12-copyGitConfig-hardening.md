# `dev.containers.copyGitConfig` Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix issue #34 — sandcat's `dev.containers.copyGitConfig: false` in `devcontainer.json.customizations.vscode.settings` is inert (Dev Containers extension reads it from HOST settings, not container-side). Add belt-and-braces defense: (1) update docs (comment + README) to reflect the limitation, mirroring the existing `terminal.integrated.allowLocalTerminal` note; (2) add unconditional `rm -f "$HOME/.gitconfig"` in `app-user-init.sh` before the git-identity apply block, so any copied host `.gitconfig` is discarded before the agent runs.

**Architecture:** Two small changes to templates (`devcontainer.json`, `app-user-init.sh`) plus README updates. No dispatcher / library changes. Applies to ALL agents identically (claude / cursor / codex / copilot).

**Tech Stack:** bash script, JSON with C-style comments, markdown.

## Global Constraints

- Cleanup step in `app-user-init.sh` runs BEFORE the existing `git config --global user.name/user.email` block. Order matters — reversing means the cleanup wipes what sandcat just set.
- Cleanup is **unconditional**. No env-var toggle, no feature flag. If a future opt-in is added, it's a separate PR.
- No changes to `cli/lib/*.bash`, `cli/libexec/*`, Dockerfile.app, or per-agent dispatchers — this fix applies uniformly.
- `devcontainer.json` comment matches the style/tone of the existing `terminal.integrated.allowLocalTerminal` comment (lines 44-47).
- README's "Consequences of hardening" section updated in place — do not add new sections.
- Backwards-compatible: existing sandcat projects reuse the same `app-user-init.sh`; on next container start their `.gitconfig` (if any leaked in via VS Code) is removed.
- No new dependencies.

---

### Task 1: Runtime cleanup in `app-user-init.sh`

**Files:**
- Modify: `cli/templates/devcontainer/sandcat/scripts/app-user-init.sh`

**Interfaces:**
- Consumes: `$HOME` (set to `/home/vscode` earlier in the same script).
- Produces: `~/.gitconfig` is guaranteed to be absent on entry to the existing `git config --global user.name` block. Downstream logic unchanged.

- [ ] **Step 1: Read the current app-user-init.sh**

Command: `head -30 cli/templates/devcontainer/sandcat/scripts/app-user-init.sh`
Note the current structure: `export HOME=...`, then two `if` blocks that set `user.name` and `user.email` from env, then `git config --global commit.gpgsign false`, etc.

- [ ] **Step 2: Insert cleanup step**

Right after the `export HOME="/home/vscode"` line and BEFORE the `if [ -n "${GIT_USER_NAME:-}" ]; then` block, insert:

```bash
# VS Code's Dev Containers extension reads dev.containers.copyGitConfig
# from HOST user settings, not from devcontainer.json — so a host
# ~/.gitconfig may have been copied in even though our template
# declares copyGitConfig: false (see issue #34). Remove any leftover
# gitconfig so it can't leak host credential helpers / signing keys
# or override the env-derived identity we're about to apply.
# Unconditional and idempotent — `-f` swallows the missing-file case.
rm -f "$HOME/.gitconfig"
```

- [ ] **Step 3: Verify no other paths depend on the file being present**

Command: `grep -n "\.gitconfig\|GIT_CONFIG" cli/templates/devcontainer/sandcat/scripts/`
Expected: only references in `app-user-init.sh` itself (the ones you just added and the `git config --global` calls that will recreate it). No other script relies on the pre-existing file.

- [ ] **Step 4: Bash syntax check**

Command: `bash -n cli/templates/devcontainer/sandcat/scripts/app-user-init.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add cli/templates/devcontainer/sandcat/scripts/app-user-init.sh
git commit -m "fix(cli): rm host-copied ~/.gitconfig in app-user-init (defense-in-depth for #34)"
```

---

### Task 2: `devcontainer.json` comment correction

**Files:**
- Modify: `cli/templates/devcontainer/devcontainer.json`
- Test: `cli/test/init/devcontainer.bats` (add a test asserting the new comment mentions "host user settings")

**Interfaces:**
- Consumes: nothing.
- Produces: honest documentation in the file that ships to every generated project.

- [ ] **Step 1: Write failing test**

Add to `cli/test/init/devcontainer.bats` — mirror the style of nearby tests that grep for expected content in the generated devcontainer.json:

```bash
@test "devcontainer.json comment notes copyGitConfig needs host user settings" {
	# Verify the comment above `dev.containers.copyGitConfig` explicitly
	# points at the host-user-settings requirement — mirrors the note on
	# `terminal.integrated.allowLocalTerminal`. See issue #34.
	local template="$SCT_TEMPLATEDIR/devcontainer/devcontainer.json"
	run grep -B4 '"dev.containers.copyGitConfig"' "$template"
	assert_success
	assert_output --partial "host user settings"
}
```

Run: `cd cli && ./support/bats/bin/bats test/init/devcontainer.bats -f "copyGitConfig"`
Expected: FAIL — current comment doesn't mention host user settings.

- [ ] **Step 2: Update the comment in `devcontainer.json`**

Replace the current comment (currently lines 37-39):

```json
// Prevent VS Code from copying host .gitconfig into the
// container, which can leak credential helpers and signing
// key references.
"dev.containers.copyGitConfig": false,
```

With:

```json
// Signal our intent to VS Code that host .gitconfig should not
// be copied into the container (which can leak credential helpers
// and signing key references). NOTE: this setting is read by VS
// Code's Dev Containers extension from HOST user settings, not
// from this file, so it only takes full effect if you also set
// "dev.containers.copyGitConfig": false in your host user settings.
// See README for details. app-user-init.sh removes any .gitconfig
// that gets through as a defense-in-depth cleanup.
"dev.containers.copyGitConfig": false,
```

- [ ] **Step 3: Verify test passes**

Run the same bats filter — expect PASS.

- [ ] **Step 4: Commit**

```bash
git add cli/templates/devcontainer/devcontainer.json cli/test/init/devcontainer.bats
git commit -m "docs(devcontainer): note that copyGitConfig also needs host user settings"
```

---

### Task 3: README correction

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: docs that match runtime behavior.

- [ ] **Step 1: Find the relevant sections**

Command: `grep -n "copyGitConfig\|Git identity" README.md`
Expected: line ~1320 ("Disables git config copying" bullet in the hardening list) and line ~1343 ("Git identity" paragraph in "Consequences of hardening").

- [ ] **Step 2: Update the "Disables git config copying" bullet (around line 1320)**

Current:

```markdown
- **Disables git config copying** (`dev.containers.copyGitConfig: false`) to
  prevent leaking host credential helpers and signing key references into the
  container.
```

Replace with:

```markdown
- **Disables git config copying** (`dev.containers.copyGitConfig: false` in
  `devcontainer.json`) to prevent leaking host credential helpers and signing
  key references into the container. The VS Code Dev Containers extension
  reads this setting from your **host** user settings, not from
  `devcontainer.json`, so for full effect also set it in
  `~/Library/Application Support/Code/User/settings.json` (macOS) or the
  equivalent for your OS. As a defense-in-depth fallback, `app-user-init.sh`
  removes any `.gitconfig` that gets copied in anyway.
```

- [ ] **Step 3: Update the "Git identity" paragraph (around line 1343)**

Current says "With `dev.containers.copyGitConfig` set to `false`, git inside the container has no `user.name` or `user.email`." That's still true (the setting represents intent), and the runtime cleanup guarantees it's true regardless. Leave the paragraph as-is, or add a one-sentence tail: "(this holds even if the setting was only applied on the container side — `app-user-init.sh` removes any host-copied gitconfig at startup)."

If the current text already reads naturally without that tail, skip the tail — README verbosity has a cost. Prefer the minimal edit.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: point at host user settings for copyGitConfig + note runtime cleanup"
```

---

### Task 4: Hands-on integration verification

**Files:** none modified.

**Interfaces:**
- Consumes: everything above.
- Produces: evidence for the PR body.

- [ ] **Step 1: Init a scratch project**

```bash
TEST=$(mktemp -d /tmp/copyGitConfig-e2e.XXXX); cd "$TEST" && mkdir proj && cd proj && git init -q
sandcat init --agent claude --ide none --name copyGitConfig-e2e --path . \
  --stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web
```

- [ ] **Step 2: Build + start the stack**

```bash
docker compose -f .devcontainer/compose-all.yml up -d --build
```

Wait for all three containers healthy.

- [ ] **Step 3: Inject a poisoned `.gitconfig` (simulate what Dev Containers extension would do)**

Create a fake host `.gitconfig` on the host side, `docker cp` it into the container's `/home/vscode/.gitconfig` — mimicking what VS Code Dev Containers extension would have done.

```bash
cat > /tmp/poisoned-gitconfig <<'EOF'
[user]
    name = Attacker Name
    email = attacker@example.com
    signingkey = ABCDEF1234567890
[commit]
    gpgsign = true
[credential]
    helper = osxkeychain
EOF
docker cp /tmp/poisoned-gitconfig copyGitConfig-e2e-agent-1:/home/vscode/.gitconfig
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent chown vscode:vscode /home/vscode/.gitconfig || true
```

Verify the file landed:
```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent cat /home/vscode/.gitconfig
```
Expected: shows the poisoned content.

- [ ] **Step 4: Re-run `app-user-init.sh` to trigger the cleanup**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -c '/usr/local/bin/app-user-init.sh 2>&1 | tail -5'
```

(In real use this runs at container start, but re-invoking it directly is the fastest way to test the cleanup happens.)

- [ ] **Step 5: Verify cleanup**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent cat /home/vscode/.gitconfig
```

Expected result:
- The `[user]` block contains ONLY `name = <what GIT_USER_NAME env said>` and `email = <what GIT_USER_EMAIL env said>` — NOT `Attacker Name` / `attacker@example.com`.
- `signingkey = ABCDEF1234567890` — ABSENT.
- `credential.helper = osxkeychain` — ABSENT.
- `[commit]` block: `gpgsign = false` (sandcat sets it explicitly to false).

Or, cleaner assertions:
```bash
# What sandcat KEEPS
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -lc \
    'git config --global user.name; git config --global user.email; git config --global commit.gpgsign'
# What sandcat REMOVES (should be empty/absent)
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -lc \
    'git config --global --get user.signingkey; git config --global --get credential.helper' \
    || echo "expected: keys absent"
```

- [ ] **Step 6: Teardown**

```bash
docker compose -f .devcontainer/compose-all.yml down -v
```

- [ ] **Step 7: Record findings**

Write to `.superpowers/sdd/2026-08-12-copyGitConfig-hardening/task-4-report.md`:
- Container versions
- Command outputs (redacted)
- PASS/FAIL for each of the six checks
- Any surprises

## Out of scope for this plan

- Adding an opt-in flag to preserve a copied `.gitconfig` (e.g., `SANDCAT_KEEP_HOST_GITCONFIG=true`). YAGNI — current template's declared intent is "no copy". If a real use case emerges, do it in a separate PR.
- Attempting to prevent the Dev Containers extension's copy at the host level (via `postCreateCommand`, `initializeCommand`, or similar). All of those hooks run AFTER the copy — no cleaner mechanism than the runtime cleanup exists.
- Doing anything different across agents (claude/cursor/codex/copilot). The fix is agent-agnostic; a change in `app-user-init.sh` covers all.
