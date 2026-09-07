# DNS resolution

Queries that aren't refused by the network rules are resolved by a small
`dnsmasq` running inside `wg-client`, which splits traffic two ways: sibling
containers go to Docker's embedded resolver locally, everything else goes
through the WireGuard tunnel to mitmproxy and out via the configured upstream.

(custom-upstream-dns)=
## Custom upstream DNS — `dns_servers`

Top-level optional array of IPv4/IPv6 addresses. Overrides the upstream DNS
servers used by the WireGuard tunnel. Point this at a corporate/intranet
resolver to make internal hostnames (e.g. `*.corp.example.com`) work inside
the sandbox. Empty list, omitted, or explicit `null` falls back to `1.1.1.1`
and `8.8.8.8`. Hostnames are not accepted (resolv.conf `nameserver` directives
require numeric IPs); invalid entries are skipped with a warning.

```json
{
  "dns_servers": ["10.20.0.10", "10.20.0.11"]
}
```

Higher-precedence layers replace the entire list; they are not merged. Setting
`"dns_servers": null` in a higher layer resets back to defaults regardless of
what a lower layer set. Run `sandcat restart` after editing.

## Container-to-container DNS

The agent can resolve sibling containers on the same Docker compose network by
name (e.g. a `db:` service in `compose.yml` is reachable as `db`). Queries
under the compose project's network (the `search` domain Docker assigns to
the container) go to Docker's embedded resolver at `127.0.0.11`. No
configuration is required.

The agent shares wg-client's network namespace via `network_mode` but Docker
still gives each container its own `/etc/resolv.conf` in its own mount
namespace. wg-client publishes its resolv.conf onto a shared `wg-runtime`
volume mounted read-only at `/run/sandcat` in the agent, and `app-init.sh`
copies it into `/etc/resolv.conf` on startup so the agent's lookups also go
through the local dnsmasq.

To prevent the search-domain carve-out from becoming a DNS exfiltration
channel — where an attacker-crafted name like `<payload>.<project>_default`
would otherwise be forwarded by Docker's embedded resolver to the host's
upstream DNS, bypassing mitmproxy — wg-client is launched with a `dns:` sink
(RFC 5737 `192.0.2.1`). Sibling names still resolve locally; anything else
under the search domain fails fast without leaving the host.

## Resolving internal hostnames — `extra_hosts`

DNS inside the sandbox goes through mitmproxy to public resolvers (or the
`dns_servers` you configured), so names that only live in your host's
`/etc/hosts` or on an unroutable internal network won't resolve. Use
`extra_hosts` in `settings.json` to map hostnames to IPs; the addon writes
them to a sidecar file which `wg-client` splices into its `/etc/hosts`
inside a `# sandcat extra_hosts` sentinel block. The agent inherits that
file via `network_mode: service:wg-client`, so `getent hosts <name>`,
`curl`, `mvn`, Java's `InetAddress` etc. resolve the name via NSS before
any DNS query.

```json
{
  "extra_hosts": {
    "maven-proxy.corp": "192.168.1.100",
    "jira.internal": "10.0.0.50"
  },
  "network": [
    {"action": "allow", "host": "maven-proxy.corp"},
    {"action": "allow", "host": "jira.internal"}
  ]
}
```

**A matching network allow rule is still required.** Mitmproxy enforces
network policy on the HTTP `Host` / TLS `SNI` regardless of how the name
was resolved. Without an allow rule, requests to the internal host are
blocked with 403.

**Merge rules.** `extra_hosts` is a dict merged across the three settings
layers (user / project / local); higher precedence overwrites per-key.

**Validation.** Invalid entries are logged as warnings and skipped; the
container still starts. Requirements:
- **Hostname** — RFC-1123 label (letters, digits, hyphens, max 253 chars).
  A trailing dot (`nexus.corp.`) is stripped before validation.
- **IP** — IPv4 or IPv6 accepted by Python's `ipaddress` module.

**IPv6 caveat.** Sandcat's kill-switch drops outbound IPv6 traffic
(`ip6tables -A OUTPUT -o eth0 -j DROP`) so mapping a name to an IPv6
address will resolve via NSS but the connection itself will time out.
The addon logs a warning for IPv6 entries but still writes them, in case
you're using them for tools that only need name-to-address lookup (e.g.
some healthchecks) rather than actual connectivity.

**Applying changes.** Run `sandcat restart` to re-read settings —
the sentinel block in `/etc/hosts` is replaced atomically on each start.
Processes already running inside the agent may cache DNS results (Java
`sun.net.InetAddressCachePolicy`, curl connection pool, etc.) and won't
pick up the change until they reconnect or the agent is restarted.

