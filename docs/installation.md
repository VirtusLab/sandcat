# Installation

The [CLI](reference/cli.md) is a helper script and thin wrapper around
docker-compose that simplifies the process of initializing and starting the
sandbox.

It has two main tasks:
* copy the necessary configuration files from the `cli/templates` directory into
  your project and customize them based on your choices (development stack,
  etc.)
* run `docker compose` commands with the correct compose file automatically
  detected, so you don't have to remember the file names or paths.

## Shell installer (recommended)

Install sandcat CLI to `~/.local/share/sandcat/` with a launcher symlink
at `~/.local/bin/sandcat`. Requires `yq` (Mike Farah's Go variant) already
installed on the host — see [yq prerequisite](#yq-prerequisite) below.

```bash
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
```

Ensure `~/.local/bin` is on your `PATH` (the installer prints a hint if it
isn't), then jump to [Initialize the sandbox](getting-started/quickstart.md#2-initialize-the-sandbox-for-your-project).

**Upgrade:** re-run the same command. The installer atomically swaps the
existing install; `~/.config/sandcat/` (user settings) is never touched.
Combine with `SANDCAT_REF` to jump to a different branch/tag/commit:

```bash
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | SANDCAT_REF=v1.0.0 sh
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | SANDCAT_REF=abc123 sh
```

Custom paths (env overrides), e.g. system-wide install:

```bash
SANDCAT_HOME=/opt/sandcat SANDCAT_BIN_DIR=/usr/local/bin \
    curl -fsSL https://.../install.sh | sudo -E sh
```

Non-interactive mode (CI):

```bash
curl -fsSL https://.../install.sh | SANDCAT_NON_INTERACTIVE=true sh
```

Uninstall (preserves user config and Docker state):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh) --uninstall
```

Env overrides in one place:

| Var | Default | Purpose |
|---|---|---|
| `SANDCAT_HOME` | `$HOME/.local/share/sandcat` | Install root |
| `SANDCAT_BIN_DIR` | `$HOME/.local/bin` | Launcher symlink dir |
| `SANDCAT_REF` | `master` | Branch / tag / commit to fetch |
| `SANDCAT_NON_INTERACTIVE` | `false` | Skip all prompts (CI) |

## Alternative: git clone

For contributors, or if you prefer to track a working tree directly:

```bash
# Clone the repo
git clone https://github.com/VirtusLab/sandcat.git

# Add the sandcat bin directory to your path (add this to your .bashrc or .zshrc)
export PATH="$PWD/sandcat/cli/bin:$PATH"
```

Update via `git pull` in the cloned directory.

## yq prerequisite

`yq` is required to edit compose files. Sandcat uses [Mike Farah's Go `yq`](https://github.com/mikefarah/yq); the unrelated Python `yq` (kislyuk/yq) is **not** compatible.

On Debian/Ubuntu, `apt install yq` installs the Python variant. Install Mike Farah's `yq` instead — for example `snap install yq`, or download a binary from the [release page](https://github.com/mikefarah/yq/releases). Homebrew and Alpine `apk` already ship the correct one.
