# Sandcat

Sandcat is a Docker & [dev container](https://containers.dev) setup for securely
running AI agents. The environment is sandboxed, with controlled network access
and transparent secret substitution. All of this is done while retaining the
convenience of working in an IDE like VS Code.

All container traffic is routed through a transparent
[mitmproxy](https://mitmproxy.org/) via WireGuard, capturing HTTP/S, DNS, and
all other TCP/UDP traffic without per-tool proxy configuration. A
straightforward allow/deny list-based engine controls which network requests go
through, and a secret substitution system injects credentials at the proxy level
so the container never sees real values.

This repository contains:

* reusable proxy definitions: `Dockerfile.wg-client`, `compose-proxy.yml`, and
  `scripts`
* template application and dev container configuration: `Dockerfile.app`,
  `compose-all.yml`, `devcontainer.json`. This should be fine-tuned for each
  project and specific development stack, to install required tools and
  dependencies.

Sandcat can be used as a devcontainer setup, or standalone through `docker`,
providing a shell for secure development. The repository itself is a runnable
devcontainer setup, so you can clone and explore how things work right away.

## Quick start: try it out

Create a settings file with your secrets and network rules:

```sh
mkdir -p ~/.config/sandcat
cp settings.example.json ~/.config/sandcat/settings.json
# Edit with your real values
```

Then start the container to verify everything works:

```sh
docker compose -f compose-all.yml run --rm --build app bash
```

Inside the container:

```sh
# Should return 200 (mitmproxy CA is trusted)
curl -s -o /dev/null -w '%{http_code}\n' https://example.com

# Check secret substitution (if you configured a GitHub token)
gh auth status
```

See [Testing the proxy](#testing-the-proxy) for more verification steps.

## Add to your project

Sandcat can be installed using one of three methods — a Claude Code prompt, an install script, or a git submodule.
All three methods produce the same target directory layout:

```
.devcontainer/
├── sandcat/                # shared infrastructure (do not edit)
│   ├── compose-proxy.yml
│   ├── Dockerfile.wg-client
│   ├── scripts/
│   │   ├── app-init.sh
│   │   ├── app-post-start.sh
│   │   ├── app-user-init.sh
│   │   ├── mitmproxy_addon.py
│   │   └── wg-client-init.sh
│   └── settings.example.json
├── compose-all.yml         # project-specific (customize)
├── Dockerfile.app          # project-specific (customize)
└── devcontainer.json       # project-specific (customize)
```

### Option 1: Claude Code prompt

Copy the prompt below into Claude Code (or any LLM-based coding agent). It will
run the install script, then inspect your project to customize the generated
files:

````text
Set up a Sandcat dev container for this project:
1. Determine the project name from the repository/directory name.
   Run: curl -fsSL https://raw.githubusercontent.com/softwaremill/sandcat/master/install.sh | bash -s -- --name <project-name>
2. Read https://raw.githubusercontent.com/softwaremill/sandcat/master/README.md
3. Inspect the project's codebase to determine the language toolchains
   and runtimes needed. Modify .devcontainer/Dockerfile.app: add
   `mise use -g` lines in the `USER vscode` section.
4. Add ecosystem-specific VS Code extensions to the extensions list in
   .devcontainer/devcontainer.json (e.g. Scala Metals, Python, ESLint).
5. Check the TLS/CA trust section in the README for any runtime-specific
   configuration needed (e.g. Rust requires using native-roots).
````

### Option 2: Install script

```sh
curl -fsSL https://raw.githubusercontent.com/softwaremill/sandcat/master/install.sh | bash
```

By default the project name is taken from the current directory. To override:

```sh
curl -fsSL https://raw.githubusercontent.com/softwaremill/sandcat/master/install.sh | bash -s -- --name my-project
```

### Option 3: Git submodule

```sh
git submodule add https://github.com/softwaremill/sandcat.git .devcontainer/sandcat
```

Then create the three project-specific files in `.devcontainer/`. You can use
the repo's own files as templates — copy `compose-all.yml`, `Dockerfile.app`,
and `devcontainer.json` from the submodule and make these adjustments:

- **`compose-all.yml`**: change the include path to `sandcat/compose-proxy.yml`
  and the project volume to `..:/workspaces/<your-project>:cached`.
- **`Dockerfile.app`**: change COPY paths to `sandcat/scripts/app-init.sh` and
  `sandcat/scripts/app-user-init.sh`.
- **`devcontainer.json`**: change `dockerComposeFile` to `compose-all.yml`
  (not `../compose-all.yml`), and update `name`, `workspaceFolder`, and
  `postStartCommand` to use your project name.

### Customizing the generated files

**`compose-all.yml`** — `network_mode: "service:wg-client"` routes all traffic
through the WireGuard tunnel. The `mitmproxy-config` volume gives your container
access to the CA cert, env vars, and secret placeholders. The `~/.claude/*`
bind-mounts forward host Claude Code customizations — remove any mount whose
source does not exist on your host.

**`Dockerfile.app`** — uses [mise](https://mise.jdx.dev/) to manage language
toolchains. Look for the `CUSTOMIZE` marker and add `mise use -g` lines for
your stack:

| Stack | mise command | CA trust notes |
|-------|-------------|----------------|
| TypeScript / Node.js | `mise use -g node@lts` (already installed) | Handled automatically by `app-init.sh` |
| Python | `mise use -g python@3.13` | Uses system store — works out of the box |
| Rust | `mise use -g rust@latest` | Use `rustls-tls-native-roots` in reqwest |
| Java | `mise use -g java@21` | Handled automatically by `app-user-init.sh` |

Some runtimes need extra configuration to trust the mitmproxy CA — see [TLS and
CA certificates](#tls-and-ca-certificates).

**`devcontainer.json`** — includes VS Code hardening settings (credential
socket cleanup, workspace trust, disabled local terminal). See
[Hardening the VS Code setup](#hardening-the-vs-code-setup) for details.

## Settings format

`~/.config/sandcat/settings.json`:

```json
{
  "env": {
    "GIT_USER_NAME": "Your Name",
    "GIT_USER_EMAIL": "you@example.com"
  },
  "secrets": {
    "ANTHROPIC_API_KEY": {
      "value": "sk-ant-real-key-here",
      "hosts": ["api.anthropic.com"]
    }
  },
  "network": [
    {"action": "allow", "host": "*", "method": "GET"},
    {"action": "allow", "host": "*.github.com", "method": "POST"},
    {"action": "allow", "host": "*.anthropic.com"},
    {"action": "allow", "host": "*.claude.com"}
  ]
}
```

Warning: allowing all GET-traffic, all traffic from GitHub or in fact any
not-fully-trusted/controlled site, leaves the possibility of a prompt injection
attack. Blocking `POST`-traffic might prevent code from being exfiltrated, but
malicious code might still be generated as part of the project.

## Network access rules

The `network` array defines ordered access rules evaluated top-to-bottom. First
matching rule wins (like iptables). If no rule matches, the request is
**denied**.

Each rule has:
- `action` — `"allow"` or `"deny"` (required)
- `host` — glob pattern via fnmatch (required)
- `method` — HTTP method to match; omit to match any method (optional)

### Examples

With the rules above:
- `GET` to any host → **allowed** (rule 1)
- `POST` to `api.github.com` → **allowed** (rule 2)
- `POST` to `api.anthropic.com` → **allowed** (rule 3)
- `POST` to `example.com` → **denied**
- `PUT` to `example.com` → **denied**
- Empty network list → all requests **denied** (default deny)

## Secret substitution

Dev containers never see real secret values. Instead, environment variables
contain deterministic placeholders (`SANDCAT_PLACEHOLDER_<NAME>`), and the
mitmproxy addon replaces them with real values when requests pass through the
proxy.

Inside the container, `echo $ANTHROPIC_API_KEY` prints
`SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY`. When a request containing that
placeholder reaches mitmproxy, it's replaced with the real key — but only if the
destination host matches the `hosts` allowlist.

### Host patterns

The `hosts` field accepts glob patterns via `fnmatch`:

- `"api.anthropic.com"` — exact match
- `"*.anthropic.com"` — any subdomain
- `"*"` — allow all hosts (use with caution)

### Leak detection

If a placeholder appears in a request to a host **not** in the allowlist,
mitmproxy blocks the request with HTTP 403 and logs a warning. This prevents
accidental secret leakage to unintended services.

### How it works internally

1. The mitmproxy container mounts `~/.config/sandcat/settings.json` (read-only)
   and the `mitmproxy_addon.py` addon script.
2. On startup, the addon reads `settings.json` and writes `sandcat.env` to the
   `mitmproxy-config` shared volume (`/home/mitmproxy/.mitmproxy/sandcat.env`).
   This file contains plain env vars (e.g. `export GIT_USER_NAME="Your Name"`)
   and secret placeholders (e.g. `export
   ANTHROPIC_API_KEY="SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY"`).
3. App containers mount `mitmproxy-config` read-only at `/mitmproxy-config/`.
   The shared entrypoint (`app-init.sh`) sources `sandcat.env` after installing
   the CA cert, so every process gets the env vars and placeholder values.
4. On each request, the addon first checks network access rules. If denied, the
   request is blocked with 403.
5. If allowed, the addon checks for secret placeholders in the request, verifies
   the destination host against the secret's allowlist, and either substitutes
   the real value or blocks the request with 403 (leak detection).

Real secrets never leave the mitmproxy container.

### Disabling

Delete or rename `~/.config/sandcat/settings.json`. If the file is absent, the
addon disables itself — no network rules are enforced and `sandcat.env` is not
written.

### Claude Code

Claude Code ignores `ANTHROPIC_API_KEY` until onboarding is complete. Without
`{"hasCompletedOnboarding": true}` in `~/.claude.json`, it prompts for
browser-based login instead of using the key. The dev container Dockerfile sets
this during the build, so Claude Code picks up the API key from secret
substitution without manual setup.

**Autonomous mode.** The bundled `devcontainer.json` enables
`claudeCode.allowDangerouslySkipPermissions` and sets
`claudeCode.initialPermissionMode` to `bypassPermissions`. This lets Claude Code
run without interactive permission prompts inside the container. The trade-off:
sandcat already provides the security boundary (network isolation, secret
substitution, iptables kill-switch), so the in-container prompts add friction
without meaningful security benefit. Remove these settings if you prefer
interactive approval. See [Secure & Dangerous Claude Code + VS Code
Setup](https://warski.org/blog/secure-dangerous-claude-code-vs-code-setup/) for
background on this approach.

**Host customizations.** The example `compose-all.yml` bind-mounts
`~/.claude/CLAUDE.md`, `~/.claude/agents`, and `~/.claude/commands` from the
host (read-only) so your personal instructions, custom agents, and slash
commands are available inside the container. Remove any mount whose source does
not exist on your host — Docker will otherwise create an empty directory in its
place.

## Architecture

### Containers and network

```mermaid
flowchart LR
    app["<b>app</b><br/><i>no NET_ADMIN</i><br/>your code runs here"]
    wg["<b>wg-client</b><br/><i>NET_ADMIN</i><br/>WireGuard + iptables"]
    mitm["<b>mitmproxy</b><br/><i>mitmweb</i><br/>network rules &amp;<br/>secret substitution"]
    inet(("internet"))

    app -- "network_mode:<br/>shares net namespace" --- wg
    wg -- "WireGuard<br/>tunnel" --> mitm
    mitm -- "allowed<br/>requests" --> inet

    style app fill:#e8f4fd,stroke:#4a90d9
    style wg fill:#fdf2e8,stroke:#d9904a
    style mitm fill:#e8fde8,stroke:#4ad94a
```

- **mitmproxy** runs `mitmweb --mode wireguard`, creating a WireGuard server and
  storing key pairs in `wireguard.conf`.
- **wg-client** is a dedicated networking container that derives a WireGuard
  client config from those keys, sets up the tunnel with `wg` and `ip` commands,
  and adds iptables kill-switch rules. Only this container has `NET_ADMIN`. No
  user code runs here.
- **App containers** share `wg-client`'s network namespace via `network_mode`.
  They inherit the tunnel and firewall rules but cannot modify them (no
  `NET_ADMIN`). They install the mitmproxy CA cert into the system trust store
  at startup so TLS interception works.
- The mitmproxy web UI is exposed on a dynamic host port (see below) to avoid
  conflicts when multiple projects include sandcat. Password: `mitmproxy`.

### Volumes

The containers communicate through two shared volumes and several bind-mounts
from the host:

```mermaid
flowchart TB
    subgraph volumes["Shared volumes"]
        mc["<b>mitmproxy-config</b><br/><i>wireguard.conf</i><br/><i>mitmproxy-ca-cert.pem</i><br/><i>sandcat.env</i>"]
        ah["<b>app-home</b><br/><i>/home/vscode</i><br/>persists Claude Code state,<br/>shell history across rebuilds"]
    end

    subgraph host["Host bind-mounts (read-only)"]
        settings["~/.config/sandcat/<br/>settings.json"]
        claude["~/.claude/<br/>CLAUDE.md, agents/, commands/"]
    end

    mitm["mitmproxy"] -- "read-write" --> mc
    wg["wg-client"] -- "read-only" --> mc
    app["app"] -- "read-only" --> mc
    app -- "read-write" --> ah
    settings -. "bind-mount" .-> mitm
    claude -. "bind-mount" .-> app

    style mc fill:#f0e8fd,stroke:#904ad9
    style ah fill:#f0e8fd,stroke:#904ad9
    style settings fill:#fde8e8,stroke:#d94a4a
    style claude fill:#fde8e8,stroke:#d94a4a
```

- **`mitmproxy-config`** is the key shared volume. Mitmproxy writes to it
  (WireGuard keys, CA cert, `sandcat.env` with env vars and secret
  placeholders); all other containers mount it read-only.
- **`app-home`** persists the vscode user's home directory across container
  rebuilds (Claude Code auth, shell history, git config).
- **`settings.json`** is bind-mounted from the host into mitmproxy only — app
  containers never see real secrets.
- **Claude Code customizations** (`CLAUDE.md`, `agents/`, `commands/`) are
  bind-mounted from the host into the app container read-only.

### Startup sequence

The containers start in dependency order. Each step writes data to the shared
`mitmproxy-config` volume that the next step reads:

```mermaid
sequenceDiagram
    participant M as mitmproxy
    participant W as wg-client
    participant A as app

    Note over M: starts first (no dependencies)
    M->>M: Start WireGuard server
    M->>M: Generate wireguard.conf (key pairs)
    M->>M: Read settings.json
    M->>M: Write sandcat.env (env vars + secret placeholders)
    M->>M: Write mitmproxy-ca-cert.pem
    Note over M: healthcheck passes<br/>(wireguard.conf exists)

    Note over W: starts after mitmproxy is healthy
    W->>W: Read wireguard.conf from shared volume
    W->>W: Derive WireGuard client keys
    W->>W: Create wg0 interface + routing
    W->>W: Set up iptables kill switch
    W->>W: Configure DNS via tunnel
    Note over W: healthcheck passes<br/>(/tmp/wg-ready exists)

    Note over A: starts after wg-client is healthy
    A->>A: Read CA cert from shared volume
    A->>A: Install CA into system trust store
    A->>A: Set NODE_EXTRA_CA_CERTS
    A->>A: Source sandcat.env (env vars + secret placeholders)
    A->>A: Run app-user-init.sh (git identity, etc.)
    A->>A: Drop to vscode user, exec main command
    Note over A: ready for use
```

## Hardening the VS Code setup

Sandcat secures the **network path** out of the container, but VS Code's dev
container integration introduces a separate trust boundary. The VS Code remote
architecture gives container-side extensions access to host resources
(terminals, credentials, clipboard) through the IDE channel, bypassing
network-level controls entirely.

For background on these attack vectors see [Leveraging VS Code Internals to
Escape
Containers](https://blog.theredguild.org/leveraging-vscode-internals-to-escape-containers/).

### What the bundled devcontainer.json already does

The included `devcontainer.json` applies the following mitigations out of the
box:

- **Clears forwarded credential sockets** (`SSH_AUTH_SOCK`, `GPG_AGENT_INFO`,
  `GIT_ASKPASS`) via `remoteEnv` so container code cannot piggyback on host SSH
  keys, GPG signing, or VS Code's git credential helpers. Clearing env vars
  alone only hides the path — the socket file in `/tmp` can still be discovered
  by scanning.
- **Removes credential sockets** via a `postStartCommand` script that deletes
  `vscode-ssh-auth-*.sock` and `vscode-git-*.sock` from `/tmp` after VS Code
  connects. This is a best-effort measure — the socket path patterns could
  change in future VS Code versions.
- **Disables git config copying** (`dev.containers.copyGitConfig: false`) to
  prevent leaking host credential helpers and signing key references into the
  container.
- **Enables workspace trust** (`security.workspace.trust.enabled: true`) so VS
  Code prompts before applying workspace settings that container code could have
  modified via the bind-mounted project folder.
- **Blocks local terminal creation** (`terminal.integrated.allowLocalTerminal:
  false`) so container extensions cannot call
  `workbench.action.terminal.newLocal` to open a shell on the host, which would
  bypass the WireGuard tunnel entirely. For maximum protection, also set this in
  your **host** user settings (workspace settings could theoretically override
  it).

### Consequences of hardening

Disabling credential forwarding and git config copying improves isolation but
requires a few adjustments.

**Git identity.** With `dev.containers.copyGitConfig` set to `false`, git inside
the container has no `user.name` or `user.email`. Add them to the `env` section
of your `settings.json`:

```json
"env": {
    "GIT_USER_NAME": "Your Name",
    "GIT_USER_EMAIL": "you@example.com"
}
```

The mitmproxy addon writes `env` entries to the shared env file (alongside
secret placeholders), and `app-user-init.sh` applies
`GIT_USER_NAME`/`GIT_USER_EMAIL` via `git config --global` at container startup.

**HTTPS remotes only.** With `SSH_AUTH_SOCK` cleared, SSH-based git remotes will
not work. Use HTTPS URLs instead — sandcat's secret substitution handles GitHub
token authentication over HTTPS transparently. Convert existing remotes with:

```sh
git remote set-url origin https://github.com/owner/repo.git
```

## Testing the proxy

Once inside the container (see [Quick start: try it
out](#quick-start-try-it-out)), you can inspect traffic in the mitmproxy web UI.
The host port is assigned dynamically — look it up from a host terminal with:

```sh
docker compose -f compose-all.yml port mitmproxy 8081
```

Or using Docker's UI. Log in with password `mitmproxy`.

To verify the kill switch blocks direct traffic:

```sh
# Should fail — iptables blocks direct eth0 access
curl --max-time 3 --interface eth0 http://1.1.1.1

# Should fail — no NET_ADMIN to modify firewall
iptables -F OUTPUT
```

To verify secret substitution for the GitHub token:

```sh
gh auth status
```

## Unit tests

```sh
cd scripts && pytest test_mitmproxy_addon.py -v
```

## Inspiration

Sandcat is mainly inspired by
[Matchlock](https://github.com/jingkaihe/matchlock), which provides similar
network isolation and secret substitution, however in the form of a dedicated
command line tool. While Matchlock VMs offer greater isolation and security,
they also lack the convenience of a dev containers setup, and integration with
an IDE.

[agent-sandbox](https://github.com/mattolson/agent-sandbox) implements a proxy
that runs alongside the container, however without secret substitution.
Moreover, the proxy is not transparent, instead relying on the more traditional
method of setting the `PROXY` environment variable.

Finally, Sandcat builds on the Docker+mitmproxy in WireGuard mode integration
implemented in
[mitm_wg](https://github.com/Srikanth0824/side-projects/tree/main/mitm_wg).

## Notes

### Why not wg-quick?

`wg-quick` calls `sysctl -w net.ipv4.conf.all.src_valid_mark=1`, which fails in
Docker because `/proc/sys` is read-only. The equivalent sysctl is set via the
`sysctls` option in `compose-proxy.yml`, and the entrypoint script handles
interface, routing, and firewall setup manually.

### TLS and CA certificates

Sandcat's mitmproxy intercepts TLS traffic, so the app container must trust the
mitmproxy CA. `app-init.sh` installs it into the system trust store, which is
enough for most tools — but some runtimes bring their own CA handling:

- **Node.js** bundles its own CA certificates and ignores the system store.
  `app-init.sh` sets `NODE_EXTRA_CA_CERTS` automatically. If you write a custom
  entrypoint, make sure to include this or Node-based tools will fail TLS
  verification.
- **Rust** programs using `rustls` with the `webpki-roots` crate bundle CA
  certificates at compile time and will not trust the mitmproxy CA. Use
  `rustls-tls-native-roots` in reqwest so it reads the system CA store at
  runtime instead.
- **Java** uses its own trust store (`cacerts`) and ignores the system CA.
  `app-user-init.sh` detects a mise-installed Java and automatically imports
  the mitmproxy CA into Java's trust store at container startup. It also
  creates a standalone copy of the modified trust store at a fixed path
  (`~/.local/share/sandcat/cacerts`), sets `JAVA_HOME` to a symlink
  pointing at the real JVM (so tools find it instead of the mise shim), and
  sets `JAVA_TOOL_OPTIONS` with `-Djavax.net.ssl.trustStore`. Both are
  exported via `/etc/profile.d/` (for shells) and `~/.bashrc` (for VS Code
  extension processes via `userEnvProbe`). **GraalVM native binaries**
  (e.g. `scala-cli`) ignore
  `JAVA_TOOL_OPTIONS` and `JAVA_HOME` for trust store resolution.
  `app-user-init.sh` pre-creates the `scala-cli` config file with the trust
  store path so it works even before scala-cli is installed. Other native
  tools may need similar tool-specific configuration.
- **Python** uses the system CA store — works out of the box.

## Development

Start the container from the command line:

```sh
docker compose -f compose-all.yml run --rm --build app bash
```

Tear down all containers and volumes (resets persisted home directory):

```sh
docker compose -f compose-all.yml down -v
```

## Commercial Support

We offer commercial services around AI-assisted software development. [Contact
us](https://virtuslab.com) to learn more about our offer!

## Copyright

Copyright (C) 2026 VirtusLab [https://virtuslab.com](https://virtuslab.com).