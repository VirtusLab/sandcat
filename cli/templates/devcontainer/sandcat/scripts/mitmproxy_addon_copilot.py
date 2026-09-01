"""
Copilot-focused mitmproxy addon: network access rules and secret substitution.

Loaded via: mitmweb -s /scripts/mitmproxy_addon_copilot.py

Thin wrapper around the shared :mod:`mitmproxy_addon_common` library.
GitHub Copilot CLI sends chat completions over HTTPS to
``api.<tier>.githubcopilot.com`` with SSE streaming responses; requests
are plain JSON, so the base ``SandcatAddon`` class's buffered-body
behaviour handles both the streaming response and the placeholder
leak check on requests. No streaming flags required (unlike Cursor).

On startup, reads settings from up to three layers (lowest to highest
precedence): user (``~/.config/sandcat/settings.json``), project
(``.sandcat/settings.json``), and local (``.sandcat/settings.local.json``).
Env vars and secrets are merged (higher precedence wins on conflict).
Network rules are concatenated (highest precedence first).

Network rules are evaluated top-to-bottom, first match wins, default deny.
Secret placeholders are replaced with real values only for allowed hosts.
"""

from mitmproxy_addon_common import SandcatAddon

addons = [SandcatAddon()]
