"""
Codex-focused mitmproxy addon: network access rules and secret substitution.

Loaded via: mitmweb -s /scripts/mitmproxy_addon_codex.py

This is a thin wrapper around the shared :mod:`mitmproxy_addon_common`
library. Codex uses OpenAI's REST API (Chat Completions endpoint, plain
JSON with SSE streaming on the response) — the default buffered-body
behaviour of the base ``SandcatAddon`` class is sufficient, and buffering
enables the placeholder leak check that the common addon runs on request
payloads.

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
