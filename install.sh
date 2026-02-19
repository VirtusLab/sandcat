#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/softwaremill/sandcat/master"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PROJECT_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --name=*)
      PROJECT_NAME="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--name <project-name>]"
      echo ""
      echo "Sets up a Sandcat dev container in .devcontainer/"
      echo ""
      echo "Options:"
      echo "  --name    Project name (defaults to current directory name)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="$(basename "$PWD")"
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
SANDCAT_DIR=".devcontainer/sandcat"
TEMPLATE_FILES=(".devcontainer/compose-all.yml" ".devcontainer/Dockerfile.app" ".devcontainer/devcontainer.json")

if [[ -d "$SANDCAT_DIR" ]]; then
  echo "Error: $SANDCAT_DIR already exists. Aborting." >&2
  exit 1
fi

for f in "${TEMPLATE_FILES[@]}"; do
  if [[ -e "$f" ]]; then
    echo "Error: $f already exists. Aborting." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Download shared infrastructure files
# ---------------------------------------------------------------------------
echo "Downloading Sandcat files into $SANDCAT_DIR/ ..."

mkdir -p "$SANDCAT_DIR/scripts"

SHARED_FILES=(
  "compose-proxy.yml"
  "Dockerfile.wg-client"
  "settings.example.json"
  "scripts/app-init.sh"
  "scripts/app-post-start.sh"
  "scripts/app-user-init.sh"
  "scripts/mitmproxy_addon.py"
  "scripts/wg-client-init.sh"
)

for file in "${SHARED_FILES[@]}"; do
  curl -fsSL "$REPO_URL/$file" -o "$SANDCAT_DIR/$file"
done

echo "Downloaded shared files."

# ---------------------------------------------------------------------------
# Download and adapt template files
# ---------------------------------------------------------------------------
echo "Generating project files in .devcontainer/ ..."

# compose-all.yml: adjust include path, volume mount context, project name
curl -fsSL "$REPO_URL/compose-all.yml" \
  | sed \
    -e "s|^name: sandcat|name: $PROJECT_NAME|" \
    -e "s|^  - path: compose-proxy.yml|  - path: sandcat/compose-proxy.yml|" \
    -e "s|\.:/workspaces/sandcat:cached|..:/workspaces/$PROJECT_NAME:cached|" \
    -e "s|\./.devcontainer:/workspaces/sandcat/.devcontainer:ro|../.devcontainer:/workspaces/$PROJECT_NAME/.devcontainer:ro|" \
  > .devcontainer/compose-all.yml

# Dockerfile.app: adjust COPY paths, add CUSTOMIZE marker
curl -fsSL "$REPO_URL/Dockerfile.app" \
  | sed \
    -e "s|COPY \(--chmod=755 \)scripts/|COPY \1sandcat/scripts/|" \
    -e "s|# Add your language toolchain|# CUSTOMIZE: add your language toolchain|" \
  > .devcontainer/Dockerfile.app

# devcontainer.json: adjust compose path, project name, postStartCommand path
curl -fsSL "$REPO_URL/.devcontainer/devcontainer.json" \
  | sed \
    -e "s|\"../compose-all.yml\"|\"compose-all.yml\"|" \
    -e "s|/workspaces/sandcat/scripts/|/workspaces/$PROJECT_NAME/.devcontainer/sandcat/scripts/|" \
    -e "s|/workspaces/sandcat|/workspaces/$PROJECT_NAME|" \
    -e "s|\"name\": \"Sandcat\"|\"name\": \"$PROJECT_NAME\"|" \
  > .devcontainer/devcontainer.json

# ---------------------------------------------------------------------------
# Verify transformations
# ---------------------------------------------------------------------------
ERRORS=0
verify() {
  if ! grep -q "$1" "$2"; then
    echo "Warning: expected pattern not found in $2: $1" >&2
    ERRORS=$((ERRORS + 1))
  fi
}
verify "^name: $PROJECT_NAME" .devcontainer/compose-all.yml
verify "path: sandcat/compose-proxy.yml" .devcontainer/compose-all.yml
verify "/workspaces/$PROJECT_NAME:cached" .devcontainer/compose-all.yml
verify "/workspaces/$PROJECT_NAME/.devcontainer:ro" .devcontainer/compose-all.yml
verify "sandcat/scripts/app-init.sh" .devcontainer/Dockerfile.app
verify "\"compose-all.yml\"" .devcontainer/devcontainer.json
verify "/workspaces/$PROJECT_NAME\"" .devcontainer/devcontainer.json
verify "\"name\": \"$PROJECT_NAME\"" .devcontainer/devcontainer.json
if [[ $ERRORS -gt 0 ]]; then
  echo "Error: $ERRORS transformation(s) failed. The upstream template files" >&2
  echo "may have changed. Please check the generated files or file an issue" >&2
  echo "at https://github.com/softwaremill/sandcat/issues" >&2
  exit 1
fi

echo ""
echo "Done! Created .devcontainer/ layout for '$PROJECT_NAME':"
echo ""
echo "  .devcontainer/"
echo "  ├── sandcat/           (shared infrastructure — do not edit)"
echo "  ├── compose-all.yml"
echo "  ├── Dockerfile.app"
echo "  └── devcontainer.json"
echo ""
echo "Next steps:"
echo "  1. Customize .devcontainer/Dockerfile.app — look for the CUSTOMIZE"
echo "     marker to add your language toolchain (python, rust, java, etc.)."
echo "  2. Set up your secrets and network rules:"
echo "     mkdir -p ~/.config/sandcat"
echo "     cp .devcontainer/sandcat/settings.example.json ~/.config/sandcat/settings.json"
echo "     # Edit with your real values"
echo "  3. Open the project in VS Code and reopen in the dev container,"
echo "     or start from the command line:"
echo "     docker compose -f .devcontainer/compose-all.yml run --rm --build app bash"
