# Applying configuration changes

Mitmproxy reads settings files only at startup (no hot-reload), and the app
container sources `sandcat.env` only during its entrypoint. After editing any
settings file, you need to restart services for changes to take effect.

You can use the CLI helper commands:

```sh
sandcat edit project-settings   # project network rules (.sandcat/settings.json)
sandcat edit user-settings      # API keys, git identity (~/.config/sandcat/settings.json)
sandcat edit dockerfile         # container Dockerfile (.devcontainer/Dockerfile.app)
sandcat edit compose            # Docker Compose file (.devcontainer/compose-all.yml)
```

After editing a settings file, restart the proxy to apply changes:

```sh
sandcat restart
```

Note that VS Code's **Rebuild Container** only rebuilds the `agent` service — it
does not restart `mitmproxy` or `wg-client`. Use `sandcat restart` to
apply settings changes.
