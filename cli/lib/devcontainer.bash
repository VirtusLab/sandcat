#!/usr/bin/env bash

# Replaces __PROJECT_NAME__ placeholder with the actual project name in devcontainer.json.
#
# Uses `sed` because `yq` does not support JSONC
# Args:
#   $1 - Path to the devcontainer.json file
#   $2 - Project name to substitute
customize_devcontainer_json() {
	local devcontainer_json=$1
	local project_name=$2

	# Use sed in a way that works on both BSD (macOS) and GNU (Linux)
	sed -i.bak "s/__PROJECT_NAME__/${project_name}/g" "$devcontainer_json" && rm -f "${devcontainer_json}.bak"
}
