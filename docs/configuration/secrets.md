# Secret substitution

Dev containers never see real secret values. Instead, environment variables
contain deterministic placeholders (`SANDCAT_PLACEHOLDER_<NAME>`), and the
mitmproxy addon replaces them with real values when requests pass through the
proxy.

Inside the container, `echo $ANTHROPIC_API_KEY` prints
`SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY`. When a request containing that
placeholder reaches mitmproxy, it's replaced with the real key — but only if the
destination host matches the `hosts` allowlist.

## Host patterns

The `hosts` field accepts glob patterns via `fnmatch`:

- `"api.anthropic.com"` — exact match
- `"*.anthropic.com"` — any subdomain
- `"*"` — allow all hosts (use with caution)

## Leak detection

If a placeholder appears in a request to a host **not** in the allowlist,
mitmproxy blocks the request with HTTP 403 and logs a warning. This prevents
accidental secret leakage to unintended services.

## 1Password integration

Instead of storing secret values directly in settings files, you can reference
secrets stored in 1Password using `op://` references:

```json
{
  "secrets": {
    "ANTHROPIC_API_KEY": {
      "op": "op://Private/Anthropic API Key/credential",
      "hosts": ["api.anthropic.com"]
    }
  }
}
```

Each secret entry must have either `"value"` (plain text) or `"op"` (1Password
reference), not both. You can mix both styles in the same settings file.

The mitmproxy addon resolves `op://` references at startup using the `op` CLI.
To enable 1Password during project setup, select it from the optional features
prompt, or pass the flag:

```bash
sandcat init --secret-provider 1password
```

This switches the mitmproxy service to
`ghcr.io/virtuslab/sandcat-mitmproxy-op`, a pre-built image that includes the
`op` CLI.

**Authentication.** The `op` CLI inside the container authenticates via a
[1Password service account](https://developer.1password.com/docs/service-accounts/).
To set one up:

1. Go to [1Password Developer Tools > Service
   Accounts](https://my.1password.com/developer-tools/infrastructure-secrets/serviceaccount/)
   and create a new service account
2. Grant it read access to the vault(s) containing your secrets
3. Add the token to `~/.config/sandcat/settings.json`:

```json
{
  "op_service_account_token": "ops_...",
  "secrets": {
    "ANTHROPIC_API_KEY": {
      "op": "op://Private/Anthropic API Key/credential",
      "hosts": ["api.anthropic.com"]
    }
  }
}
```

The token is read from the settings file by the mitmproxy addon at startup. If
`op_service_account_token` is not set in settings, the addon falls back to the
`OP_SERVICE_ACCOUNT_TOKEN` environment variable (forwarded from the host shell
into the container).

Secret resolution happens once at mitmproxy startup — run `sandcat
restart` after changing 1Password items.

## How it works internally

1. The mitmproxy container mounts `~/.config/sandcat/settings.json` (read-only)
   and the project's `.sandcat/` directory (read-only) alongside the addon
   script. The addon comes in two agent-specific variants
   (`mitmproxy_addon_claude.py`, `mitmproxy_addon_cursor.py`) that share their
   common logic via the `mitmproxy_addon_common.py` library.
2. On startup, the addon reads all available settings files (user, project,
   local), merges them according to the precedence rules above, and writes
   `sandcat.env` to the agent-facing `mitmproxy-public` shared volume
   (`/mitmproxy-public/sandcat.env`). This file contains plain env vars
   (e.g. `export GIT_USER_NAME='Your Name'`) and secret placeholders (e.g.
   `export ANTHROPIC_API_KEY=SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY`).
3. App containers mount `mitmproxy-public` read-only at `/mitmproxy-config/`.
   The shared entrypoint (`app-init.sh`) sources `sandcat.env` after installing
   the CA cert, so every process gets the env vars and placeholder values.
4. On each request, the addon first checks network access rules. If denied, the
   request is blocked with 403.
5. If allowed, the addon checks for secret placeholders in the request, verifies
   the destination host against the secret's allowlist, and either substitutes
   the real value or blocks the request with 403 (leak detection).

Real secrets never leave the mitmproxy container.

## Disabling

Remove all settings files. If no settings file exists at any layer, the addon
disables itself — no network rules are enforced and `sandcat.env` is not
written.

## Agent-specific notes

Per-agent authentication and substitution behavior moved to the **Agents**
section: [Claude Code](../agents/claude.md#authentication),
[Cursor CLI](../agents/cursor.md#authentication-and-cli-configuration).
