# shlex.quote for sandcat.env Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Issue #19 — replace hand-rolled `_shell_escape` with stdlib `shlex.quote` in `sandcat.env` generation; fix newline value-corruption; update the unit tests that lock the old format.

**Architecture:** One function change in `mitmproxy_addon_common.py` (`_write_placeholders_env` uses `shlex.quote`, `_shell_escape` deleted, `import shlex` added), test updates in `test_mitmproxy_addon.py`, plus a hands-on container verification that a hostile env value arrives bit-perfect.

**Tech Stack:** Python (mitmproxy addon), pytest, Docker for integration.

## Global Constraints

- Line format becomes `export NAME=<shlex.quote(value)>` — no double-quote wrapper.
- `_shell_escape` deleted entirely (verified: only callers are the two lines in `_write_placeholders_env` and its own tests).
- `_validate_env_name` untouched.
- `import shlex` at module level, alphabetically ordered with the existing stdlib imports.
- Tests updated, not weakened: the hostile-input test (`$(rm -rf /)` + backtick) must still exist, asserting the shlex-quoted form; add a round-trip property assertion (`shlex.split` on the emitted line recovers the original value); newline test asserts PRESERVATION (not the old corruption).
- Local pytest cannot run on this host (system Python 3.9 vs `str | None` syntax in the addon) — the implementer verifies via `python3 -m py_compile` + running pytest INSIDE a container if convenient, or defers pytest to CI with the syntax check done. Bats suites are runnable locally and must stay green.

---

### Task 1: Code + unit tests

**Files:**
- Modify: `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_common.py`
- Modify: `cli/test/mitmproxy/test_mitmproxy_addon.py`

**Steps:**

- [ ] **Step 1**: Grep all `_shell_escape` references (`grep -rn "_shell_escape" cli/`) and all format-locking assertions (`grep -n 'export ' cli/test/mitmproxy/test_mitmproxy_addon.py`). List them in the report with dispositions.
- [ ] **Step 2**: In `mitmproxy_addon_common.py`: add `import shlex`; rewrite the two `lines.append` calls in `_write_placeholders_env` to `f"export {name}={shlex.quote(...)}"`; delete `_shell_escape` and its docstring.
- [ ] **Step 3**: Update tests:
  - Assertions like `'export A="SANDCAT_PLACEHOLDER_A"'` → shlex form. NOTE: placeholders match shlex's safe charset, so they emit BARE: `export A=SANDCAT_PLACEHOLDER_A`. Values with spaces/quotes emit single-quoted.
  - The hostile-input test asserts the new quoted form AND adds a round-trip check: parse the emitted line with `shlex.split`, assert the token equals `X=<original hostile value>`.
  - Replace `TestShellEscapingStaticHelpers` with `TestShlexQuoting` (or similar): safe-value-bare, spaces-quoted, newline-preserved-literally (round-trip), `!`-quoted, embedded-single-quote round-trip.
  - Update `test_helpers_inherited_by_variants` (references `_shell_escape`) — delete or re-point.
- [ ] **Step 4**: Verify: `python3 -m py_compile` both files. If a Python ≥3.10 with mitmproxy+pytest is reachable (check `docker run --rm mitmproxy/mitmproxy:12.2.3 python3 -c "import pytest"` — mitmproxy image may lack pytest; alternatively `pip install` inside a throwaway container), run the pytest file; otherwise document CI-deferral. Run bats regression: `cd cli && ./run-tests.bash test/init/` (green — bats doesn't assert env format... verify with grep first; if any bats test asserts `export X="`, update it too).
- [ ] **Step 5**: Commit: `security(mitmproxy): use shlex.quote for sandcat.env generation (#19)`

---

### Task 2: Hands-on integration verification

**Files:** none (evidence for PR body).

**Steps:**

- [ ] **Step 1**: Scratch project (`sandcat init --agent claude --stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web`). Back up `~/.config/sandcat/settings.json`; add a hostile env var:
  ```bash
  yq -i -o json '.env.SANDCAT_E2E_NASTY = "sp ace \"dq\" '\''sq'\'' $(reboot) `tick` $HOME ! end"' ~/.config/sandcat/settings.json
  ```
  (Skip literal newline in settings.json if yq injection is fiddly — cover newline at unit level; note the decision.)
- [ ] **Step 2**: `docker compose up -d --build`; inside agent (login shell): compare `"$SANDCAT_E2E_NASTY"` against the expected literal, byte-for-byte (e.g. `python3 -c 'import os,sys; sys.exit(0 if os.environ["SANDCAT_E2E_NASTY"] == sys.argv[1] else 1)' '<expected>'` or `od -c` diff). Assert `$(reboot)`, backtick, and `$HOME` arrive UNEXPANDED.
- [ ] **Step 3**: Regression: placeholder still exported (`echo $ANTHROPIC_API_KEY` shows `SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY` in login shell) and networking through the proxy works (`curl https://github.com` → 200).
- [ ] **Step 4**: Restore settings backup; teardown `down -v`; write `.superpowers/sdd/2026-08-19-shlex-quote/task-2-report.md`.

## Out of scope

- Escaping in bash templates/heredocs elsewhere in the CLI (different surface, no vault-value flow).
- Any change to `_validate_env_name` or placeholder naming.
