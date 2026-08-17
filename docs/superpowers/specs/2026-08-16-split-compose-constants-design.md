# Split constant compose entries out of compose-all.yml — Design

## Goal

Implement issue #22: reduce cognitive load in the user-facing `compose-all.yml` by moving the agent service's **constant** (non-user-editable) entries into a new included file `sandcat/compose-agent.yml`, leaving only the **user-customizable** parts (volumes, environment) at the top level.

## Motivation

`compose-all.yml` is the file sandcat tells users to edit (uncomment optional mounts, tune per-path workspace mounts, disable shared caches). Today it interleaves those knobs with security-critical constants (`network_mode`, `security_opt`, `depends_on`, constant volume mounts). Splitting them:

- makes the user-editable surface obvious at a glance;
- reduces the chance a user accidentally deletes `network_mode: "service:wg-client"` or `security_opt: no-new-privileges` while editing mounts;
- mirrors the already-established pattern — the proxy stack (wg-client + mitmproxy) was long ago extracted to `sandcat/compose-proxy.yml`.

## Mechanism — include + override merge (already load-bearing)

Docker Compose merges a service partially defined in the **including** file with the same-named service from an **included** file. Sandcat already relies on this: the generated `compose-all.yml` contains a partial `services.mitmproxy` (the `.sandcat:/config/project:ro` mount) merged over the full mitmproxy definition in the included `compose-proxy.yml`. Every running sandcat installation exercises this semantics — no new Compose version requirement, no new risk surface (including JetBrains Gateway, which already works with the current include).

The refactor extends the same pattern to the agent service.

## Target file shapes

### New: `cli/templates/devcontainer/sandcat/compose-agent.yml`

```yaml
# Constant (non-user-editable) parts of the agent service. User-customizable
# parts — volumes, environment — live in ../compose-all.yml and are merged
# over this base by Docker Compose's include-override mechanism.
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

### Slimmed: `cli/templates/devcontainer/compose-all.yml`

```yaml
include:
  - path: sandcat/compose-proxy.yml
  # Constant (non-user-editable) parts of the agent service — image build,
  # security hardening, network wiring, dependency ordering. The service
  # entries below are merged OVER that base.
  - path: sandcat/compose-agent.yml

services:
  # User-customizable parts of the agent service (volumes, environment).
  # sandcat init populates this section; edit or uncomment entries freely —
  # the security-critical base stays in sandcat/compose-agent.yml.
  agent: {}
```

Notes:
- `agent: {}` is a valid stub; `sandcat init` immediately populates `working_dir`, workspace mounts, agent-config mounts, caches, and `environment` via the existing yq helpers (all of which create keys on demand — `yq '.a += [x]'` materializes missing paths).
- The top-level `volumes: agent-home:` declaration moves to `compose-agent.yml` (it's constant). Cache volume declarations (`sandcat-cache-*`, `external: true`) keep being appended to `compose-all.yml` by `add_shared_cache_volumes` — they're user-toggleable.
- The `build.context` changes from `.` to `..` because included-file paths resolve relative to the included file's directory (`sandcat/`). Same convention `compose-proxy.yml` already uses for `Dockerfile.wg-client` (context `.` = `sandcat/`).

## What does NOT change

- Entry point stays `-f compose-all.yml` everywhere (`sandcat run`, `restart-proxy`, `destroy`, `find_compose_file`, VS Code `dockerComposeFile`, JetBrains).
- All CLI yq-edit helpers keep targeting `compose-all.yml`: `set_workspace`, `add_volume_entry` (+ commented entries with foot comments — workspace mounts land first, so the "non-empty array" precondition for `add_foot_comment` still holds), `add_settings_volume` (mitmproxy override — unchanged pattern), `add_shared_cache_volumes`, `add_jetbrains_capabilities` (`cap_add` merges additively across include-override), `merge_compose_agent_environment`.
- Template copy path: `cp -R "$SCT_TEMPLATEDIR/devcontainer/." "$devcontainer_dir/"` picks up the new file automatically.
- Regression tests (`cli/test/init/regression.bats`) assert against `docker compose config` — the **merged effective** config — so `network_mode`, `security_opt`, `agent-home` etc. still appear exactly as before. These tests are the safety net proving behavior identity.

## Risks / mitigations

| Risk | Mitigation |
|---|---|
| `build.context` mis-resolved from included file | Integration test builds the image (`docker compose build agent` must succeed; COPY paths in Dockerfile.app depend on correct context) |
| Some bats test greps the compose-all **template** for moved keys | Run full bats surface; fix any template-shape assertions to point at compose-agent.yml |
| Older docker compose versions on user machines mishandle agent include-override | Same mechanism as the existing mitmproxy override — any version running sandcat today already supports it |
| `cap_add` from `add_jetbrains_capabilities` lands in override while base has none | Compose merge unions lists; `docker compose config` in the jetbrains regression test verifies |
| Existing generated projects | Unaffected — old self-contained compose-all.yml keeps working; new layout appears on re-init |

## Testing

- Full bats surface (all `cli/test/*` suites) green.
- Regression suite (`regression.bats`) — runs `docker compose config`; must pass unchanged (proves effective-config identity).
- Hands-on integration: fresh `sandcat init`, `docker compose config` shows merged agent (network_mode + security_opt + depends_on + build present), full `up -d --build`, agent networking through proxy works, `NoNewPrivs: 1` in `/proc/self/status`, `sudo` blocked, `sandcat restart-proxy` still restarts agent (the #69 fix references the `agent` service by name — unchanged).

## Documentation

- `README.md:565` — the "compose-all.yml — network_mode routes all traffic..." bullet needs to say the constant lives in `sandcat/compose-agent.yml` now.
- `README.md:23` — template file list gains `sandcat/compose-agent.yml`.

## Global Constraints

- New file path: `cli/templates/devcontainer/sandcat/compose-agent.yml`.
- Moved fields: `build`, `security_opt`, `network_mode`, the 3 constant volume mounts, `command`, `depends_on`, top-level `volumes: agent-home:`. Comments move with their fields verbatim.
- `build.context: ..` + `dockerfile: Dockerfile.app` in the new file (path relative to `sandcat/`).
- `compose-all.yml` keeps: `include` list (proxy + agent base), `services.agent: {}` stub with guidance comment.
- No changes to any `cli/lib/*.bash` or `cli/libexec/*` logic — yq helpers already create keys on demand.
- All existing tests must pass without weakening assertions; template-shape assertions may be re-pointed to the new file but not deleted.
