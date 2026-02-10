# Dev Container Setup

All traffic from the rust dev container is routed through a transparent
[mitmproxy](https://mitmproxy.org/) via WireGuard. This captures HTTP/S,
DNS, and all other TCP/UDP traffic without per-tool proxy configuration.

The WireGuard tunnel and iptables kill switch run in a dedicated
`wg-client` container. The rust container shares its network namespace
via `network_mode: "service:wg-client"` and never receives `NET_ADMIN`,
so processes inside — even root — cannot modify routing, firewall rules,
or the tunnel itself. This is enforced by the kernel, not by capability
drops.

## Testing the proxy setup

A lightweight `test` container is included for verifying the proxy works.
Start it (from the `.devcontainer/` directory):

```sh
docker compose --profile test run --rm test bash
```

Inside the container, verify HTTPS works through the tunnel:

```sh
# Should return 200 (mitmproxy CA is trusted)
curl -s -o /dev/null -w '%{http_code}\n' https://example.com

# Traffic should appear in the mitmproxy web UI
curl https://httpbin.org/get
```

Then open http://localhost:8081 and log in with password `mitmproxy` to
confirm the requests show up in the web UI.

To verify the kill switch blocks direct traffic:

```sh
# Should fail — iptables blocks direct eth0 access
curl --max-time 3 --interface eth0 http://1.1.1.1

# Should fail — no NET_ADMIN to modify firewall
iptables -F OUTPUT
```

To inspect WireGuard state, exec into the wg-client container (which
has `NET_ADMIN`):

```sh
docker exec devcontainer-wg-client-1 wg show
```

## Architecture

```
                network_mode
┌──────────────┐  shares net  ┌──────────────┐  WG tunnel  ┌──────────────┐
│ rust / test  │ ──────────── │  wg-client   │ ─────────── │  mitmproxy   │ ── internet
│  (no NET_ADMIN)             │  (NET_ADMIN) │             │  (mitmweb)   │
└──────────────┘              └──────────────┘             └──────────────┘
                                                             localhost:8081
                                                             pw: mitmproxy
```

- **mitmproxy** runs `mitmweb --mode wireguard`, creating a WireGuard
  server and storing key pairs in `wireguard.conf`.
- **wg-client** is a dedicated networking container that derives a
  WireGuard client config from those keys, sets up the tunnel with `wg`
  and `ip` commands, and adds iptables kill-switch rules. Only this
  container has `NET_ADMIN`. No user code runs here.
- **rust / test** containers share `wg-client`'s network namespace via
  `network_mode`. They inherit the tunnel and firewall rules but cannot
  modify them (no `NET_ADMIN`). They install the mitmproxy CA cert into
  the system trust store at startup so TLS interception works.
- The mitmproxy web UI on port 8081 shows all intercepted traffic
  (password: `mitmproxy`).

### Why not wg-quick?

`wg-quick` calls `sysctl -w net.ipv4.conf.all.src_valid_mark=1`, which
fails in Docker because `/proc/sys` is read-only. The equivalent sysctl
is set via the `sysctls` option in `docker-compose.yml`, and the
entrypoint script handles interface, routing, and firewall setup manually.

## Rust TLS note

Rust programs using `rustls` with the `webpki-roots` crate bundle CA
certificates at compile time and will not trust the mitmproxy CA. This
project uses `rustls-tls-native-roots` in reqwest so it reads the system
CA store at runtime instead. If you add other HTTP client dependencies,
make sure they also use native cert roots.
