FROM debian:trixie-slim

#   ca-certificates - system CA store, needed for update-ca-certificates
#   gosu            - used by the entrypoint to drop privileges
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gh git gosu jq vim \
    && rm -rf /var/lib/apt/lists/*

# Devcontainer base images include a vscode user; plain images do not.
RUN useradd -m -s /bin/bash vscode

COPY --chmod=755 scripts/sandcat-init.sh /usr/local/bin/sandcat-init.sh
COPY --chmod=755 scripts/sandcat-user-init.sh /usr/local/bin/sandcat-user-init.sh

USER vscode

# Install mise (SDK manager), then use it to install Node.js and Claude Code.
RUN curl https://mise.run | sh
# Make mise available in login shells (su - vscode) and Docker CMD/RUN.
RUN echo 'export PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:$PATH"' >> /home/vscode/.profile
ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:$PATH"
RUN mise use -g node@lts \
    && npm install -g @anthropic-ai/claude-code

# Pre-create the Claude config directory and seed onboarding flag so Claude
# Code can use an API key from the environment without interactive setup.
RUN mkdir -p /home/vscode/.claude \
    && echo '{"hasCompletedOnboarding":true}' > /home/vscode/.claude.json

RUN echo 'alias claude-yolo="claude --dangerously-skip-permissions"' >> /home/vscode/.bashrc

USER root
ENTRYPOINT ["/usr/local/bin/sandcat-init.sh"]
