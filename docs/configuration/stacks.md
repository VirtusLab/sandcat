# Stack and tool packages via devbox

All packages inside the sandbox — both stack toolchains and user tools —
are managed with [devbox](https://www.jetify.com/devbox), which resolves
them from Nix. `sandcat init` generates two config files side by side in
`.devcontainer/`:

**`devbox.stack.json`** — sandcat-managed. Regenerated on every
`sandcat init` from the `--stacks` selection plus a baseline of shell tools
every sandbox needs (`fd`, `fzf`, `gh`, `jq`, `ripgrep`, `tmux`, `vim`).
Do not edit by hand — your changes will be overwritten on the next init.

**`devbox.tools.json`** — user-managed. Written once with an empty
`packages` list; subsequent `sandcat init` invocations leave it untouched.
Add project-specific tools here.

At image build time the two files are merged into a single devbox global
config. `devbox.tools.json` wins over `devbox.stack.json` on:

* **Same package name** — the `@` prefix. Put `nodejs@22.5.1` in tools
  to replace the stack's `nodejs` (without a specifier, `nodejs` refers to lts).
* **Cross-family collisions** — tools packages providing the same file
  as a stack package win too. Put `openjdk17@latest` in tools to make
  it the active Java over the stack's `temurin-bin-25@latest`; the
  agent's `java`, `JAVA_HOME` and the injected mitmproxy CA all
  resolve to the tools JDK.

Non-overriding tools entries just add to the merged config. Search
available packages on [nixhub.io](https://www.nixhub.io/).

Example — give the agent [yq](https://github.com/mikefarah/yq),
[shellcheck](https://www.shellcheck.net/), and
[hyperfine](https://github.com/sharkdp/hyperfine) by dropping them into
`devbox.tools.json`:

```json
{
  "packages": ["yq-go@latest", "shellcheck@latest", "hyperfine@latest"]
}
```

Then rebuild the agent image:

```bash
sandcat run --build
# or, without starting the full stack:
docker compose -f .devcontainer/compose-all.yml build agent
```

Every shell inside the sandbox — including the agent's — picks up the
packages on `PATH`. Iterating on `devbox.tools.json` is the fast path:
the stack install layer stays cached and only the delta downloads
(typically seconds).

Installs are build-time only: `devbox add` inside the sandbox is not
supported, and no Nix download hosts are added to the network allowlist.
To pin the exact package versions across environments, commit
`.devcontainer/devbox.lock` next to the JSON files; the build picks it up
automatically.

Optional volume mounts (agent config, `.git`, `.idea`) are written into the
generated `.devcontainer/compose-all.yml`. See [Customizing optional volume
mounts](volume-mounts.md) below. For scripted `sandcat init`,
set `SANDCAT_*` environment variables (see the [CLI reference](../reference/cli.md)).
