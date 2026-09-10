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
# The docker CLI discovers plugins client-side (~/.docker/cli-plugins);
# link the set the dind service published so `docker compose` / `docker
# buildx` work. agent-home is a writable volume, so the link persists;
# the guard keeps this a one-time, idempotent action.
if [ -d /docker-sock/cli-plugins ] && [ ! -e "$HOME/.docker/cli-plugins" ]; then
    mkdir -p "$HOME/.docker" 2>/dev/null \
        && ln -s /docker-sock/cli-plugins "$HOME/.docker/cli-plugins" 2>/dev/null
fi
# Testcontainers assumes "docker host = localhost" for a unix socket, but
# inner ports publish in the dind service's namespace — point it there.
if [ -S /docker-sock/docker.sock ]; then
    export TESTCONTAINERS_HOST_OVERRIDE="dind"
fi
