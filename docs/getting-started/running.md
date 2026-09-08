# Starting the sandbox

**CLI mode:**

```bash
# Open a shell in the agent container
sandcat run

# Rebuild images first (after editing Dockerfile.app or scripts)
sandcat run --build

# Start your agent cli (e.g. claude). Because you're in a sandbox, you can use yolo mode!
# (an alias for --dangerously-skip-permissions)
claude-yolo
```

**Attaching to a running container:**

If the sandbox is already running (e.g. started by VS Code's devcontainer integration or
another terminal), use `attach` to open an additional shell in it without starting a new
container:

```bash
sandcat attach           # opens bash --login
sandcat attach <cmd>     # runs <cmd> directly, e.g. sandcat attach zsh
```

Unlike `sandcat run`, this connects to an existing container rather than starting a fresh one.
It uses `find_compose_file` to locate the correct project, so it works reliably even when
multiple sandboxes are running in parallel.
