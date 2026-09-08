# Settings format

Settings are loaded from up to three files (highest to lowest precedence):

| File | Scope | Git |
|------|-------|-----|
| `.sandcat/settings.local.json` | Per-project overrides | **Ignored** (add to `.gitignore`) |
| `.sandcat/settings.json` | Per-project defaults | Committed |
| `~/.config/sandcat/settings.json` | User-wide defaults | N/A |

All three files use the same JSON format. Missing files are silently skipped. If
no files exist, the addon disables itself.

**Merge rules:**
- `env` — merged; higher-precedence values overwrite lower ones.
- `secrets` — merged; higher-precedence entries overwrite lower ones.
- `extra_hosts` — merged; higher-precedence entries overwrite lower ones.
- `network` — concatenated; highest-precedence rules come first. Since rules are
  evaluated top-to-bottom with first-match-wins, this means local rules take
  priority over project rules, which take priority over user rules.
- `dns_servers` — last-wins; the highest-precedence layer that sets the key
  replaces the entire list (see [DNS resolution](dns.md#dns-resolution)).

A typical setup keeps user-specific settings (git identity, API keys) in the
user file, project-wide network rules in the project file, and developer
overrides in the local file:

`~/.config/sandcat/settings.json` (user — created by `sandcat init` on first
run):

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
    },
    "GITHUB_TOKEN": {
      "value": "ghp_your-token-here",
      "hosts": ["github.com", "*.github.com", "*.githubusercontent.com"]
    }
  },
  "network": [
    {"action": "allow", "host": "*.github.com"},
    {"action": "allow", "host": "github.com"},
    {"action": "allow", "host": "*.githubusercontent.com"},
    {"action": "allow", "host": "*.anthropic.com"},
    {"action": "allow", "host": "*.claude.ai"},
    {"action": "allow", "host": "*.claude.com"}
  ]
}
```

`.sandcat/settings.json` (project, committed):

```json
{
  "network": [
    {"action": "allow", "host": "*", "method": "GET"}
  ]
}
```

`.sandcat/settings.local.json` (project, git-ignored):

```json
{
  "network": [
    {"action": "allow", "host": "internal.corp.dev"}
  ]
}
```

With these files, the merged network rules are (local first, then project, then
user): allow `internal.corp.dev`, then the project wildcard GET rule, then the
user's GitHub/Anthropic rules. Env and secrets come from the user file since
neither project file defines them.

Warning: the default project settings allow all GET traffic, which means the
agent can read arbitrary web content — a vector for prompt injection. Stricter
settings would narrow this to known service domains. Note that the user-level
settings allow full access to GitHub, which can be used to read untrusted
content (prompt injection) or push data out (exfiltration). Malicious code might
also be generated as part of the project itself.
