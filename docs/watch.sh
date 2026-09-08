#!/usr/bin/env bash
# Live-reload docs preview: pip install -r requirements.txt, then ./watch.sh
set -euo pipefail
cd "$(dirname "$0")"
sphinx-autobuild . _build/html "$@"
