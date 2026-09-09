# Claude Code

Claude Code is sandcat's default agent (`--agent claude`, or simply omit the
flag). The sections below cover authentication, the host paths sandcat mounts
for it, and its RTK hook; everything generic — network policy, secret
mechanics, stacks — works the same for every agent.

## Authentication

Claude Code supports two authentication methods inside the container:

- **API key** — add an `ANTHROPIC_API_KEY` secret to `settings.json`. The
  entrypoint detects the key and seeds `~/.claude.json` with
  `{"hasCompletedOnboarding": true}` so Claude Code uses it without interactive
  setup.
- **Subscription (browser login)** — omit `ANTHROPIC_API_KEY` from
  `settings.json`. On first run Claude Code will display a URL and a code. Open
  the URL in a browser on your host machine, enter the code, and authenticate
  there — the container itself cannot open a browser.

**Autonomous mode.** The bundled `devcontainer.json` enables
`claudeCode.allowDangerouslySkipPermissions` and sets
`claudeCode.initialPermissionMode` to `bypassPermissions`. This lets Claude Code
run without interactive permission prompts inside the container. The trade-off:
sandcat already provides the security boundary (network isolation, secret
substitution, iptables kill-switch), so the in-container prompts add friction
without meaningful security benefit. Remove these settings if you prefer
interactive approval. See [Secure & Dangerous Claude Code + VS Code
Setup](https://warski.org/blog/secure-dangerous-claude-code-vs-code-setup/) for
background on this approach.

**Host customizations.** The example `compose-all.yml` bind-mounts
`~/.claude/CLAUDE.md`, `~/.claude/agents`, and `~/.claude/commands` from the
host (read-only) so your personal instructions, custom agents, and slash
commands are available inside the container. Remove any mount whose source does
not exist on your host — Docker will otherwise create an empty directory in its
place.

**Multi-line prompts.** Composing a multi-line prompt with `⌘+Enter` does not
work on macOS — the terminal reserves the `⌘` modifier and never transmits it
over the PTY, so `sandcat attach` (and Claude Code) only ever receive a plain
`Enter`. This is not sandcat-specific and cannot be fixed inside the container.
Use one of these instead:

- **`\` then `Enter`** — inserts a newline in any terminal with no setup. The
  simplest option.
- **`Option+Enter`** — Claude Code's macOS default. In Apple Terminal, first
  enable *Settings → Profiles → Keyboard → Use Option as Meta key*; iTerm2 sends
  it out of the box.
- **`Shift+Enter`** — the most familiar combination, but Claude Code only
  receives whatever bytes the terminal chooses to send for it, so it needs a
  one-time mapping in the **host** terminal. Claude Code's `/terminal-setup` is
  meant to install this, but it has two traps in this setup: it configures the
  host terminal, so running it from Claude Code *inside* the sandbox does
  nothing; and it caches an "installed" flag, so a second run reports *"already
  enabled"* even when the terminal was never actually changed. The reliable route
  is to map the key by hand:
  - **iTerm2** — Settings → Keys → Key Bindings → `+`, record `Shift+Enter`,
    choose *Send Hex Codes* and enter `0x1b 0x0d` (this is `Option+Enter`, which
    Claude Code treats as a newline). GUI bindings take effect immediately. To
    confirm it worked, run `cat -v` in the sandbox shell and press `Shift+Enter`:
    it should print `^[` instead of a blank line.
  - **VS Code integrated terminal** — add to `keybindings.json`:

    ```json
    { "key": "shift+enter",
      "command": "workbench.action.terminal.sendSequence",
      "args": { "text": "\u001b\r" },
      "when": "terminalFocus" }
    ```

## Host paths and mounts

**Claude paths** (host `~/.claude/`, read-only when mounted):

- `CLAUDE.md`, `agents/`, `commands/`

Project-local configuration (`.claude/` in the repo) and the isolation
semantics of these mounts are described in
[Customizing optional volume mounts](../configuration/volume-mounts.md).

## RTK hook

Works out of the box, zero configuration. `sandcat init` generates an
`app-user-init.sh` block that runs `rtk init -g --hook-only --auto-patch`
on the first container start; the hook lands in the sandbox's
`~/.claude/settings.json` (inside the `agent-home` volume, not
bind-mounted). Subsequent starts are idempotent no-ops.

See [RTK — LLM token compression](rtk.md) for what RTK does and how to opt
out.

## Convenience alias

Every claude sandbox ships a `claude-yolo` alias (= `claude
--dangerously-skip-permissions`): the sandcat network isolation is the
security boundary, so bypassing in-container permission prompts is the
intended workflow.
