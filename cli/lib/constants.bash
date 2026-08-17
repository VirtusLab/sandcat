#!/usr/bin/env bash
# Core constants for sandcat

# User config directory. Function instead of variable so it respects
# HOME changes (e.g. in tests).
sct_home() { echo "$HOME/.config/sandcat"; }

export SCT_PROJECT_DIR='.sandcat'

# Pinned mitmproxy image version used by CLI-generated compose files.
# Keep in sync with the build-side counterpart in images/mitmproxy.env —
# a contract test asserts the two stay equal.
export SCT_MITMPROXY_VERSION="12.2.3"
