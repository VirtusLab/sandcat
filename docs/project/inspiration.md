# Inspiration

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
