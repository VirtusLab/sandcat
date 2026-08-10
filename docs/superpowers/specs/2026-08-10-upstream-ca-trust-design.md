# Upstream CA Trust — Design

## Goal

Let sandcat users add trusted CA certificates to mitmproxy's **upstream** trust store, so agents can reach internal HTTPS services (self-signed or corporate-CA-signed) through mitmproxy without disabling TLS verification globally.

## Motivation

Sandcat runs mitmproxy as a TLS-intercepting proxy between the agent and upstream services. There are two independent TLS legs:

```
agent  ── TLS #1 ──▶  mitmproxy  ── TLS #2 ──▶  upstream
       (sandcat CA)              (mitmproxy image
                                  trust store)
```

Agent-side (TLS #1) works because `app-init.sh` installs mitmproxy's CA into the agent container's system trust store.

Upstream-side (TLS #2) uses the `mitmproxy/mitmproxy:latest` image's stock Debian CA bundle — public CAs only. Internal services signed by a corporate CA or self-signed fail with `SSLHandshakeException` / `UNKNOWN_CA`.

Issue #64 (Jiří Mareš) is the concrete user need. Current workarounds are all bad:

- `--set ssl_insecure=true` — disables verification for **all** upstreams (MITM window)
- `--set ssl_verify_upstream_trusted_ca=<path>` — **replaces** system trust, loses public CAs
- Custom `Dockerfile.mitmproxy` — user maintains their own image, poor DX

## Non-Goals

- Per-host trust rules (`certificates.<host>` mapping in mitmproxy). Complexity not warranted for v1; users add a CA and it applies to all upstreams that server signs. Same trust model as installing a CA in your OS.
- Automatic CA fetching / rotation.
- Pasting PEM content directly in settings.json.

## Design

### Setting

New field in settings.json (accepted in both **user** settings `~/.config/sandcat/settings.json` and **project** settings `.sandcat/settings.json`):

```json
{
  "upstream_ca_bundles": [
    "/absolute/host/path/to/company-ca.pem",
    "/etc/ssl/private/gitlab-internal.crt"
  ]
}
```

- Type: **array of strings**.
- Values: absolute paths on the host.
- Precedence: user + project entries are **concatenated** (union). No dedup — user is responsible.
- Empty array or missing key: no-op.

### Validation (at `sandcat init`)

For each entry:
1. Path is absolute (starts with `/`).
2. File exists at that path on the host.
3. File is readable by the invoking user.
4. File contains at least one `-----BEGIN CERTIFICATE-----` line (basic PEM sanity).

Any failure → `sandcat init` exits non-zero with a message naming the offending path. This is fail-fast — a missing/malformed CA would silently disable TLS interception for the target host, which is exactly the class of bug the setting exists to prevent.

### Compose rendering

For each bundle entry, `sandcat init` renders a **read-only bind-mount** on the `mitmproxy` service in `compose-proxy.yml`:

```yaml
mitmproxy:
  volumes:
    - /absolute/host/path/to/company-ca.pem:/upstream-ca/000-company-ca.crt:ro
    - /etc/ssl/private/gitlab-internal.crt:/upstream-ca/001-gitlab-internal.crt:ro
```

Naming convention:
- Numbered prefix `NNN-` preserves stable ordering (mount index).
- Basename copied from source path, stripped of directory and any pre-existing extension.
- Extension forced to `.crt` — required by `update-ca-certificates` when copying to `/usr/local/share/ca-certificates/`.

### Runtime — entrypoint extension

`compose-proxy.yml`'s mitmproxy entrypoint is wrapped to add a CA installation step **before** `docker-entrypoint.sh` drops privileges to the `mitmproxy` user. Current entrypoint:

```
["/bin/sh", "-c", "rm -f /home/mitmproxy/.mitmproxy/dns.conf && exec docker-entrypoint.sh \"$@\"", "sh"]
```

New entrypoint:

```
["/bin/sh", "-c",
  "if [ -d /upstream-ca ] && ls /upstream-ca/*.crt >/dev/null 2>&1; then \
      cp /upstream-ca/*.crt /usr/local/share/ca-certificates/ && \
      update-ca-certificates >/dev/null; \
   fi && \
   rm -f /home/mitmproxy/.mitmproxy/dns.conf && \
   exec docker-entrypoint.sh \"$@\"",
 "sh"]
```

Steps:
1. If `/upstream-ca/*.crt` exist (i.e. user configured bundles), copy them to `/usr/local/share/ca-certificates/`.
2. Run `update-ca-certificates` — rebuilds `/etc/ssl/certs/ca-certificates.crt` **extending** the system store (not replacing).
3. Continue with existing entrypoint logic (remove stale dns.conf, exec docker-entrypoint.sh which drops to mitmproxy user).

The mitmproxy `mitmweb`/`mitmdump` process (Python) reads the system trust store via Python's `ssl` module by default → picks up added CAs automatically. No mitmproxy command-line changes needed.

### Data flow

```
~/.config/sandcat/settings.json
       │  { "upstream_ca_bundles": ["/etc/ssl/ca.pem"] }
       ▼
sandcat init
       │  reads settings, validates paths
       │  renders compose-proxy.yml with:
       │    - volumes: [/etc/ssl/ca.pem:/upstream-ca/000-ca.crt:ro]
       │    - entrypoint: [install-ca && original-entrypoint]
       ▼
sandcat run --build
       │  docker compose up
       ▼
mitmproxy container (root phase)
       │  1. copy /upstream-ca/*.crt → /usr/local/share/ca-certificates/
       │  2. update-ca-certificates → /etc/ssl/certs/ca-certificates.crt (extended)
       │  3. docker-entrypoint.sh → drop to mitmproxy user
       ▼
mitmproxy (mitmweb) accepts agent TLS with sandcat CA,
initiates upstream TLS with extended trust store → validates
internal cert successfully → request forwarded
```

## Security Model

| Aspect | Analysis |
|---|---|
| Explicit opt-in | User must add path to settings.json. No implicit trust. |
| Isolation | Bind-mounts are **read-only**, mounted only on `mitmproxy` service. Agent container has no access. |
| Symmetric with OS trust | Adding a CA here is equivalent to installing that CA in your OS — familiar risk. |
| Client-side sandbox unchanged | Agent still sees only sandcat CA. Extending upstream trust does not relax any agent-side check. |
| Blast radius | A CA added here is trusted for **all** upstreams that CA signs. User responsibility to add only CAs they control. Documented in README. |
| Portability | Paths are per-machine (host absolute paths). Same limitation as `extra_hosts` IP addresses. |
| Rotation | User's responsibility. `sandcat init` re-run needed to change bundle paths; `docker compose restart mitmproxy` needed to re-read cert file contents. |
| No privilege escalation surface | CA install runs during mitmproxy container's root phase, before drop to `mitmproxy` user; matches existing entrypoint's privilege model. |

## Error cases

| Case | Behavior |
|---|---|
| `upstream_ca_bundles` absent / empty | No mounts rendered, entrypoint's install-ca branch is a no-op (`/upstream-ca` directory doesn't exist inside the container). |
| Path not absolute | `sandcat init` fails with `upstream_ca_bundles: expected absolute path, got '<value>'`. |
| Path doesn't exist on host | `sandcat init` fails with `upstream_ca_bundles: file not found: <path>`. |
| Path exists but not PEM | `sandcat init` fails with `upstream_ca_bundles: no PEM certificate block in <path>`. |
| Duplicate basenames between user and project settings | Second mount overwrites first in-container (last wins). Order determined by numeric prefix. Not treated as error. |
| File contents change after `sandcat init` | Bind-mount reflects live host file at container start; `docker compose restart mitmproxy` picks up new contents. |
| CA expired | `update-ca-certificates` includes it; mitmproxy honors OS reject-on-expiry via OpenSSL. User-visible error at connect time (matches OS behavior). |

## Testing

- **bats** for compose rendering (`add_upstream_ca_mounts` renders correct volumes given N inputs; no-op for empty; entrypoint patched idempotently).
- **bats** for settings validation (fails on non-absolute paths, missing files, non-PEM content).
- **Integration** in real Docker container:
  1. Scratch project + valid CA path → container starts, `/etc/ssl/certs/ca-certificates.crt` contains the added CA hash, mitmproxy log shows no cert errors.
  2. Reproduce Jiří's scenario: internal HTTPS service with self-signed cert, `extra_hosts` mapping the hostname, agent `curl` succeeds **only** with bundle configured (fails without).
  3. Public HTTPS (e.g. github.com) still works — extension not replacement.

## Documentation

README section under existing TLS/CA discussion:

> ### Trusting internal CAs upstream
> If your organization uses an internal Certificate Authority (for internal Nexus, GitLab, etc.), sandcat's mitmproxy will fail to validate upstream TLS by default (the mitmproxy image ships a stock public CA bundle). Add your CA certificate(s) to `upstream_ca_bundles` in `~/.config/sandcat/settings.json`:
>
> ```json
> {
>   "upstream_ca_bundles": [
>     "/etc/ssl/company-ca.pem"
>   ]
> }
> ```
>
> Paths are absolute on the host. Files are bind-mounted read-only into mitmproxy and installed into its system trust store at container start. Re-run `sandcat init` after changing this setting; changes to the cert file content itself only require `docker compose restart mitmproxy`.

## Global Constraints

- Setting name: **`upstream_ca_bundles`** (plural, array).
- In-container mount path: **`/upstream-ca/`** (read-only bind-mounts).
- In-container installed path: **`/usr/local/share/ca-certificates/`** (standard Debian location for `update-ca-certificates`).
- Mount file naming: `<NNN>-<basename>.crt` where NNN is a 3-digit index and basename is source filename stripped of extension.
- Backwards compatible: absent setting → zero change to existing behavior.
- No new dependencies. `update-ca-certificates` is already present in `mitmproxy/mitmproxy:latest` (Debian 13).
