# Pin Image Versions (issue #20, Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Pin the mitmproxy image chain (public image in generated projects, both derived ghcr secret-provider images) to an exact version with a two-file source of truth enforced by a contract test; make the weekly cron rebuild only the `latest` tracking channel; freeze the rtk install script to a commit SHA.

**Architecture:** CLI side gets `SCT_MITMPROXY_VERSION` in `cli/lib/constants.bash`, consumed by a new `__MITMPROXY_VERSION__` placeholder in the compose-proxy template and by `apply_secret_provider`. Build side gets `images/mitmproxy.env`, consumed by both image workflows as `--build-arg` into `ARG MITMPROXY_VERSION` (no default) in both Dockerfiles. A contract bats test keeps both values equal. Cron passes `MITMPROXY_VERSION=latest` and tags only `latest`; master pushes tag the version.

**Tech Stack:** bash + yq, bats, GitHub Actions, Dockerfiles.

## Global Constraints

- Pinned version at introduction: **12.2.3**.
- CLI constant: `SCT_MITMPROXY_VERSION="12.2.3"` in `cli/lib/constants.bash`.
- Build env file: `images/mitmproxy.env` with `MITMPROXY_VERSION=12.2.3` (comment header explaining it's the build-side source of truth, mirroring `images/mitmproxy-pass/pass-cli.env` style).
- Template placeholder: `__MITMPROXY_VERSION__` in `cli/templates/devcontainer/sandcat/compose-proxy.yml`, replaced in `customize_agent_templates`'s existing `apply_inline_placeholders` call.
- `apply_secret_provider` writes `ghcr.io/virtuslab/sandcat-mitmproxy-op:<version>` / `-pass:<version>` using `$SCT_MITMPROXY_VERSION`.
- Both `images/*/Dockerfile`: `ARG MITMPROXY_VERSION` (no default) + `FROM mitmproxy/mitmproxy:${MITMPROXY_VERSION}`.
- Workflows: master push → build with pinned version, tags = version + sha (NOT latest); schedule → build with `MITMPROXY_VERSION=latest`, tag = latest only; PR → build pinned, no push (preserve current PR push behavior).
- rtk: `raw.githubusercontent.com/rtk-ai/rtk/<full-40-char-sha>/install.sh` with a comment documenting the script-vs-binary pin limitation.
- `regression.bats` `assert_proxy_service` updated from `mitmproxy/mitmproxy:latest` to the pinned reference — a mandated assertion change, not a weakening.
- All existing bats suites green.

---

### Task 1: CLI-side pinning

**Files:**
- Modify: `cli/lib/constants.bash` (add `SCT_MITMPROXY_VERSION="12.2.3"` with a comment pointing at `images/mitmproxy.env` + the contract test)
- Modify: `cli/templates/devcontainer/sandcat/compose-proxy.yml` (`image: mitmproxy/mitmproxy:latest` → `image: mitmproxy/mitmproxy:__MITMPROXY_VERSION__`)
- Modify: `cli/lib/devcontainer.bash` (add the placeholder pair to the existing `apply_inline_placeholders` call that already handles `__MITM_HTTP2__` — around line 283-286)
- Modify: `cli/lib/composefile.bash` (`apply_secret_provider`: both ghcr images get `:` + `$SCT_MITMPROXY_VERSION`; use `env()` injection in yq, matching file style)
- Test: `cli/test/init/regression.bats` (`assert_proxy_service` — pinned image reference), `cli/test/init/extensions.bats` (add: generated compose-proxy.yml contains `mitmproxy/mitmproxy:12.2.3` and no unresolved `__MITMPROXY_VERSION__`), `cli/test/composefile/composefile.bats` (secret-provider tests if they assert the `:latest` ghcr tags — re-point to versioned)

**Interfaces:**
- Consumes: existing placeholder-replacement flow.
- Produces: `SCT_MITMPROXY_VERSION` (Task 2's contract test reads it; Task 4's docs reference it).

**Steps:** (implementer works test-first per file group)

- [ ] **Step 1**: Grep current assertions: `grep -rn "mitmproxy/mitmproxy:latest\|sandcat-mitmproxy-op:latest\|sandcat-mitmproxy-pass:latest" cli/` — every hit is either a change site or a test to update. List them in the report.
- [ ] **Step 2**: Add the constant to `constants.bash`; template placeholder; wire `apply_inline_placeholders`; update `apply_secret_provider`.
- [ ] **Step 3**: Update/extend the tests found in Step 1. New extensions.bats test asserts BOTH: resolved pinned image AND `run grep '__MITMPROXY_VERSION__' ...; assert_failure`.
- [ ] **Step 4**: `cd cli && ./run-tests.bash test/init/ test/composefile/` green; then full surface.
- [ ] **Step 5**: Commit: `security(cli): pin mitmproxy image references to SCT_MITMPROXY_VERSION (#20)`

---

### Task 2: Build-side pinning + workflow tag policy

**Files:**
- Create: `images/mitmproxy.env` (`MITMPROXY_VERSION=12.2.3` + header comment listing consumers)
- Modify: `images/mitmproxy/Dockerfile`, `images/mitmproxy-pass/Dockerfile` (`ARG MITMPROXY_VERSION` no default + parameterized FROM; update the header comment that says "Rebuilt weekly to track mitmproxy:latest" to describe the new dual-channel policy)
- Modify: `.github/workflows/build-mitmproxy-image.yml`, `.github/workflows/build-mitmproxy-pass-image.yml`:
  - add `images/mitmproxy.env` to both `paths` trigger lists
  - a step that reads the env file into `$GITHUB_ENV` (skip on schedule)
  - build-arg: `MITMPROXY_VERSION=${{ github.event_name == 'schedule' && 'latest' || env.MITMPROXY_VERSION }}` (or equivalent two-step logic — implementer picks the cleanest correct form)
  - metadata-action tags: replace the current list with conditional logic — schedule → `latest` only; master push → `<version>` + `sha`; PR → current PR-tag behavior, no push. Verify with `docker/metadata-action` `enable=` expressions or split into two metadata steps guarded by `if:`.
- Test: new contract test `cli/test/compat/mitmproxy_version.bats` — parses `SCT_MITMPROXY_VERSION` from `cli/lib/constants.bash` and `MITMPROXY_VERSION` from `images/mitmproxy.env`, asserts equal. Also asserts both Dockerfiles contain `ARG MITMPROXY_VERSION` and the parameterized FROM (guards against a stray re-hardcode).

**Interfaces:**
- Consumes: `SCT_MITMPROXY_VERSION` from Task 1.
- Produces: `images/mitmproxy.env` (Task 4 documents the bump procedure around it).

**Steps:**

- [ ] **Step 1**: Write the contract test first; run — fails (env file missing).
- [ ] **Step 2**: Create env file, patch both Dockerfiles.
- [ ] **Step 3**: Patch both workflows. Validate YAML: `yq . .github/workflows/build-mitmproxy-image.yml >/dev/null` (and actionlint if available — check `command -v actionlint`).
- [ ] **Step 4**: Local build sanity: `docker build --build-arg MITMPROXY_VERSION=12.2.3 -f images/mitmproxy/Dockerfile images/mitmproxy` succeeds; same with `MITMPROXY_VERSION=latest`.
- [ ] **Step 5**: Contract test green + full bats surface unaffected.
- [ ] **Step 6**: Commit: `security(images): pin mitmproxy base via images/mitmproxy.env; cron rebuilds latest only (#20)`

---

### Task 3: rtk install-script pin

**Files:**
- Modify: `cli/lib/rtk.bash` (`sct_rtk_docker_install_block`)
- Test: `cli/test/rtk/rtk.bats` (if it asserts the master URL — update; add assertion that the URL contains a 40-char SHA)

**Steps:**

- [ ] **Step 1**: Resolve the current rtk master commit: `gh api repos/rtk-ai/rtk/commits/master --jq .sha`. Record it in the report.
- [ ] **Step 2**: Replace `raw.githubusercontent.com/rtk-ai/rtk/master/install.sh` with `.../rtk/<sha>/install.sh`. Extend the comment: script pinned by SHA (freezes the fetched shell code); rtk's install.sh itself downloads a binary release, so the binary is NOT fully pinned until rtk publishes stable releases — revisit then.
- [ ] **Step 3**: `curl -fsSL <pinned URL> | head -5` — sanity that the pinned raw URL serves the script.
- [ ] **Step 4**: `cd cli && ./run-tests.bash test/rtk/` green.
- [ ] **Step 5**: Commit: `security(rtk): pin install script to commit SHA (#20)`

---

### Task 4: Docs — bump procedure + README touch-ups

**Files:**
- Modify: `README.md` and/or `cli/README.md`

**Steps:**

- [ ] **Step 1**: `grep -n "mitmproxy:latest\|mitmproxy/mitmproxy" README.md cli/README.md` — update stale references to reflect pinning.
- [ ] **Step 2**: Add a short "Bumping the pinned mitmproxy version" subsection (likely cli/README.md near the pass-cli.env docs): edit `cli/lib/constants.bash` + `images/mitmproxy.env` (2 lines), the contract test enforces sync, master push publishes the new ghcr version tags, cron only refreshes `latest`.
- [ ] **Step 3**: Commit: `docs: document pinned mitmproxy version + bump procedure`

---

### Task 5: Hands-on integration verification

**Files:** none (evidence for PR body).

- [ ] **Step 1**: Fresh project, provider none: generated `compose-proxy.yml` has `image: mitmproxy/mitmproxy:12.2.3`, no unresolved placeholder; `docker compose up -d --build` (pulls the pinned tag) → all healthy; `curl https://github.com` from agent → 200.
- [ ] **Step 2**: Fresh project, `--secret-provider 1password`: generated compose has `ghcr.io/virtuslab/sandcat-mitmproxy-op:12.2.3`. Rendering-only assertion (`docker compose config`) — the tag publishes to ghcr only after this lands on master; note that in the report. Do NOT `up` this variant.
- [ ] **Step 3**: Local image build both ways (pinned + latest build-arg) — already done in Task 2 Step 4; reference results.
- [ ] **Step 4**: Teardown; write `.superpowers/sdd/2026-08-17-pin-image-versions/task-5-report.md`.

## Out of scope

- Base images (devcontainers/base, debian:trixie-slim) — follow-up.
- Agent CLI + devbox installers — self-updating tools, low pin value.
- Renovate automation (Phase 2), digest pinning (Phase 3).
