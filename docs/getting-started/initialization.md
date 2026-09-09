# Initializing the sandbox

```bash
sandcat init
```

This prompts you to select the agent type, IDE (for devcontainer mode), and
development stacks to install. You can also pass flags to skip prompts:

```bash
sandcat init --agent claude --ide vscode --stacks "python,node"

# With optional features (proxy TUI, 1Password integration)
sandcat init --secret-provider 1password --agent claude --ide vscode
```

Available agents:
- `claude` (Claude Code CLI)
- `cursor` (Cursor IDE)
- `codex` (OpenAI Codex CLI — https://github.com/openai/codex)
- `copilot` (GitHub Copilot CLI — https://docs.github.com/copilot/how-tos/copilot-cli)

Available stacks: `node`, `python`, `java`, `rust`, `go`, `scala`, `ruby`,
`dotnet`, `zig`. Versions default to LTS where available (e.g. Node.js LTS,
Java LTS 25). To change a version for a single project, add the desired
package to `.devcontainer/devbox.tools.json` — see [Stack and tool packages
via devbox](#stack-and-tool-packages-via-devbox) below for how tool entries
override stack defaults.

Selecting `scala` automatically includes `java` as a dependency. Stacks also
install the corresponding VS Code extension (e.g. `rust-analyzer` for Rust,
`metals` for Scala).

## Stack and tool packages via devbox

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
mounts](#customizing-optional-volume-mounts) below. For scripted `sandcat init`,
set `SANDCAT_*` environment variables (see the [CLI reference](../reference/cli.md)).

## Customizing optional volume mounts

`sandcat init` adds optional bind-mounts to `services.agent.volumes` in
`.devcontainer/compose-all.yml`. Each mount is an independent line — you can
enable or disable **individual paths** by editing that file after init. This
works the same way for Claude and Cursor; there are no per-folder `sandcat init`
flags today.

**All-or-nothing at init time** (scripted workflows only):

| Agent     | Environment variable          | Default                                 |
|-----------|-------------------------------|-----------------------------------------|
| Claude    | `SANDCAT_MOUNT_CLAUDE_CONFIG` | `true`                                  |
| Cursor    | `SANDCAT_MOUNT_CURSOR_CONFIG` | `true`                                  |
| Codex     | `SANDCAT_MOUNT_CODEX_CONFIG`  | `true`                                  |
| Any       | `SANDCAT_MOUNT_GIT_READONLY`  | `false` (commented in compose)          |
| JetBrains | `SANDCAT_MOUNT_IDEA_READONLY` | `false` (active when `--ide jetbrains`) |
| Any       | `SANDCAT_MOUNT_SHARED_CACHE`  | `true` — see [Shared dependency caches](#shared-dependency-caches) |
| Any       | `SANDCAT_GITIGNORE`           | `true` (see [Gitignore defaults](#gitignore-defaults)) |
| Any       | `SANDCAT_RTK`                 | `true` (see [RTK — LLM token compression](../agents/rtk.md)) |

When an agent mount flag is `false`, Sandcat lists every path as a foot comment
on the first volume entry — copy the lines you want into the active `volumes:`
list.

**Per-path tuning (recommended):** edit `.devcontainer/compose-all.yml`, remove
or comment out mounts you do not want, then rebuild/reopen the devcontainer:

```yaml
# Mount a different workspace's Cursor transcripts (not recommended):
# - ${HOME}/.cursor/projects/workspaces-other-project:/home/vscode/.cursor/projects/workspaces-other-project
```

**Do not re-run `sandcat init`** unless you intend to reset generated files —
it recopies the template and overwrites manual compose edits. Commit your
customized `compose-all.yml` to keep changes across the team.

**Project-local config** (per repository, via the workspace code mount — not
controlled by `SANDCAT_MOUNT_*_CONFIG`):

- Claude: `.claude/` in the repo (skills, agents, etc.)
- Cursor: `.cursor/` in the repo (rules, skills, agents, `cli.json`, etc.)

Use host mounts for personal defaults shared across sandboxes; use repo
`.claude/` or `.cursor/` for project-specific or team-shared customization.

**Isolation notes:** host `~/.claude/` and shared Cursor customization mounts
(`rules/`, `skills/`, etc.) are one profile per user on the machine — all
sandcat projects on that host see the same mounted trees. Cursor transcripts for
this sandbox persist under host `projects/<workspace-id>/` only
(`workspaces-<project-name>`). Other workspaces' `projects/`, plus `chats/`,
`plugins/`, and `subagents/`, are not mounted. To keep a sandcat project fully
isolated from host agent state, set `SANDCAT_MOUNT_<AGENT>_CONFIG=false` and
rely on repo-local config plus the `agent-home` volume inside the container.

## Shared dependency caches

For stacks that download a lot of common dependencies, sandcat mounts a set
of **host-scoped named volumes** so `cats-effect`, `spring-boot`, etc.
downloaded in one project are instantly available in every other project on
the same host. Otherwise each sandbox re-downloads and re-stores the same
JAR trees inside its own `agent-home`, adding several GB per project.

The cache set is picked **per stack** — a project without a matching stack
gets no shared cache mounts at all. Today only the JVM stack (`--stacks java`,
also pulled in by `scala`) contributes cache entries; other language stacks
are not supported now.

Java/Scala cache mounts (all under `/home/vscode/` in the container):

| Path                        | Cache for                                             |
|-----------------------------|-------------------------------------------------------|
| `.m2/repository/`           | Maven local repository                                |
| `.cache/coursier/`          | Coursier — sbt (modern), scala-cli, Metals            |
| `.gradle/caches/`           | Gradle dependency cache                               |
| `.gradle/wrapper/dists/`    | Gradle Wrapper distributions                          |
| `.ivy2/cache/`              | Ivy — legacy sbt (pre-Coursier resolver)              |
| `.sbt/boot/`                | sbt bootstrap (sbt binaries + Scala compiler)         |

Each is a Docker named volume with a stable host-wide name
(`sandcat-cache-maven`, `sandcat-cache-coursier`, …) declared as
`external: true` in the generated `compose-all.yml`. Multiple sandcat compose
projects reference the same physical volume, and `sandcat compose down -v` on
one project will **not** wipe caches other projects rely on. The `sandcat run`
wrapper creates them lazily via `docker volume create` (idempotent), so no
manual setup is required.

Only `/home/vscode/.m2/repository/` is shared, not the whole `.m2/` — user
config like `settings.xml` stays per-project inside `agent-home`. Same pattern
for `.gradle/` (only `caches/` and `wrapper/dists/`, not `daemon/` or
`init.d/`) and `.ivy2/` (only `cache/`, not `local/` where `sbt publishLocal`
outputs live).

**Opt out per project:**

```bash
sandcat init --features no-shared-cache ...      # interactive selection also
                                                  # exposes it in the menu
```

Or set the env var before init (equivalent to the feature flag):

```bash
SANDCAT_MOUNT_SHARED_CACHE=false sandcat init ...
```

With shared cache disabled, the mount lines stay in `compose-all.yml` as
comments — you can flip individual ones back on by uncommenting.

**Trade-offs to be aware of:**

* Shared caches break sandcat's per-project isolation model for those specific
  paths. If one project's build corrupts a JAR (rare — Maven and Coursier both
  do content-hash validation), other projects using shared cache pick up the
  corruption. Disable per project if you need hermetic isolation (regulated
  environments, security-sensitive projects).
* Two parallel builds writing the same artifact rely on the tools' own file
  locking (Maven `.locks/`, Coursier per-artifact `.lock`, Gradle `.lock`).
  This works reliably in practice but is not sandcat-mediated.

**Managing shared caches:**

```bash
# Detailed table — volume name, size, file count, running container users
sandcat cache list
sandcat cache          # same as `list`

# Quick total across all shared-cache volumes
sandcat cache size

# Wipe one (next build re-downloads what the project needs)
sandcat cache rm sandcat-cache-maven

# Wipe them all — resets every shared cache on the host
sandcat cache rm --all
```

`sandcat cache rm` refuses to remove a volume that a running sandbox
still mounts; stop the sandbox first, or pass `--force` to bypass the
check (Docker will then error out if the volume is truly locked).

## Gitignore defaults

When the project has a `.git/` directory, `sandcat init` appends a
`# Sandcat` block to `.gitignore` (creating the file if needed) so
users don't accidentally commit files that are either regenerated on
next init or per-machine:

```text
# Sandcat
.devcontainer/*
!.devcontainer/devbox.tools.json
.sandcat/settings.local.json
# /Sandcat
```

The `!.devcontainer/devbox.tools.json` negation keeps the user-managed
tool list in git — it's the project-shared extension of the stack (see
[Stack and tool packages via devbox](#stack-and-tool-packages-via-devbox))
and travels with the repo even though everything else under
`.devcontainer/` is ignored.

The block is bracketed by `# Sandcat` / `# /Sandcat` sentinels so
sandcat can manage it symmetrically: enabling on a subsequent init is
a no-op when the block is already present, and disabling **removes**
the block cleanly (preserving your other rules).

**Opt out** if you'd rather keep the generated files in git (e.g. team
convention where each dev clones a ready-to-run devcontainer without
re-running `sandcat init`):

```bash
sandcat init --features no-gitignore ...
SANDCAT_GITIGNORE=false sandcat init ...
```

Both are equivalent — the env var is the scripted counterpart of the
interactive/CSV feature flag. If a Sandcat block already exists in
`.gitignore`, opting out on a re-init deletes the block (and, when
the block was the file's only content, deletes the file too). Rules
outside the sandcat markers are always preserved.

If the project is not a git working tree (no `.git/` directory), init
silently skips the gitignore step — no `.gitignore` gets created.

## Agent-specific setup

Per-agent onboarding, authentication, host paths, and RTK hooks live in the
**Agents** section: [Claude Code](../agents/claude.md),
[Cursor CLI](../agents/cursor.md), [Codex CLI](../agents/codex.md),
[GitHub Copilot CLI](../agents/copilot.md), [RTK](../agents/rtk.md).
