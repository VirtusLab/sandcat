#!/bin/bash
set -e

# Keep the CLI version of Claude Code up to date. The VS Code extension
# updates itself, but the CLI installed via the devcontainer feature does not.
sudo env PATH="$PATH" claude update
