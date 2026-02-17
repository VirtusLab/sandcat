#!/bin/bash
#
# Post-start hook for VS Code dev containers.
# Runs after VS Code connects and sets up its remote server.
#
# VS Code forwards the host SSH agent socket into the container,
# allowing any process to sign challenges using the host's SSH keys.
# Clearing SSH_AUTH_SOCK (via remoteEnv) hides the path from the
# environment, but the socket file still exists in /tmp and can be
# discovered by scanning. Remove it as a best-effort hardening measure.
#
# This is not bulletproof — VS Code could recreate the socket on
# reconnect, or change the naming pattern in future versions.
#
set -e

found=0
for sock in /tmp/vscode-ssh-auth-*.sock; do
    # Guard against the unexpanded glob (no matches).
    [ -e "$sock" ] || continue
    if rm -f "$sock" 2>/dev/null; then
        echo "sandcat: removed forwarded SSH agent socket: $sock"
    else
        echo "sandcat: warning: could not remove $sock (owned by root?)" >&2
        echo "sandcat: SSH_AUTH_SOCK is cleared, but the socket file remains" >&2
    fi
    found=1
done

if [ "$found" -eq 0 ]; then
    echo "sandcat: warning: no VS Code SSH agent socket found in /tmp" >&2
    echo "sandcat: the socket path pattern may have changed — review post-start script" >&2
fi
