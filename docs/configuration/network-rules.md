# Network access rules

The `network` array defines ordered access rules evaluated top-to-bottom. First
matching rule wins (like iptables). If no rule matches, the request is
**denied**.

Each rule has:
- `action` — `"allow"` or `"deny"` (required)
- `host` — glob pattern via fnmatch (required)
- `method` — HTTP method to match; omit to match any method (optional)

## Network presets

Instead of listing every registry host by hand, a rule may be a **preset
reference** that expands, in place, to a predefined group of `allow` rules:

```json
{
  "network": [
    {"preset": "python"},
    {"preset": "github"},
    {"action": "allow", "host": "internal.corp.dev"}
  ]
}
```

Expansion preserves rule order, so first-match-wins semantics work across
presets — a `deny` rule placed before a preset shadows any host the preset
would allow. A preset entry must contain the `preset` key alone, and an
unknown preset name stops the proxy from starting (fail-loud) instead of
silently changing the policy.

Available presets (defined in `mitmproxy_addon_common.py`, versioned with
sandcat):

| Preset | Covers |
|--------|--------|
| `python` | pypi.org, files.pythonhosted.org, pypi.python.org, astral.sh (uv) |
| `node` | registry.npmjs.org, registry.yarnpkg.com, nodejs.org |
| `java` | Maven Central, Sonatype, Gradle plugin/services/downloads |
| `scala` | sbt/Typesafe repos + Maven Central (self-contained) |
| `go` | proxy.golang.org, sum.golang.org, pkg.go.dev, golang.org, google.golang.org |
| `rust` | crates.io (+index/static), static.rust-lang.org |
| `ruby` | rubygems.org (+index/api) |
| `dotnet` | api.nuget.org, globalcdn.nuget.org, nuget.org |
| `zig` | ziglang.org |
| `nix` | cache/channels/releases.nixos.org, search.devbox.sh (runtime devbox installs) |
| `vscode` | update/marketplace.visualstudio.com, *.vsassets.io, main.vscode-cdn.net |
| `jetbrains` | plugins.jetbrains.com, downloads.marketplace.jetbrains.com |
| `github` | github.com, *.github.com, *.githubusercontent.com |
| `anthropic` | *.anthropic.com, *.claude.ai, *.claude.com |
| `openai` | api.openai.com, *.openai.com |

Presets are host-only (no method restriction) — they mirror the domain-level
allowlists they are modeled on, and per-method tightening of package
registries breaks legitimate flows (e.g. `npm audit` POSTs) for marginal
gain. Add your own `deny` rules before a preset to tighten further.

## Default settings

`sandcat init` creates two settings files automatically:

- **User settings** (`~/.config/sandcat/settings.json`) — allows full access to
  GitHub and Anthropic/Claude, with empty API key placeholders. This is a
  liberal default: the agent can read arbitrary GitHub content (prompt injection
  vector) and push data (exfiltration vector).
- **Project settings** (`.sandcat/settings.json`) — allows all GET traffic to
  any host. This means the agent can read arbitrary web content, which is a
  prompt injection vector.

For stricter configurations, replace the wildcard rule with the
[network presets](#network-presets) for your stacks (plus any internal hosts
you need) — e.g. `{"preset": "python"}, {"preset": "github"}` instead of
`{"action": "allow", "host": "*", "method": "GET"}`.

`sandcat init --features strict-network` does this for you: the generated
project settings contain one preset entry per selected stack and no wildcard,
so anything beyond the stack registries and the user-settings layer (your
agent's API hosts) is denied by default — including its DNS resolution.
Expect to add a few hosts on first use (`.sandcat/settings.local.json` is the
per-machine place); the startup log and `sandcat proxy` show what got blocked.

## DNS filtering

DNS queries are checked against the same network rules as HTTP requests. If a
hostname is not allowed by any rule, the DNS lookup is refused — the container
never learns the IP address. This prevents DNS-based exfiltration even when HTTP
to that host would be blocked.

Because DNS has no HTTP method, method-specific rules are matched on host only.
A rule like `{"action": "allow", "host": "*", "method": "GET"}` will also allow
DNS resolution for any host. Rule ordering matters: a method-specific deny rule
will block DNS for that host even if a later rule would allow other methods.

## Examples

With the liberal template rules:
- `GET` to any host → **allowed** (rule 1)
- DNS lookup for any host → **allowed** (rule 1 matches on host)
- `POST` to `api.github.com` → **allowed** (rule 2)
- `POST` to `api.anthropic.com` → **allowed** (rule 4)
- `POST` to `example.com` → **denied**
- Empty network list → all requests **denied** (default deny)

