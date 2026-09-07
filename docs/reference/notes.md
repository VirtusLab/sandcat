# Notes

## Why not wg-quick?

`wg-quick` calls `sysctl -w net.ipv4.conf.all.src_valid_mark=1`, which fails in
Docker because `/proc/sys` is read-only. The equivalent sysctl is set via the
`sysctls` option in `compose-proxy.yml`, and the entrypoint script handles
interface, routing, and firewall setup manually.

## TLS and CA certificates

Sandcat's mitmproxy intercepts TLS traffic, so the app container must trust the
mitmproxy CA. `app-init.sh` installs it into the system trust store, which is
enough for most tools — but some runtimes bring their own CA handling:

- **Node.js** bundles its own CA certificates and ignores the system store.
  `app-init.sh` sets `NODE_EXTRA_CA_CERTS` and
  `NODE_OPTIONS=--use-openssl-ca` automatically. The `--use-openssl-ca` flag
  is required for tools that bundle their own Node.js binary (e.g. Cursor CLI)
  where `NODE_EXTRA_CA_CERTS` alone may not be honored. If you write a custom
  entrypoint, make sure to include both or Node-based tools will fail TLS
  verification.
- **Rust** programs using `rustls` with the `webpki-roots` crate bundle CA
  certificates at compile time and will not trust the mitmproxy CA. Use
  `rustls-tls-native-roots` in reqwest so it reads the system CA store at
  runtime instead.
- **Java** uses its own trust store (`cacerts`) and ignores the system CA. The
  `Dockerfile.app` build step creates a version-independent `JAVA_HOME` symlink,
  copies the default `cacerts`, and writes `JAVA_HOME` and `JAVA_TOOL_OPTIONS`
  (with `-Djavax.net.ssl.trustStore`) to `.bashrc` so VS Code's `userEnvProbe`
  picks them up immediately. At container startup, `app-user-init.sh` imports
  the mitmproxy CA into the `cacerts` copy at `~/.local/share/sandcat/cacerts`
  and updates the symlink target if the Java version changed. **GraalVM native
  binaries** (e.g. `scala-cli`) ignore `JAVA_TOOL_OPTIONS` and `JAVA_HOME` for
  trust store resolution. `app-user-init.sh` pre-creates the `scala-cli` config
  file with the trust store path so it works even before scala-cli is installed.
  Other native tools may need similar tool-specific configuration.
- **Python** uses the system CA store — works out of the box. The exception is
  **uv**, which is itself a Rust binary and (like other `rustls`-based tools)
  bundles its own root CAs. The `python` stack sets `UV_SYSTEM_CERTS` on the
  agent service automatically so `uv` reads the system store instead.

## Trusting internal CAs upstream

If your organization runs internal HTTPS services (e.g. an on-prem Nexus,
GitLab, Artifactory) signed by an internal CA or with a self-signed
certificate, sandcat's mitmproxy will fail to validate those upstreams by
default — the `mitmproxy/mitmproxy` image ships a stock Debian
public-CA bundle and does not know about your internal CA.

Add the CA(s) to `upstream_ca_bundles` in
`~/.config/sandcat/settings.json` (per-user) and/or
`.sandcat/settings.local.json` (per-project, per-machine — file is
git-ignored by default):

    {
      "upstream_ca_bundles": [
        "/etc/ssl/company-ca.pem"
      ]
    }

Values are absolute paths on the host. Files are bind-mounted read-only
into mitmproxy at `/upstream-ca/` and installed at container start into
(a) the OS trust store via `update-ca-certificates` and (b) the
`certifi` bundle that mitmproxy loads on the upstream leg
(`mitmproxy/net/tls.py` uses `certifi.where()`, not the OS store).
Public CAs are **extended, not replaced** — public HTTPS services keep
working.

Re-run `sandcat init` after adding, removing, or changing paths in this
setting (bind-mounts are set at compose-render time). Changing only the
contents of an already-mounted CA file requires just
`docker compose restart mitmproxy`.

Security note: a CA you add here is trusted by mitmproxy for every
upstream that CA signs — the same risk model as installing a CA in your
OS. Add only CAs you or your organization control.
