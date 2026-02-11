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
