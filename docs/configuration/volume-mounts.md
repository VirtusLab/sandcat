# Customizing optional volume mounts

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
| Any       | `SANDCAT_MOUNT_SHARED_CACHE`  | `true` — see [Shared dependency caches](caches.md) |
| Any       | `SANDCAT_GITIGNORE`           | `true` (see [Gitignore defaults](gitignore.md)) |
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
