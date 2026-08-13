# Split mitmproxy Volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Close the CA private key exposure to the agent container (issue #25) by splitting the single `mitmproxy-config` Docker volume into two: `mitmproxy-config` (private — mounted only to mitmproxy + wg-client) and `mitmproxy-public` (agent-facing — mounted only to mitmproxy + agent). The agent-side path stays `/mitmproxy-config/` so no downstream script changes.

**Architecture:** Interlocking changes across four files that must land in one PR to keep the stack functional: `compose-proxy.yml` (mitmproxy + wg-client volume mounts + healthcheck), `compose-all.yml` (agent volume mount), `mitmproxy_addon_common.py` (redirect agent-visible file writes to public volume, add public-cert seed step), plus tests. Because these are tightly coupled, the plan intentionally groups all code changes into one task and validates via integration.

**Tech Stack:** Docker Compose YAML, Python (mitmproxy addon), bats CLI tests.

## Global Constraints

- Volume names: existing `mitmproxy-config` (narrows scope to private), new `mitmproxy-public` (agent-facing).
- Mitmproxy container: mounts both — `mitmproxy-config` writable at `/home/mitmproxy/.mitmproxy/`, `mitmproxy-public` writable at `/mitmproxy-public/`.
- wg-client container: unchanged mount — `mitmproxy-config:/mitmproxy-config:ro`. wg-client is trusted and reads `wireguard.conf` (private) + `dns.conf` + `extra_hosts` from there.
- Agent container: CHANGED mount — was `mitmproxy-config:/mitmproxy-config:ro`, becomes `mitmproxy-public:/mitmproxy-config:ro`. Path in container unchanged so `app-init.sh` and downstream code don't change.
- Addon constants (`mitmproxy_addon_common.py`): `SANDCAT_ENV_PATH` and `CURSOR_CLI_CONFIG_PATH` change to `/mitmproxy-public/`. `SANDCAT_DNS_CONF_PATH` and `EXTRA_HOSTS_PATH` stay in `.mitmproxy/` (wg-client reads them, not agent).
- Addon gains a `_seed_public_ca_cert()` helper that copies `.mitmproxy/mitmproxy-ca-cert.pem` → `/mitmproxy-public/mitmproxy-ca-cert.pem` on startup, invoked from `load()`.
- Healthcheck on mitmproxy service updated to gate on `/mitmproxy-public/mitmproxy-ca-cert.pem` presence (guarantees agent depends chain works).
- No `sandcat init` template-emission changes needed to header comments (the volume names are declared inside compose-proxy.yml, no yq generation involved).
- No downstream `app-init.sh` / `app-user-init.sh` / `wg-client-init.sh` changes.

---

### Task 1: Compose file topology + addon redirect + CA seed

**Files:**
- Modify: `cli/templates/devcontainer/sandcat/compose-proxy.yml`
- Modify: `cli/templates/devcontainer/compose-all.yml`
- Modify: `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_common.py`
- Test: append to appropriate bats file (e.g. `cli/test/init/extensions.bats` — grep for existing tests that assert compose contents)

**Interfaces:**
- Consumes: nothing.
- Produces: the split-volume topology described above.

- [ ] **Step 1: Read current state**

Files to read before editing:
- `cli/templates/devcontainer/sandcat/compose-proxy.yml` — current volume declarations for mitmproxy + wg-client, healthcheck block
- `cli/templates/devcontainer/compose-all.yml` — current agent volume mount for `mitmproxy-config`
- `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_common.py` — locate `SANDCAT_ENV_PATH`, `CURSOR_CLI_CONFIG_PATH`, `SANDCAT_DNS_CONF_PATH`, `EXTRA_HOSTS_PATH` constants (around lines 60-80). Also locate `load()` method to insert the seed call.

- [ ] **Step 2: `compose-proxy.yml` — add mitmproxy-public volume + mitmproxy mount**

In the `mitmproxy` service's `volumes:` block, append a new entry:

```yaml
      # Agent-facing volume — public CA cert + sandcat.env + cursor-cli-config.
      # Split from mitmproxy-config so the agent container cannot read the CA
      # private key (mitmproxy-ca.pem) or WireGuard private keys
      # (wireguard.conf) — see issue #25.
      - mitmproxy-public:/mitmproxy-public
```

In the top-level `volumes:` block at the bottom of the file, add:

```yaml
volumes:
  mitmproxy-config:
  mitmproxy-public:
  wg-runtime:
```

- [ ] **Step 3: `compose-proxy.yml` — update mitmproxy healthcheck**

Current:

```yaml
test: ["CMD", "sh", "-c", "test -f /home/mitmproxy/.mitmproxy/wireguard.conf && test -f /home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem && test -f /home/mitmproxy/.mitmproxy/dns.conf"]
```

New:

```yaml
test: ["CMD", "sh", "-c", "test -f /home/mitmproxy/.mitmproxy/wireguard.conf && test -f /mitmproxy-public/mitmproxy-ca-cert.pem && test -f /home/mitmproxy/.mitmproxy/dns.conf"]
```

Only the middle predicate changes (public CA cert now lives in `/mitmproxy-public/`, not `.mitmproxy/`).

- [ ] **Step 4: `compose-all.yml` — swap agent's volume**

Find the agent service's volumes block. Replace:

```yaml
      - mitmproxy-config:/mitmproxy-config:ro
```

with:

```yaml
      # Agent gets ONLY the public volume. The mitmproxy-config volume is
      # kept private (mitmproxy + wg-client only) to prevent the untrusted
      # agent from reading CA private key or WireGuard keys — see issue #25.
      - mitmproxy-public:/mitmproxy-config:ro
```

The container-side path stays `/mitmproxy-config/` so app-init.sh and everything downstream is unchanged.

- [ ] **Step 5: `mitmproxy_addon_common.py` — redirect agent-visible file paths**

Locate the constants (around lines 60-80):

```python
SANDCAT_ENV_PATH = "/home/mitmproxy/.mitmproxy/sandcat.env"
CURSOR_CLI_CONFIG_PATH = "/home/mitmproxy/.mitmproxy/cursor-cli-config.json"
SANDCAT_DNS_CONF_PATH = "/home/mitmproxy/.mitmproxy/dns.conf"
EXTRA_HOSTS_PATH = "/home/mitmproxy/.mitmproxy/extra_hosts"
```

Change to:

```python
# Agent-visible files land in the mitmproxy-public volume — mounted RO
# in the agent container as /mitmproxy-config/. See issue #25 for why we
# split the private CA volume from the agent-facing files.
SANDCAT_ENV_PATH = "/mitmproxy-public/sandcat.env"
CURSOR_CLI_CONFIG_PATH = "/mitmproxy-public/cursor-cli-config.json"
# Read by wg-client (trusted, sees the private volume) — stays where it
# already was; no need to duplicate into the public volume.
SANDCAT_DNS_CONF_PATH = "/home/mitmproxy/.mitmproxy/dns.conf"
EXTRA_HOSTS_PATH = "/home/mitmproxy/.mitmproxy/extra_hosts"
```

- [ ] **Step 6: `mitmproxy_addon_common.py` — add `_seed_public_ca_cert` and call from `load()`**

Add a helper method (near other file-writing helpers):

```python
def _seed_public_ca_cert(self):
    """Copy the public CA cert to the mitmproxy-public volume so the
    agent container (which sees only the public volume post-split) can
    trust mitmproxy's TLS. mitmproxy generates the CA lazily on first
    TLS setup; usually ready by the time load() runs, but retry a few
    times in case timing varies. See issue #25.
    """
    src = "/home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem"
    dst = "/mitmproxy-public/mitmproxy-ca-cert.pem"
    for _ in range(10):
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(src, dst)
            ctx.log.info(f"Seeded public CA cert to {dst}")
            return
        time.sleep(1)
    ctx.log.warn(
        f"CA cert not present at {src} after 10s — agent may see no cert"
    )
```

At the top of the file, add `import shutil` and `import time` alongside existing stdlib imports.

Call `self._seed_public_ca_cert()` from inside `load()` — before the existing writes to `SANDCAT_ENV_PATH` etc., to ensure the public volume exists (mkdir + write test) before the agent's healthcheck-gated start.

- [ ] **Step 7: Bats coverage — assert compose file structure**

Find the appropriate bats test file(s):
- `cli/test/init/extensions.bats` typically has tests that grep the copied `compose-proxy.yml` for mitmproxy config.

Add two tests (or extend existing ones) — one for the private volume mount and one for the public volume:

```bash
@test "compose-proxy.yml declares mitmproxy-public volume" {
	yq -e '.volumes | has("mitmproxy-public")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
}

@test "compose-proxy.yml mounts mitmproxy-public writable in mitmproxy" {
	yq -e '.services.mitmproxy.volumes[] | select(. == "mitmproxy-public:/mitmproxy-public")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
}

@test "compose-proxy.yml healthcheck gates on public CA cert" {
	local check
	check=$(yq -r '.services.mitmproxy.healthcheck.test | join(" ")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml")
	[[ "$check" == *"/mitmproxy-public/mitmproxy-ca-cert.pem"* ]]
}

@test "compose-all.yml mounts agent from mitmproxy-public (not mitmproxy-config)" {
	yq -e '.services.agent.volumes[] | select(. == "mitmproxy-public:/mitmproxy-config:ro")' \
		"$SCT_TEMPLATEDIR/devcontainer/compose-all.yml"

	# Regression guard: the old private mount MUST NOT exist on agent.
	run yq -e '.services.agent.volumes[] | select(. == "mitmproxy-config:/mitmproxy-config:ro")' \
		"$SCT_TEMPLATEDIR/devcontainer/compose-all.yml"
	[ "$status" -ne 0 ]
}
```

Run:

```bash
cd cli && ./support/bats/bin/bats test/init/extensions.bats
```

All tests including the four new ones pass. Full CLI suite as regression.

- [ ] **Step 8: Python syntax check on addon**

Since local Python 3.9 can't parse the file's `str | None` syntax, use `py_compile` with `--python 3.10+` or just fall back to smoke-testing via bash: at minimum, verify the file is still valid Python by:

```bash
docker run --rm -v "$(pwd)/cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_common.py:/tmp/addon.py:ro" mitmproxy/mitmproxy:latest python3 -c "import ast; ast.parse(open('/tmp/addon.py').read()); print('OK')"
```

or the Python test suite in `cli/test/mitmproxy/test_mitmproxy_addon.py` (CI runs it on Python 3.12+).

- [ ] **Step 9: Commit**

```bash
git add cli/templates/devcontainer/sandcat/compose-proxy.yml \
        cli/templates/devcontainer/compose-all.yml \
        cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_common.py \
        cli/test/init/extensions.bats
git commit -m "fix(mitmproxy): split volume so agent cannot read CA private key (#25)"
```

---

### Task 2: Hands-on integration verification

**Files:** none modified. Evidence for PR body.

**Interfaces:**
- Consumes: Task 1 changes.
- Produces: PASS/FAIL log for each scenario.

- [ ] **Step 1: Scratch project + build**

```bash
TEST=$(mktemp -d /tmp/mitmproxy-split.XXXX); cd "$TEST" && mkdir proj && cd proj && git init -q
sandcat init --agent claude --ide none --name mitmproxy-split-e2e --path . \
  --stacks "" --secret-provider none --features "no-rtk,no-gitignore" --proxy web
docker compose -f .devcontainer/compose-all.yml up -d --build
```

Wait for all three containers healthy.

- [ ] **Step 2: Assert both volumes exist**

```bash
docker volume ls | grep -E "mitmproxy-(config|public)$"
```

Both should appear.

- [ ] **Step 3: From inside the agent — list what's visible**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent ls -la /mitmproxy-config/
```

Expected: `mitmproxy-ca-cert.pem`, `sandcat.env`, `cursor-cli-config.json` — and NOTHING with `mitmproxy-ca.pem` (private) or `wireguard.conf` in the listing.

- [ ] **Step 4: Agent tries to read the private key — must FAIL**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent \
    cat /mitmproxy-config/mitmproxy-ca.pem 2>&1
```

Expected: `No such file or directory`, exit code ≠ 0.

- [ ] **Step 5: Agent tries to read WireGuard config — must FAIL**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent \
    cat /mitmproxy-config/wireguard.conf 2>&1
```

Expected: `No such file or directory`, exit code ≠ 0.

- [ ] **Step 6: Public functionality still works**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T -u vscode agent bash -lc \
    'echo "-- CA cert readable? --"; head -1 /mitmproxy-config/mitmproxy-ca-cert.pem; \
     echo "-- sandcat.env vars visible? --"; env | grep -c GIT_USER_NAME; \
     echo "-- HTTPS to allowlisted host? --"; curl -sSI https://api.github.com/ | head -1'
```

Expected: all three succeed.

- [ ] **Step 7: wg-client still reads private files (unaffected)**

```bash
docker compose -f .devcontainer/compose-all.yml exec -T wg-client sh -c \
    'ls /mitmproxy-config/wireguard.conf /mitmproxy-config/dns.conf 2>&1'
```

Expected: both files listed, no errors.

- [ ] **Step 8: extra_hosts still applied to wg-client's /etc/hosts**

If extra_hosts configured in settings, verify wg-client's `/etc/hosts` has them. Otherwise skip.

- [ ] **Step 9: Teardown + report**

```bash
docker compose -f .devcontainer/compose-all.yml down -v
```

Write scenarios PASS/FAIL to `.superpowers/sdd/2026-08-12-mitmproxy-volume-split/task-2-report.md`.

---

## Out of scope for this plan

- Rotating the CA. Existing CA lifecycles are unchanged; `docker compose down -v` still regenerates.
- Splitting `wireguard.conf` out to a wg-client-only volume. wg-client already sees the private volume — no additional benefit for the marginal complexity.
- Renaming `mitmproxy-config` to `mitmproxy-private`. Keeping the existing volume name minimises the diff and preserves any existing volume state during upgrade.
