# Shell installer — design spec

**Date:** 2026-08-04
**Status:** Draft (pending user review)
**Issue:** [VirtusLab/sandcat#30](https://github.com/VirtusLab/sandcat/issues/30) — "feat: Shell installer"

## Summary

Add an `install.sh` script at repo root that installs sandcat CLI on a user's host with a single `curl -fsSL ... | sh` invocation — analog to the install scripts users already use for `rtk`, `claude`, `cursor`, and `codex`. The script fetches a tarball snapshot of the sandcat repo from GitHub, unpacks it under `$XDG_DATA_HOME/sandcat/` (default `~/.local/share/sandcat/`), and drops a symlink into `~/.local/bin/sandcat`. Supports version pinning via `SANDCAT_REF`, upgrade via re-run, and clean uninstall via `--uninstall`.

## Motivation

Sandcat currently offers two install methods (docker image, git clone). Issue #30 asks for a third — a shell installer that requires neither Docker nor Git. Analog to the ecosystem convention (`curl … | sh`), it removes friction for first-time users and matches how sandcat's own supported agents (claude/cursor/codex) are installed. This design also anticipates a future semver release workflow without needing installer rewrite when it arrives.

## Non-goals

- **Windows-native support.** Bash-only script; Windows users continue using Docker image or WSL.
- **Auto-install yq.** yq is a hard prerequisite for sandcat CLI (Mike Farah's Go variant). Cross-platform auto-install has too many edge cases (macOS brew vs Linux snap vs apt-Python-yq footgun). Installer detects + refuses with per-OS instructions; user takes one manual step.
- **`sandcat self-update` subcommand.** YAGNI in v1 — re-running `install.sh` handles upgrade cleanly (analog to how `rustup` uses the same shell script for install and update). Can be a thin wrapper in a follow-up PR.
- **Signature/hash verification of the tarball.** No signing infrastructure exists today; adding it here would block on release-flow decisions. Can be added when semver releases are introduced.
- **Shell completions / man page install.** Out of scope; sandcat has none today.
- **Release flow itself.** This spec assumes `master` branch tarballs work for v1. When the team introduces semver tags, installer requires zero rewrite (see [Forward compatibility](#forward-compatibility)).

## Architecture

### File location

- `install.sh` in repo root (alongside `Dockerfile`, `README.md`).
- Published one-liner (documented in README):
  ```bash
  curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
  ```

### Install layout (defaults)

```
$SANDCAT_HOME/                          ← ~/.local/share/sandcat/ by default
└── cli/
    ├── bin/sandcat
    ├── lib/
    ├── libexec/
    ├── templates/
    ├── support/
    └── .version                        ← "master (installed 2026-08-04 14:22:03)"

$SANDCAT_BIN_DIR/sandcat                ← ~/.local/bin/sandcat
                                          symlink → $SANDCAT_HOME/cli/bin/sandcat

~/.config/sandcat/settings.json         ← user config (untouched by installer,
                                          created by `sandcat init` at first use)
```

### Rationale for XDG paths

XDG Base Directory Specification maps files by role: config → `XDG_CONFIG_HOME` (`~/.config/`), installed data → `XDG_DATA_HOME` (`~/.local/share/`), user binaries → `~/.local/bin/`. Sandcat is already partially XDG-aligned: `sct_home()` in `cli/lib/constants.bash` resolves user settings to `~/.config/sandcat/`. Putting the CLI install under `~/.local/share/sandcat/` completes the alignment (config in XDG_CONFIG_HOME, data in XDG_DATA_HOME, launcher in `~/.local/bin/`).

Newer install-script tools (mise, fnm, devbox) use XDG paths for the same reason. Older tools (rustup, nvm, pyenv) use top-level `~/.tool/` dotdirs — a historical convention that predates widespread XDG adoption.

### Env var interface

| Var | Default | Purpose |
|---|---|---|
| `SANDCAT_HOME` | `$HOME/.local/share/sandcat` | Install root (where `cli/` lives) |
| `SANDCAT_BIN_DIR` | `$HOME/.local/bin` | Where the launcher symlink goes |
| `SANDCAT_REF` | `master` | Branch / tag / commit sha to install |
| `SANDCAT_NON_INTERACTIVE` | `false` | Skip all prompts (CI-friendly) |

### Symlink strategy

`ln -sf $SANDCAT_HOME/cli/bin/sandcat $SANDCAT_BIN_DIR/sandcat` creates a symlink at the launcher path. Sandcat's `cli/bin/sandcat` computes `SCT_ROOT="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.."` — `readlink -f` follows the symlink to the real path, so `SCT_ROOT` resolves correctly to `$SANDCAT_HOME/cli/`. No change to sandcat runtime code is needed.

### Version handling

`install.sh` writes `$SANDCAT_HOME/cli/.version` containing `$SANDCAT_REF (installed <ISO date>)`. Sandcat's existing `libexec/version/version` command already has a fallback path:

```bash
if [[ -s "$path/.version" ]]; then
    ver=$(<"$path/.version")
    echo "$name $ver" | info
```

So `sandcat version` correctly reports version even when `.git/` is not present (which is the case for tarball installs). No sandcat runtime code changes required.

## install.sh flow

Pseudo-code / logical steps:

```
1. parse_args
   • --uninstall  → jump to uninstall flow
   • --help       → print usage + exit
   • (env vars are primary interface)

2. check_prerequisites
   • command -v curl (fallback wget)
   • command -v tar
   • command -v yq && yq --version | grep -q mikefarah
     → if missing/wrong: print per-OS install instructions + exit 1

3. resolve_paths
   • SANDCAT_HOME       = ${SANDCAT_HOME:-$HOME/.local/share/sandcat}
   • SANDCAT_BIN_DIR    = ${SANDCAT_BIN_DIR:-$HOME/.local/bin}
   • SANDCAT_REF        = ${SANDCAT_REF:-master}
   • TMP_DIR            = $(mktemp -d)     # trap-cleaned on exit

4. detect_existing_install
   • if [ -d "$SANDCAT_HOME/cli" ]:
     - SANDCAT_NON_INTERACTIVE=true → silent overwrite
     - else → prompt "Sandcat already installed. Overwrite? [y/N]"

5. fetch_tarball
   • URL: https://codeload.github.com/VirtusLab/sandcat/tar.gz/$SANDCAT_REF
   • curl -fsSL "$URL" -o "$TMP_DIR/sandcat.tar.gz"
   • on 404: error "Reference '$SANDCAT_REF' not found in VirtusLab/sandcat"

6. extract
   • tar xzf "$TMP_DIR/sandcat.tar.gz" -C "$TMP_DIR"
   • source_dir = "$TMP_DIR/sandcat-*/cli"  (glob — dir name is sandcat-<ref-slug>)

7. install_files (near-atomic swap)
   • mkdir -p "$SANDCAT_HOME"
   • # Two-phase swap so a mv failure doesn't leave the user without a cli:
   • # extract new tree beside the old one, then rename in one syscall.
   • rm -rf "$SANDCAT_HOME/cli.new"
   • mv "$source_dir" "$SANDCAT_HOME/cli.new"
   • rm -rf "$SANDCAT_HOME/cli.old"          # any leftover from prior aborted swap
   • [ -d "$SANDCAT_HOME/cli" ] && mv "$SANDCAT_HOME/cli" "$SANDCAT_HOME/cli.old"
   • mv "$SANDCAT_HOME/cli.new" "$SANDCAT_HOME/cli"
   • rm -rf "$SANDCAT_HOME/cli.old"
   • echo "$SANDCAT_REF (installed $(date +'%F %T'))" > "$SANDCAT_HOME/cli/.version"

8. install_symlink
   • mkdir -p "$SANDCAT_BIN_DIR"
   • ln -sf "$SANDCAT_HOME/cli/bin/sandcat" "$SANDCAT_BIN_DIR/sandcat"

9. verify
   • "$SANDCAT_BIN_DIR/sandcat" version >/dev/null
     → catches broken symlink / bad extraction early

10. print_success
    • "Installed sandcat $SANDCAT_REF to $SANDCAT_HOME/cli/"
    • PATH check: if $SANDCAT_BIN_DIR not in $PATH, print .bashrc line
    • "Next: run `sandcat init` in your project"

11. cleanup  (also on trap ERR / EXIT)
    • rm -rf "$TMP_DIR"
```

### Uninstall flow (`install.sh --uninstall`)

```
1. resolve_paths (same as install)
2. if [ ! -d "$SANDCAT_HOME/cli" ]:
     print "Sandcat is not installed at $SANDCAT_HOME"; exit 0
3. confirm removal (unless SANDCAT_NON_INTERACTIVE=true):
     prompt "Remove sandcat install at $SANDCAT_HOME/cli/? [y/N]"
4. rm -f "$SANDCAT_BIN_DIR/sandcat"       # symlink
5. rm -rf "$SANDCAT_HOME/cli"             # install files
6. if [ -d "$SANDCAT_HOME" ] && [ -z "$(ls -A "$SANDCAT_HOME")" ]:
     rmdir "$SANDCAT_HOME"                # remove parent only if empty
7. print completion:
   - "Removed sandcat install ($SANDCAT_HOME/cli/) and launcher ($SANDCAT_BIN_DIR/sandcat)"
   - "User settings preserved at ~/.config/sandcat/"
   - "Docker images and cache volumes preserved. Run `docker rmi` or `sandcat cache rm --all` manually if desired."
```

### Set-flag hygiene

`install.sh` starts with `set -euo pipefail` to fail fast on any error. Traps ensure cleanup:

```bash
trap 'cleanup; exit 1' ERR
trap 'cleanup' EXIT
```

## Forward compatibility

The install.sh **interface is designed to survive a future semver release rollout**. Today the team publishes only `ghcr.io/virtuslab/sandcat` Docker image with `master` / `sha-*` / `latest` tags — no git tags, no `gh release`, no `CHANGELOG.md`. When the team introduces semver tags:

- Users can immediately pin: `curl … | SANDCAT_REF=v1.0.0 sh` (works today too, would just 404 on an unreleased tag).
- Installer's default `SANDCAT_REF=master` remains valid.
- Optional future upgrade: add a `SANDCAT_REF=latest` "smart default" that queries `https://api.github.com/repos/VirtusLab/sandcat/releases/latest` and installs the tag from there — one-function change in the installer, no user-visible interface change.

No refactoring of install.sh is required at that point — the whole flow (fetch tarball → extract → symlink) remains the same.

## User-facing behavior

### Fresh install (default)

```bash
$ curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
[INFO] Sandcat installer
[INFO] Checking prerequisites... OK
[INFO] Fetching master from codeload.github.com...
[INFO] Extracting to /home/alice/.local/share/sandcat/cli/
[INFO] Installed sandcat master (installed 2026-08-04 14:22:03)
[INFO] Symlinked /home/alice/.local/bin/sandcat -> /home/alice/.local/share/sandcat/cli/bin/sandcat
[INFO] Sandcat master (installed 2026-08-04 14:22:03)

Next steps:
  Ensure $HOME/.local/bin is in your PATH (add to .bashrc if needed):
    export PATH="$HOME/.local/bin:$PATH"
  Then in your project directory:
    sandcat init
```

### PATH not configured

If `$SANDCAT_BIN_DIR` (i.e. `~/.local/bin`) is not in the current `$PATH`, the installer prints an actionable hint (the `export PATH=` line above) but proceeds. Installer never edits user's `~/.bashrc` automatically — leaves that as an explicit user action.

### Version pinning

```bash
curl -fsSL https://.../install.sh | SANDCAT_REF=e78ba6c sh    # pin to commit
curl -fsSL https://.../install.sh | SANDCAT_REF=v1.0.0 sh     # pin to tag (when tags exist)
curl -fsSL https://.../install.sh | SANDCAT_REF=my-branch sh  # test a branch
```

### Custom paths

```bash
# System-wide install (needs sudo)
sudo SANDCAT_HOME=/opt/sandcat SANDCAT_BIN_DIR=/usr/local/bin bash install.sh

# Non-standard user path
SANDCAT_HOME="$HOME/tools/sandcat" SANDCAT_BIN_DIR="$HOME/tools/bin" bash install.sh
```

### Upgrade (re-run)

```bash
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
# Interactive terminal:
Sandcat already installed at /home/alice/.local/share/sandcat/cli
Overwrite? [y/N]: y
# Silent for CI:
SANDCAT_NON_INTERACTIVE=true curl … | sh
```

### Uninstall

```bash
bash <(curl -fsSL https://.../install.sh) --uninstall
# Or if you cloned:
./install.sh --uninstall
```

## Edge cases

| Case | Behavior |
|---|---|
| No internet | `curl -f` fails → exit 1 with URL in error message |
| Bad `SANDCAT_REF` (404) | Explicit error: `"Reference '$SANDCAT_REF' not found in VirtusLab/sandcat"` |
| `~/.local/bin/sandcat` exists as regular file (not symlink) | `ln -sf` overwrites; warning printed |
| Existing symlink to different install path | `ln -sf` silently overwrites (symlinks are always replaceable) |
| `$SANDCAT_HOME` exists as file, not dir | Fail: `"$SANDCAT_HOME already exists as a file. Move it and retry."` |
| yq missing or wrong variant | Refuse install with per-OS instructions (see [Prerequisite check](#prerequisite-check)) |
| curl unavailable but wget present | Fallback to `wget -qO-` |
| Neither curl nor wget | Fail with "Install curl or wget and retry" |
| tar extraction fails mid-way | Trap cleans TMP_DIR; SANDCAT_HOME/cli/ untouched (mv is atomic on step 7); previous install preserved |
| `set -e` catches any failure | Trap runs cleanup; exit 1 |
| User runs installer as root without setting SANDCAT_HOME/BIN_DIR | Uses root's `$HOME` = `/root` — probably not what they want. Print warning: "Running as root: files will be installed under /root/. Set SANDCAT_HOME/SANDCAT_BIN_DIR for system-wide install." |

### Prerequisite check

`install.sh` requires `yq` — Mike Farah's Go variant. Check:

```bash
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q mikefarah; then
    print_yq_instructions
    exit 1
fi
```

The `mikefarah` grep is the same detection used by sandcat runtime (`cli/lib/require.bash`). Instructions vary per OS:

- **macOS:** `brew install yq`
- **Debian/Ubuntu:** `snap install yq`  (with warning that `apt install yq` installs the Python variant which is incompatible)
- **Alpine:** `apk add yq-go`
- **Fallback:** download from `https://github.com/mikefarah/yq/releases` and drop the binary on `$PATH`

OS detection via `$OSTYPE` and `/etc/os-release`.

## Testing

### Unit (bats)

New suite: `cli/test/installer/installer.bats`. Uses `HOME=$BATS_TEST_TMPDIR/home` for isolation; mocks `curl`/`tar` via bats-mock stubs.

Test cases:

- `install.sh installs to $SANDCAT_HOME/cli/` — fresh install, symlink resolves, `.version` file has ref+date
- `install.sh --uninstall removes install but preserves ~/.config/sandcat/`
- `install.sh detects existing install and prompts in interactive mode`
- `SANDCAT_NON_INTERACTIVE=true install.sh overwrites without prompt`
- `install.sh fails with clear error on 404 SANDCAT_REF` (stub curl to return 404)
- `install.sh detects missing yq and exits with per-OS instructions` (stub `command -v`)
- `install.sh detects Python yq variant and exits` (stub `yq --version` → "Python yq output")
- `install.sh symlink resolves back to install path via readlink -f`
- `install.sh warns if SANDCAT_BIN_DIR is not on PATH`
- `install.sh writes .version file with SANDCAT_REF and ISO timestamp`
- `install.sh --uninstall exits 0 on missing install with message`
- `install.sh --help prints usage and exits 0`
- `install.sh custom SANDCAT_HOME + SANDCAT_BIN_DIR are honored`

Fixture: `cli/test/installer/fixtures/tarball.tar.gz` — minimal sandcat structure (`sandcat-master/cli/{bin,lib,libexec,templates}/`). Enough to satisfy extraction step + symlink verification without hitting real GitHub.

### Integration (executed hands-on after implementation)

1. **Fresh install to scratch paths:**
   ```bash
   SANDCAT_HOME=/tmp/sandcat-integ SANDCAT_BIN_DIR=/tmp/sandcat-integ-bin \
       bash install.sh
   /tmp/sandcat-integ-bin/sandcat version
   ```
2. **Version pin:** `SANDCAT_REF=<recent-commit-sha> bash install.sh` — verify `.version` reflects sha.
3. **Update:** run again with `SANDCAT_REF=master` — verify existing install replaced cleanly.
4. **Bad ref:** `SANDCAT_REF=bogusref bash install.sh` — verify exit 1 + clear error.
5. **Uninstall:** `bash install.sh --uninstall` — verify cleanup + user config preserved.
6. **PATH hint:** run with `PATH=/usr/bin` (no ~/.local/bin) — verify hint printed.
7. **yq missing:** temporarily `alias yq=false` — verify installer exits with instructions.

## Documentation

- **README.md** (top-level): new subsection under "Install sandcat CLI", between Docker image and Local install:
  ```markdown
  #### Shell installer

  Install sandcat CLI to `~/.local/share/sandcat/` with a symlink in `~/.local/bin/sandcat`.
  Requires yq (Mike Farah's Go variant) pre-installed.

  \`\`\`bash
  curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
  \`\`\`

  Version pinning:
  \`\`\`bash
  curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | SANDCAT_REF=v1.0.0 sh
  \`\`\`

  Uninstall:
  \`\`\`bash
  bash <(curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh) --uninstall
  \`\`\`

  Env overrides: `SANDCAT_HOME`, `SANDCAT_BIN_DIR`, `SANDCAT_REF`, `SANDCAT_NON_INTERACTIVE`.
  ```
- **cli/README.md**: link to installer section in README.md.
- **install.sh `--help`**: inline usage + env vars.

## Rollback plan

Feature is purely additive:

- New file: `install.sh`
- New test suite: `cli/test/installer/`
- README additions

Revert the feature commit removes all of them. No runtime code changes in existing sandcat CLI (the `.version` file fallback already exists at `cli/libexec/version/version:17-20`).

## Open questions

None at design-approval time. Decisions locked:

- Install path: `~/.local/share/sandcat/` (XDG_DATA_HOME), override via `SANDCAT_HOME`
- Symlink: `~/.local/bin/sandcat` (`SANDCAT_BIN_DIR` override)
- Tarball source: `codeload.github.com/VirtusLab/sandcat/tar.gz/$SANDCAT_REF` (default `master`)
- yq: detect + refuse install with per-OS instructions
- Update: re-run `install.sh`
- Uninstall: `install.sh --uninstall`
- Version: `.version` file in install dir (existing sandcat fallback)

## Follow-ups (not in this spec)

- `sandcat self-update` subcommand as thin wrapper around install.sh.
- Semver release flow (git tags + `gh release create`) — enables `SANDCAT_REF=latest` smart default.
- Tarball hash verification once a release publishing pipeline exists.
- Shell completions and man page install.
- Windows-native installer (PowerShell) — separate concern; probably use WSL as the pragmatic answer for v1.
