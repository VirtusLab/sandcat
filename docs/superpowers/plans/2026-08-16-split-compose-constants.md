# Split Compose Constants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Issue #22 — move the agent service's constant entries from the user-facing `compose-all.yml` template into a new included `sandcat/compose-agent.yml`, using the include-override merge mechanism that sandcat's generated compose already relies on for the mitmproxy settings mount.

**Architecture:** Pure template refactor. New file `cli/templates/devcontainer/sandcat/compose-agent.yml` holds `build` (context `..`), `security_opt`, `network_mode`, 3 constant mounts, `command`, `depends_on`, and the `agent-home` volume declaration. `compose-all.yml` shrinks to the include list + a `services.agent: {}` stub that `sandcat init` populates with user-customizable entries (workspace mounts, agent config mounts, caches, environment). No CLI bash-logic changes — all yq helpers create keys on demand and keep targeting `compose-all.yml`.

**Tech Stack:** YAML templates, bats, docker compose (config-render regression tests).

## Global Constraints

- New file: `cli/templates/devcontainer/sandcat/compose-agent.yml`. Exact contents specified in Task 1 — comments move verbatim with their fields.
- `build.context: ..` and `dockerfile: Dockerfile.app` in the new file (included-file paths resolve relative to `sandcat/`).
- Moved out of `compose-all.yml`: `build`, `security_opt`, `network_mode`, mounts `agent-home:/home/vscode`, `mitmproxy-config:/mitmproxy-config:ro`, `wg-runtime:/run/sandcat:ro`, `command: sleep infinity`, `depends_on`, top-level `volumes: agent-home:`.
- `compose-all.yml` keeps: `include` (proxy + agent base, with a comment explaining the split) and `services.agent: {}` stub with a guidance comment.
- Zero changes to `cli/lib/*.bash` and `cli/libexec/*`.
- All existing bats tests pass; template-shape assertions may be re-pointed to the new file, never deleted or weakened.
- Regression suite (`cli/test/init/regression.bats`, asserts on `docker compose config` output) must pass **unchanged** — it proves effective-config identity.

---

### Task 1: Template split

**Files:**
- Create: `cli/templates/devcontainer/sandcat/compose-agent.yml`
- Modify: `cli/templates/devcontainer/compose-all.yml`
- Test: run existing suites; fix template-shape assertions if any grep the old location (check `cli/test/wg-client/dns_conf_contract.bats` — it asserts `wg-runtime:/run/sandcat:ro` is mounted in the **agent** service; re-point the file it reads from `compose-all.yml` to `sandcat/compose-agent.yml` if it reads templates directly).

**Interfaces:**
- Consumes: nothing.
- Produces: two-file template; generated projects get both via the existing `cp -R` in `cli/libexec/init/devcontainer:91`.

- [ ] **Step 1: Create `cli/templates/devcontainer/sandcat/compose-agent.yml`**

```yaml
# Constant (non-user-editable) parts of the agent service. User-customizable
# parts — volumes, environment — live in ../compose-all.yml and are merged
# over this base by Docker Compose's include-override mechanism (the same
# mechanism compose-all.yml already uses to add the project-settings mount
# to the mitmproxy service defined in compose-proxy.yml).
services:
  agent:
    build:
      # Paths in an included compose file resolve relative to THIS file's
      # directory (sandcat/), so the context points one level up at
      # .devcontainer/, where Dockerfile.app lives.
      context: ..
      dockerfile: Dockerfile.app
    # We set `no-new-privileges` to true to "disable container processes from
    # gaining new privileges."
    # https://docs.docker.com/reference/cli/docker/container/run/#security-opt
    # https://docs.docker.com/reference/compose-file/services/#security_opt
    # https://www.kernel.org/doc/Documentation/prctl/no_new_privs.txt
    security_opt:
      - no-new-privileges
    # Share wg-client's network namespace so all traffic goes through its
    # WireGuard tunnel. The app container has no NET_ADMIN capability,
    # so processes inside cannot modify routing, iptables, or the tunnel.
    network_mode: "service:wg-client"
    volumes:
      # Named volume for the home directory so Claude Code auth state,
      # shell history, and other user-level config persist across rebuilds.
      - agent-home:/home/vscode
      # Shared volume from mitmproxy containing the CA cert and
      # sandcat.env (env vars + secret placeholders). Read-only — app
      # containers should never write to this.
      - mitmproxy-config:/mitmproxy-config:ro
      # Resolv.conf published by wg-client. We copy it into /etc/resolv.conf
      # in app-init.sh so DNS goes to wg-client's local dnsmasq instead of
      # whatever Docker initialized this container's resolv.conf to.
      - wg-runtime:/run/sandcat:ro
    command: sleep infinity
    depends_on:
      wg-client:
        condition: service_healthy

volumes:
  agent-home:
```

- [ ] **Step 2: Replace `cli/templates/devcontainer/compose-all.yml`**

```yaml
include:
  - path: sandcat/compose-proxy.yml
  # Constant (non-user-editable) parts of the agent service — image build,
  # security hardening (no-new-privileges), network wiring through
  # wg-client, dependency ordering. The `services.agent` entries below are
  # merged OVER that base by Docker Compose.
  - path: sandcat/compose-agent.yml

services:
  # User-customizable parts of the agent service (volumes, environment).
  # sandcat init populates this section; edit or uncomment entries freely —
  # the security-critical base stays in sandcat/compose-agent.yml.
  agent: {}
```

- [ ] **Step 3: Sanity-render the raw templates**

Run:
```bash
cd cli/templates/devcontainer && docker compose -f compose-all.yml config >/dev/null && echo TEMPLATE-RENDER-OK
```
Expected: `TEMPLATE-RENDER-OK` (the raw template must be a valid mergeable project — proxy file placeholders like `__AGENT_MITM_ADDON__` are string values, not YAML syntax, so config-render succeeds; if placeholder content breaks rendering, note it and rely on Step 5's generated-project check instead).

- [ ] **Step 4: Run the full bats surface, fix template-shape assertions**

```bash
cd cli
for d in test/agents test/cache test/compat test/composefile test/destroy test/edit test/init test/path test/proxy test/restart-proxy test/rtk test/run test/select test/wg-client; do ./run-tests.bash "$d" || echo "FAILED: $d"; done
```

Expected failures to investigate and fix:
- `test/wg-client/dns_conf_contract.bats` — asserts `wg-runtime:...:ro` in the agent service; if it reads `compose-all.yml` template, re-point to `sandcat/compose-agent.yml`.
- Any `init` test that greps the compose-all template for `network_mode` / `agent-home` — re-point.
- `regression.bats` uses `docker compose config` — must pass with NO edits; if it fails, the split itself is broken (stop and investigate, do not adjust the test).

- [ ] **Step 5: Verify a generated project renders identically**

```bash
T=$(mktemp -d /tmp/issue22-t1.XXXX) && cd "$T" && mkdir proj && cd proj && git init -q
<repo>/cli/bin/sandcat init --agent claude --ide vscode --name issue22-t1 --path . \
  --stacks java --secret-provider none --features "no-rtk,no-gitignore" --proxy web
docker compose -f .devcontainer/compose-all.yml config > /tmp/issue22-t1-effective.yml
yq -e '.services.agent.network_mode == "service:wg-client"' /tmp/issue22-t1-effective.yml
yq -e '.services.agent.security_opt[] | select(. == "no-new-privileges")' /tmp/issue22-t1-effective.yml
yq -e '.services.agent.depends_on | has("wg-client")' /tmp/issue22-t1-effective.yml
yq -e '.services.agent.volumes[] | select(.source == "agent-home")' /tmp/issue22-t1-effective.yml
```
All four yq assertions must pass.

- [ ] **Step 6: Commit**

```bash
git add cli/templates/devcontainer/compose-all.yml cli/templates/devcontainer/sandcat/compose-agent.yml <any adjusted test files>
git commit -m "refactor(templates): split constant agent entries into sandcat/compose-agent.yml (#22)"
```

---

### Task 2: README updates

**Files:**
- Modify: `README.md`

**Interfaces:** docs only.

- [ ] **Step 1: Update the template file list (line ~23)**

Add `sandcat/compose-agent.yml` to the enumeration of `cli/templates/devcontainer/` files.

- [ ] **Step 2: Update the security-architecture bullet (line ~565)**

Current: `**\`compose-all.yml\`** — \`network_mode: "service:wg-client"\` routes all traffic ...`
Change the file reference to `sandcat/compose-agent.yml` (where the constant now lives), and add one sentence noting `compose-all.yml` holds only user-customizable entries merged over that base.

- [ ] **Step 3: Grep for other stale references**

```bash
grep -n "compose-all" README.md
```
Lines describing *user-editable mounts* (~196-340, 685) remain correct — they point at `compose-all.yml` on purpose. Only structural/security descriptions of the moved constants need updating.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: point constant-compose descriptions at sandcat/compose-agent.yml"
```

---

### Task 3: Hands-on integration verification

**Files:** none (evidence for PR body).

- [ ] **Step 1: Fresh project, full build + up**

```bash
T=$(mktemp -d /tmp/issue22-e2e.XXXX) && cd "$T" && mkdir proj && cd proj && git init -q
sandcat init --agent claude --ide none --name issue22-e2e --path . \
  --stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web
docker compose -f .devcontainer/compose-all.yml up -d --build
```
Expected: image builds (proves `build.context: ..` resolves correctly — Dockerfile.app COPY paths depend on it), all three containers healthy.

- [ ] **Step 2: Security constants still effective at runtime**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent grep NoNewPrivs /proc/self/status   # → NoNewPrivs: 1
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent sudo whoami                          # → blocked
```

- [ ] **Step 3: Networking through the proxy works**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" https://github.com   # → 200
```

- [ ] **Step 4: restart-proxy still re-links the agent (regression check for #69)**

```bash
sandcat restart-proxy --path .
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" https://github.com   # → 200 again
```

- [ ] **Step 5: Teardown + write findings**

```bash
docker compose -f .devcontainer/compose-all.yml down -v
```
Record all outcomes in `.superpowers/sdd/2026-08-16-split-compose-constants/task-3-report.md`.

## Out of scope

- Moving the per-project workspace mounts (`..`, `.devcontainer:ro`, `.sandcat:ro`) out of `compose-all.yml` — they're generated per project name and users legitimately tune them (README documents per-path tuning).
- Restructuring `compose-proxy.yml` — already extracted.
- Migration tooling for existing projects — old self-contained compose-all.yml files keep working; new layout arrives on re-init.
