# Gitignore defaults

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
[Stack and tool packages via devbox](stacks.md))
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
