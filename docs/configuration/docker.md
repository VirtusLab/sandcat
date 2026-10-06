# Docker in the sandbox

Many agent workflows need a working Docker engine — Testcontainers, building
images, `docker compose` integration stacks. Mounting the host's
`docker.sock` would hand the agent host-root and a proxy bypass, so sandcat
takes a different route: an opt-in **nested Docker daemon** whose traffic
stays on the mitmproxy path.

```bash
sandcat init --features docker ...
# or: SANDCAT_DOCKER=true sandcat init ...
```

## What you get

Inside the sandbox, `docker` just works:

```bash
docker run --rm alpine echo hello     # runs on the NESTED daemon
docker build -t myimage .
docker compose up -d                  # project's own stacks
```

`DOCKER_HOST` points at a unix socket on a shared volume
(`/docker-sock/docker.sock`), and the matching `docker` CLI is published on
`PATH` by the dind service itself — versions can't drift.

## How it works

A dedicated `dind` compose service hosts the nested `dockerd`:

- **Own network namespace** with its **default route via wg-client**, which
  NATs it into the WireGuard tunnel. Egress from every container the agent
  launches transits mitmproxy: the network policy, TLS bumping, and secret
  substitution apply **two levels deep**. The route is fail-loud — if it
  cannot be installed, the daemon refuses to start rather than fall back to
  an unproxied path.
- The **mitmproxy CA is installed before the nested daemon starts** (Go
  loads its trust pool once per process), so `docker pull` works through
  the proxy out of the box.
- The **host daemon is never exposed**: no `docker.sock` bind-mount exists
  anywhere in the generated project, and inner containers cannot reach
  wg-client's namespace — forwarding anywhere except into the tunnel is
  dropped.

## Network policy

`--features docker` seeds the [`docker-registry` network
preset](network-rules.md#network-presets) into the project settings: BuildKit
resolves registry manifests with **HEAD** requests, which the default
allow-`*`-GET wildcard does not cover. The preset is host-scoped
(Docker Hub + ghcr.io, all methods); add other registries your builds pull
from the same way.

## Caveats

- The `dind` service is `privileged` — required by the nested daemon
  (cgroups, overlayfs, iptables in its own namespaces). The agent only ever
  sees the socket; a hostile inner container that escaped dind would still
  be outside wg-client's namespace and unable to touch the kill switch.
- **HTTPS inside inner containers** needs the mitmproxy CA like everywhere
  else in the sandbox. The nested daemon trusts it (pulls work), but your
  own containers must mount/trust it too, e.g.:

  ```bash
  docker run -v /usr/local/share/ca-certificates/sandcat-mitm-ca.crt:/etc/ssl/certs/mitm.pem ...
  ```

  For JVM/Testcontainers workloads, point the truststore at the CA the same
  way the agent's Java setup does (see
  [Notes → TLS and CA certificates](../reference/notes.md)).
- Secret placeholders are **not** propagated into inner containers by
  default — pass the env var explicitly if a container should authenticate
  through the proxy.
- Inner-container state lives on the `dind-storage` volume; `sandcat
  destroy` removes it with everything else.
