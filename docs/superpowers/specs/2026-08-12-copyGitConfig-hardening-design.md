# `dev.containers.copyGitConfig` Hardening — Design

## Goal

Close the gap in sandcat's git-config isolation model exposed by issue #34: the `dev.containers.copyGitConfig: false` setting sandcat places in `devcontainer.json` is inert where it sits (Dev Containers extension reads it from host user settings, not container-side settings), so a `.gitconfig` from the host still gets copied into the container when the user opens the project via "Reopen in Container" in VS Code. Sandcat's README explicitly promises otherwise.

Two-part fix (belt-and-braces):

1. **Docs correction** — update the comment in `devcontainer.json` and the README section on "Consequences of hardening" so users know the container-side setting alone is not enough; they must also set `dev.containers.copyGitConfig: false` in their host VS Code user settings for full effect. Mirrors the existing note for `terminal.integrated.allowLocalTerminal`.
2. **Runtime cleanup** — regardless of whether the Dev Containers extension copied a `.gitconfig`, `app-user-init.sh` unconditionally removes `/home/vscode/.gitconfig` before applying the sandcat-managed identity from env vars. This closes the actual security gap for users who don't (or can't) modify their host settings.

## Motivation

Reported in issue #34 with a linked review comment from `mattolson/agent-sandbox` PR #108. VS Code's `dev.containers.copyGitConfig` setting is a **host-side extension setting**, not a container VS Code server setting:

- The Dev Containers extension runs on the host.
- It reads the setting from the host's user (or workspace) settings.json.
- The copy operation happens BEFORE the container starts, or at container-attach time, but always from host-side context.
- `devcontainer.json`'s `customizations.vscode.settings` block is delivered to the VS Code server that runs inside the container — a different process, activated after the copy has already happened.

Result: sandcat's setting is placed in the container-side settings and never seen by the entity that decides whether to copy.

Concrete impact when a `.gitconfig` sneaks in:

- `credential.helper = osxkeychain` / `manager` → doesn't work in Linux container, may prompt for password or fail silently
- `user.signingkey` + `commit.gpgsign = true` → every commit tries to sign, GPG unavailable in container → all commits fail
- Custom credential helper paths → agent may probe those, subtle behavior changes
- `.gitconfig` overrides sandcat's env-derived `GIT_USER_NAME`/`GIT_USER_EMAIL` depending on write order → identity confusion

None of these are a full credential leak (Mac keychain is unreachable from Linux; GPG keys aren't in the config file itself), but they violate sandcat's documented promise and produce surprising behavior.

## Non-Goals

- Not offering an "opt-in to copy gitconfig" flag. Users who want their host's gitconfig can set their own git config in the container via env vars (`GIT_USER_NAME`, `GIT_USER_EMAIL`) or a post-start script; sandcat's default posture stays "clean state, no host state carried over."
- Not intercepting or preventing the VS Code Dev Containers extension's copy at the extension level. The extension is host-side, sandcat runs in the container — we can only clean up after.
- Not changing the container-side setting's placement. Keeping it in `devcontainer.json` still documents intent to any reader browsing the file; removing it would hide a signal.

## Design

### Setting the record straight — docs update

Two files need documentation updates:

**`cli/templates/devcontainer/devcontainer.json`** — update the comment above `"dev.containers.copyGitConfig": false` (currently lines 37-39) to match the style of the `terminal.integrated.allowLocalTerminal` comment (lines 44-47). Concrete new text:

```json
// Signal our intent to VS Code that host .gitconfig should not be
// copied into the container (which can leak credential helpers and
// signing key references). NOTE: this setting is read by VS Code's
// Dev Containers extension from HOST user settings, not from this
// file, so it only takes full effect if you also set
// "dev.containers.copyGitConfig": false in your host user settings.
// See README for details. app-user-init.sh removes any .gitconfig
// that gets through as a defense-in-depth cleanup.
"dev.containers.copyGitConfig": false,
```

**`README.md`** — update the corresponding bullet in "Consequences of hardening" (currently line 1320-1322) to note that (a) this setting must also be in host user settings for full effect, and (b) sandcat also cleans up defensively at container start.

### Runtime cleanup — `app-user-init.sh`

Add a cleanup step early in `cli/templates/devcontainer/sandcat/scripts/app-user-init.sh`, before the block that applies `GIT_USER_NAME`/`GIT_USER_EMAIL` from env:

```bash
# Sandcat's design intent (see devcontainer.json's copyGitConfig setting):
# the agent starts with a clean git state; identity comes from the
# GIT_USER_NAME / GIT_USER_EMAIL env vars sourced from sandcat.env.
# VS Code's Dev Containers extension may have copied the host's
# ~/.gitconfig anyway (its copyGitConfig setting is read from HOST
# user settings, not from devcontainer.json — see issue #34). Delete
# anything the extension left behind so it can't leak host credential
# helpers, signing keys, or override our env-derived identity.
rm -f "$HOME/.gitconfig"
```

Unconditional, no configuration flag. Rationale: the template's `copyGitConfig: false` already declares intent; the cleanup honors that intent regardless of whether the host settings agree.

### Interaction with the existing git-identity apply

Current `app-user-init.sh` sets git identity from env vars. That block runs `git config --global user.name "..." / user.email "..."` — which WRITES to `$HOME/.gitconfig`. So the sequence:

1. Container starts. Dev Containers extension may have already copied host `.gitconfig`.
2. `app-init.sh` runs (root), drops to vscode.
3. `app-user-init.sh` runs (vscode).
4. **NEW**: `rm -f "$HOME/.gitconfig"` — deletes anything left over.
5. Existing block: `git config --global user.name "$GIT_USER_NAME"` etc. — recreates the file with sandcat-managed identity only.

Ordering matters: the cleanup MUST happen before the `git config` calls, or those calls would run against the ghost file and produce a merged result rather than a clean-slate `.gitconfig`.

## Data flow

```
Host                                             Container
━━━━━━━━━━━━━━━━━━━━━━━━                          ━━━━━━━━━━━━━━━━━━━━━━━━
VS Code + Dev Containers ext
       │
       │  If host user settings lack
       │  copyGitConfig:false, copies
       │  ~/.gitconfig into container
       ▼
                                       /home/vscode/.gitconfig (from host)
                                                     │
                                                     │  container start
                                                     ▼
                                             app-init.sh (root)
                                                     │
                                                     │  drop to vscode + su -c
                                                     ▼
                                             app-user-init.sh
                                                     │
                                                     │  NEW: rm -f ~/.gitconfig
                                                     │
                                                     │  git config --global \
                                                     │      user.name=$GIT_USER_NAME
                                                     │      user.email=$GIT_USER_EMAIL
                                                     ▼
                                             clean ~/.gitconfig with only
                                             sandcat-managed identity
```

## Security model

| Aspect | Current (buggy) | With this fix |
|---|---|---|
| Host `.gitconfig` reaches container | Yes, when host user settings don't have `copyGitConfig:false` | Yes, extension still copies, but sandcat removes it before agent runs |
| Agent sees host credential helpers / signing key IDs | Yes | No (removed by app-user-init.sh) |
| `commit.gpgsign` triggers failed signing in the agent | Yes | No |
| Sandcat's env-derived git identity applies | Sometimes (depends on write order) | Always |
| Docs match runtime behavior | No | Yes |
| Setting removable in a future opt-in feature | Yes, one flag change | Yes, one flag change |

## Error cases

| Case | Behavior |
|---|---|
| `.gitconfig` absent when `rm -f` runs | `-f` swallows "no such file", `rm` exits 0. No effect. |
| `.gitconfig` present but unreadable by vscode user | Shouldn't happen (copied file is owned by vscode); if it does, `rm -f` still deletes because ownership matters, not readability. |
| `$HOME` not set | app-user-init.sh runs as vscode from `su - vscode -c`, `$HOME` is always set to `/home/vscode`. |
| Multiple starts of same container | idempotent — each start, cleanup runs, identity is reapplied from env. Repeat is a no-op after the first. |
| User adds custom `git config` entries after startup | Removed on next start. Documented consequence — customization goes via env or a post-start script, not by editing `.gitconfig` in-container. |

## Testing

- **bats** unit tests for `app-user-init.sh` are limited (the script is shell run under su); instead:
  - **integration** in a real Docker container:
    1. Init a scratch project (any agent).
    2. Start the stack, wait healthy.
    3. Simulate the Dev Containers extension's copy: `docker cp` a fake `.gitconfig` with a suspicious payload (`user.signingkey = TESTKEY`, `credential.helper = osxkeychain`) into `/home/vscode/.gitconfig` — mimic what VS Code would have done on startup.
    4. Trigger `app-user-init.sh` (either restart agent, which re-runs it, or `docker exec` the script directly).
    5. Verify `/home/vscode/.gitconfig` is either absent, or present but contains only sandcat-managed keys (`user.name` + `user.email` matching env; no `signingkey`, no `credential.helper`).
    6. Verify git operations still succeed (`git config --global user.name`, `git commit` on a scratch file).

Additional smoke: `docker compose exec agent bash -lc 'git config --global --list'` returns only sandcat-set keys.

## Documentation

- `README.md`: update the "Disables git config copying" bullet in the "Hardening" list AND the "Git identity" paragraph in "Consequences of hardening" to reflect both the docs correction and the runtime cleanup.
- `devcontainer.json` inline comment: revised text (see design section).

## Global Constraints

- Cleanup happens **before** the git-config apply block in `app-user-init.sh`. Ordering is critical; write a comment explaining why.
- Cleanup is **unconditional** — no env-var toggle, no feature flag. If a future opt-in is added, it's a separate PR.
- No changes to `cli/lib/agents.bash` or other per-agent dispatchers — this fix applies to ALL agents identically.
- No changes to the Docker image build (Dockerfile.app) — cleanup runs at agent-user-init time, from a bash script.
- Backwards-compatible: existing sandcat projects that already have `.gitconfig` in their agent-home volume will see it removed on the next container start. Users who set custom git config manually inside the container should move that customization to env vars or a post-start hook (documented consequence).
