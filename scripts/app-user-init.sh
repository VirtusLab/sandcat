#!/bin/bash
#
# vscode-user tasks run via su from app-init.sh.
# /etc/profile.d/ is sourced by the login shell, providing
# GIT_USER_NAME, GIT_USER_EMAIL, and NODE_EXTRA_CA_CERTS.
#
set -e

if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# Best-effort: may fail if network isn't routed yet or CLI was just installed.
claude update || true
