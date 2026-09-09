# GitHub Copilot CLI

GitHub's [Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli)
(`@github/copilot`) is available as a first-class sandcat agent. Sandcat installs
Node.js 22 and the Copilot package into every copilot-agent sandbox and wires
`COPILOT_GITHUB_TOKEN` through the mitmproxy secret substitution layer.

**Setup:**

```bash
sandcat init --agent copilot --ide vscode
# Edit ~/.config/sandcat/settings.json — set secrets.COPILOT_GITHUB_TOKEN.value
sandcat run
copilot "explain this codebase"
```

**Authentication:** Copilot CLI requires a GitHub token. Choose one of:

1. **Fine-grained Personal Access Token (recommended):** Create a PAT at
   [`https://github.com/settings/personal-access-tokens`](https://github.com/settings/personal-access-tokens)
   with the **"Copilot Requests"** permission (Read and write). Then add it to
   `~/.config/sandcat/settings.json`:
   ```json
   {
     "secrets": {
       "COPILOT_GITHUB_TOKEN": {
         "value": "github_pat_...",
         "hosts": ["api.github.com", "*.github.com", "*.githubcopilot.com", "*.githubusercontent.com"]
       }
     }
   }
   ```

2. **GitHub CLI OAuth token (quick setup):** If you already have `gh` CLI logged in,
   run this once to write the token directly into `settings.json`:
   ```bash
   export TKN=$(gh auth token)
   yq -i -o json '.secrets.COPILOT_GITHUB_TOKEN.value = strenv(TKN)' \
     ~/.config/sandcat/settings.json
   ```

**Note:** Adding Node.js 22 and Copilot to the base image increases its size by
approximately 120 MB. The image is built once and cached locally; rebuilds are
fast.

**VS Code integration:** When the IDE is `vscode`, the bundled `devcontainer.json`
includes the `GitHub.copilot` extension. Note that the VS Code extension
authenticates through VS Code's own GitHub sign-in (not the `COPILOT_GITHUB_TOKEN`
env var used by the CLI), so you may need to sign in the first time you open the
extension.

**Placeholder:** Sandcat automatically sets the placeholder to
`gho_SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN`. The container sees only the
placeholder; the real token is injected by mitmproxy only for allowed Copilot
hosts. No manual configuration is needed.

**Bash alias:** `copilot-yolo` (= `copilot --yolo`) is available in every
copilot sandbox for parity with `claude-yolo` and `codex-yolo`. `--yolo` is
equivalent to `--allow-all-tools --allow-all-paths --allow-all-urls` — the
sandcat network isolation is the security boundary, so bypassing in-container
permission prompts is the intended workflow.
