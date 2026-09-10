#!/bin/bash
# Exposes the sandboxed Docker daemon to shells when the dind service is
# present (sandcat init --features docker). Guarded, so images built without
# the feature are unaffected. Same pattern as sandcat-java.sh.
if [ -S /docker-sock/docker.sock ]; then
    export DOCKER_HOST="unix:///docker-sock/docker.sock"
fi
if [ -d /docker-sock/bin ]; then
    case ":$PATH:" in
        *":/docker-sock/bin:"*) ;;
        *) export PATH="/docker-sock/bin:$PATH" ;;
    esac
fi
