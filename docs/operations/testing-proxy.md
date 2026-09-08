# Testing the proxy

The proxy mode is chosen during `sandcat init` via the optional features prompt,
or with `--features tui` / `--proxy tui`. Both modes run `sandcat proxy` from the host, in the project
directory.

**Web UI** (default, `--proxy web`) — opens a browser-based interface:

```sh
sandcat proxy              # prints the mitmweb URL and password
sandcat compose port mitmproxy 8081  # or look up the port manually
```

Log in with password `mitmproxy`.

**Console** (`--proxy tui`) — uses `mitmdump` to log flows as text:

```sh
sandcat proxy              # tails the mitmdump log (Ctrl+C to stop)
```

Useful in terminal-only environments (SSH sessions, remote servers) or when a
browser adds overhead.

To verify the kill switch blocks direct traffic:

```sh
# Should fail — iptables blocks direct eth0 access
curl --max-time 3 --interface eth0 http://1.1.1.1

# Should fail — no NET_ADMIN to modify firewall
iptables -F OUTPUT
```

To verify Docker-internal traffic works (e.g. a database or app service added to
the compose file):

```sh
# Should succeed — Docker network traffic is allowed
curl --max-time 3 http://my-service:8080
```

To verify host access is blocked:

```sh
# Should fail — gateway (host) is blocked
docker_gateway=$(ip -4 route show default dev eth0 | awk '{print $3}')
curl --max-time 3 "http://$docker_gateway"
```

To verify direct mitmproxy access is blocked:

```sh
# Should fail — mitmproxy container is only reachable via WireGuard
mitmproxy_ip=$(getent hosts mitmproxy | awk '{print $1}')
curl --max-time 3 "http://$mitmproxy_ip:8081"
```

To verify secret substitution for the GitHub token:

```sh
gh auth status
```
