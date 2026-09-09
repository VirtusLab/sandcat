# JetBrains

Sandcat supports JetBrains IDEs through [JetBrains
Gateway](https://www.jetbrains.com/remote-development/gateway/) and its dev
containers integration: `sandcat init --ide jetbrains …` generates a
`devcontainer.json` with a `customizations.jetbrains` block instead of the
VS Code one.

## Opening the sandbox

In Gateway (or a JetBrains IDE with remote development), choose **Dev
Containers → From Local Project** and point it at the project's
`.devcontainer/devcontainer.json`. Gateway builds the images, starts the
compose stack, installs the backend IDE inside the agent container, and
connects a thin client to it.

The generated block looks like:

```json
"customizations": {
    "jetbrains": {
        "backend": "IntelliJ",
        "plugins": ["org.intellij.scala"],
        "settings": {}
    }
}
```

- **`backend`** selects which JetBrains product runs inside the container.
  `IntelliJ` is the default; edit it per project (e.g. `PyCharm`, `GoLand`).
- **`plugins`** is seeded from the selected stacks — see below.

## Per-stack plugins

Like the VS Code path adds one language extension per stack, the JetBrains
path seeds `customizations.jetbrains.plugins` with the stack's Marketplace
plugin ID, and Gateway installs the listed plugins into the backend IDE at
first start:

| Stack | Plugin | Caveat |
|-------|--------|--------|
| `python` | `PythonCore` | free; works in IDEA Community |
| `scala` | `org.intellij.scala` | free |
| `go` | `org.jetbrains.plugins.go` | requires an **Ultimate** backend (or GoLand); silently skipped on Community |
| `ruby` | `org.jetbrains.plugins.ruby` | requires an **Ultimate** backend (or RubyMine); silently skipped on Community |
| `zig` | `com.falsepattern.zigbrains` | community-maintained |
| `node`, `java` | — | language support is bundled in IntelliJ IDEA |
| `dotnet` | — | JetBrains' .NET IDE is standalone Rider; no IntelliJ plugin exists |
| `rust` | — | Rust moved to standalone RustRover; the old plugin is discontinued |

## `overrideCommand: false` — do not remove

The generated `devcontainer.json` sets `overrideCommand: false`. This is a
**security-relevant** line, not a preference: JetBrains Gateway otherwise
replaces the container command and skips the sandcat entrypoint
(`app-init.sh`) — the step that installs the mitmproxy CA, adopts
wg-client's DNS, and loads the sandcat environment. With the entrypoint
skipped, processes in the container run without the sandbox's TLS and
policy wiring. Leave it in place.

## Extra capabilities and mounts

The JetBrains backend manages files it does not own (indexes, caches,
IDE state), so with `--ide jetbrains` the agent service additionally gets
`cap_add: [DAC_OVERRIDE, CHOWN, FOWNER]` in the generated compose file —
still combined with `no-new-privileges`, and still without `NET_ADMIN`,
so the network boundary is unaffected.

Optionally, the host project's `.idea/` directory can be mounted read-only
into the workspace with `SANDCAT_MOUNT_IDEA_READONLY=true` at init time
(defaults to on for the JetBrains IDE path), so run configurations and code
styles carry over. See [Customizing optional volume
mounts](../getting-started/initialization.md#customizing-optional-volume-mounts).

## Network

The backend IDE downloads itself, plugins, and updates from JetBrains
servers — through the proxy, like all container traffic. The `jetbrains`
[network preset](../configuration/network-rules.md#network-presets)
(`plugins.jetbrains.com`, `downloads.marketplace.jetbrains.com`) covers the
plugin marketplace; on a tightened policy add the JetBrains download hosts
your setup needs.
