# Debugging

## Viewing proxy logs

Mitmproxy addon errors (network rule violations, secret resolution failures)
are written to stderr, visible via:

```sh
sandcat compose logs mitmproxy
```

In web mode, the mitmweb UI event log (accessible from the browser) also shows
addon warnings.

## Common issues

**`op read` failures (1Password).** If an `op://` reference can't be resolved
(wrong vault name, missing item, auth error), the addon logs a warning and sets
the secret value to empty. The container continues running — other secrets still
work. Check the logs to see the specific error:

```sh
sandcat compose logs mitmproxy | grep WARNING
```

**Container won't start.** If `mitmproxy` exits immediately, check its logs
first. Common causes:
- Settings JSON syntax error — the addon can't parse the file
- Missing settings file mount — verify `~/.config/sandcat/settings.json` exists

**Secrets not substituted.** If requests fail with auth errors even though
secrets are configured:
- Verify the secret has a non-empty value: `sandcat compose logs mitmproxy`
  shows how many secrets were loaded at startup
- Check that the destination host matches the secret's `hosts` allowlist
- Run `sandcat restart` after editing settings — the addon only reads
  settings at startup

**No network inside the container on some Wi-Fi networks.** If the sandbox has
no connectivity on one network but works on another, the network is likely
blocking outbound DNS (port 53) to the public resolvers sandcat uses by default
(`1.1.1.1`, `8.8.8.8`). This is common on corporate, hotel, and guest Wi-Fi,
which force their own resolver. The symptom is DNS-only: name lookups fail
inside the container while the host still browses fine (the host uses the
network's resolver; the container does not).

Fix: point the container at the network's own resolver via
[`dns_servers`](custom-upstream-dns). First find the resolver IP:

```sh
# macOS
scutil --dns | awk '/nameserver\[0\]/ {print $3; exit}'
# Linux (systemd-resolved)
resolvectl status | awk '/Current DNS Server/ {print $4; exit}'
# Fallback: your default gateway is often the resolver
#   macOS:  route -n get default | awk '/gateway/{print $2}'
#   Linux:  ip route | awk '/default/{print $3; exit}'
```

Then set it in `.sandcat/settings.local.json` (local, not committed) — or
`~/.config/sandcat/settings.json` to cover all projects:

```json
{ "dns_servers": ["10.0.0.1"] }
```

The value is network-specific; update or remove it when you change networks.
Run `sandcat restart` to apply it (or `sandcat run` if the sandbox isn't
started yet).

**CA certificate issues.** If you see TLS errors inside the container, the
mitmproxy CA may not be trusted. See [TLS and CA
certificates](../reference/notes.md#tls-and-ca-certificates) for runtime-specific configuration.
