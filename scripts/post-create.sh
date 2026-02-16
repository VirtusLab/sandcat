#!/bin/bash
# Post-create setup for the dev container.
# Called by devcontainer.json postCreateCommand.
set -e

# Claude Code requires hasCompletedOnboarding to use an API key from the
# environment. Set it automatically if not already present.
CLAUDE_JSON="$HOME/.claude.json"
if [ ! -f "$CLAUDE_JSON" ]; then
    echo '{"hasCompletedOnboarding":true}' > "$CLAUDE_JSON"
elif ! jq -e '.hasCompletedOnboarding' "$CLAUDE_JSON" >/dev/null 2>&1; then
    jq '.hasCompletedOnboarding = true' "$CLAUDE_JSON" > /tmp/claude.json \
        && mv /tmp/claude.json "$CLAUDE_JSON"
fi

# Configure git identity from environment variables. Host .gitconfig is not
# copied into the container (to avoid leaking credential helpers), so set
# GIT_USER_NAME and GIT_USER_EMAIL via the env section in settings.json.
if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# Add claude-yolo alias
echo 'alias claude-yolo="claude --dangerously-skip-permissions"' >> ~/.bashrc

# Ensure mounted directories exist & fix ownership (Docker volumes are created as root)
mkdir -p /home/vscode/.claude
sudo chown -R vscode:vscode /home/vscode/.claude 2>/dev/null || true