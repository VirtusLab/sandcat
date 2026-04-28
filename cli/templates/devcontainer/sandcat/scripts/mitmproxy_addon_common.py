"""
Shared mitmproxy addon library for sandcat.

Provides a base ``SandcatAddon`` class that agent-specific addons subclass.
The base implements all behavior that is identical across agents:

  - Settings layer loading and merging (user / project / local).
  - 1Password (``op://``) reference resolution.
  - Network policy evaluation (top-to-bottom, first match wins, default deny).
  - Secret substitution in URL, headers, optional Basic Auth, and body.
  - ``sandcat.env`` file generation that exports placeholders for the agent.

Agent variants override a small set of hook methods to customise behaviour:

  - ``_on_settings_merged(merged)``         — read agent-specific settings keys.
  - ``_normalize_secret_value(value)``      — sanitize a resolved secret value.
  - ``_is_streaming_request(flow) -> bool`` — keep the body opaque if True.
  - ``_prepare_streaming_request(flow)``    — per-request streaming setup.
  - ``_normalize_authorization_header(v)``  — sanitize the ``Authorization``
    header after substitution.
  - ``_basic_auth_contains_placeholder(auth_header, placeholder) -> bool``.
  - ``_replace_placeholder_in_basic_auth(auth_header, placeholder, value)``.
  - ``_is_textual_content_type(ct) -> bool`` — body substitution gate.

The defaults are tuned to match the simplest "Claude" behaviour (no streaming,
no Basic Auth handling, body substitution always permitted).
"""

import base64
import binascii
import hashlib
import json
import logging
import os
import re
import subprocess
import sys
from fnmatch import fnmatch

from mitmproxy import ctx, dns, http

_VALID_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# Settings layers, lowest to highest precedence.
SETTINGS_PATHS = [
    "/config/settings.json",                # user:    ~/.config/sandcat/settings.json
    "/config/project/settings.json",        # project: .sandcat/settings.json
    "/config/project/settings.local.json",  # local:   .sandcat/settings.local.json
]
SANDCAT_ENV_PATH = "/home/mitmproxy/.mitmproxy/sandcat.env"

logger = logging.getLogger(__name__)


class SandcatAddon:
    """Base sandcat addon: network policy + secret substitution."""

    def __init__(self):
        self.secrets: dict[str, dict] = {}  # name -> {value, hosts, placeholder}
        self.network_rules: list[dict] = []
        self.env: dict[str, str] = {}  # non-secret env vars (e.g. git identity)
        self.debug_enabled = False  # subclasses may flip this in _on_settings_merged

    # ------------------------------------------------------------------ load

    def load(self, loader):
        layers = []
        for path in SETTINGS_PATHS:
            if os.path.isfile(path):
                with open(path) as f:
                    layers.append(json.load(f))

        if not layers:
            logger.info("No settings files found — addon disabled")
            return

        merged = self._merge_settings(layers)
        self._on_settings_merged(merged)

        self._configure_op_token(merged.get("op_service_account_token"))
        self.env = merged["env"]
        self._load_secrets(merged["secrets"])
        self._load_network_rules(merged["network"])
        self._write_placeholders_env()

        ctx.log.info(
            f"Loaded {len(self.env)} env var(s) and {len(self.secrets)} secret(s), "
            f"wrote {SANDCAT_ENV_PATH}"
        )

    def _on_settings_merged(self, merged: dict):
        """Hook: subclasses may inspect merged settings (e.g., feature flags)."""
        pass

    @staticmethod
    def _configure_op_token(token: str | None):
        """Set OP_SERVICE_ACCOUNT_TOKEN from settings if not already in the environment."""
        if token and "OP_SERVICE_ACCOUNT_TOKEN" not in os.environ:
            os.environ["OP_SERVICE_ACCOUNT_TOKEN"] = token

    @staticmethod
    def _merge_settings(layers: list[dict]) -> dict:
        """Merge settings from multiple layers (lowest to highest precedence).

        - env: dict merge, higher precedence overwrites.
        - secrets: dict merge, higher precedence overwrites.
        - network: concatenated, highest precedence first (top-to-bottom matching).
        - op_service_account_token: highest precedence non-empty value wins.
        """
        env: dict[str, str] = {}
        secrets: dict[str, dict] = {}
        network: list[dict] = []
        op_token: str | None = None

        for layer in layers:
            env.update(layer.get("env", {}))
            secrets.update(layer.get("secrets", {}))
            layer_token = layer.get("op_service_account_token")
            if layer_token:
                op_token = layer_token

        # Network rules: highest-precedence layer's rules come first.
        for layer in reversed(layers):
            network.extend(layer.get("network", []))

        return {
            "env": env,
            "secrets": secrets,
            "network": network,
            "op_service_account_token": op_token,
        }

    # --------------------------------------------------------------- secrets

    def _load_secrets(self, raw_secrets: dict):
        for name, entry in raw_secrets.items():
            placeholder = f"SANDCAT_PLACEHOLDER_{name}"
            try:
                value = self._resolve_secret_value(name, entry)
            except (RuntimeError, ValueError) as e:
                ctx.log.warn(str(e))
                print(f"WARNING: {e}", file=sys.stderr)
                value = ""
            self.secrets[name] = {
                "value": self._normalize_secret_value(value),
                "hosts": entry.get("hosts", []),
                "placeholder": placeholder,
            }

    @classmethod
    def _resolve_secret_value(cls, name: str, entry: dict) -> str:
        """Resolve a secret from either a plain ``value`` or a 1Password ``op`` reference."""
        has_value = "value" in entry
        has_op = "op" in entry

        if has_value and has_op:
            raise ValueError(
                f"Secret {name!r}: specify either 'value' or 'op', not both"
            )
        if not has_value and not has_op:
            raise ValueError(
                f"Secret {name!r}: must specify either 'value' or 'op'"
            )

        if has_value:
            return cls._normalize_secret_value(entry["value"])

        op_ref = entry["op"]
        if not op_ref.startswith("op://"):
            raise ValueError(
                f"Secret {name!r}: 'op' value must start with 'op://', got {op_ref!r}"
            )

        try:
            result = subprocess.run(
                ["op", "read", op_ref],
                capture_output=True, text=True, timeout=30,
            )
        except FileNotFoundError:
            raise RuntimeError(
                f"Secret {name!r}: 'op' CLI not found. "
                "Install 1Password CLI to use op:// references."
            ) from None

        if result.returncode != 0:
            stderr = result.stderr.strip()
            raise RuntimeError(f"Secret {name!r}: 'op read' failed: {stderr}")

        return cls._normalize_secret_value(result.stdout.strip())

    @staticmethod
    def _normalize_secret_value(value) -> str:
        """Default: coerce to string. Subclasses may strip whitespace / BOM."""
        return "" if value is None else str(value)

    # --------------------------------------------------------------- network

    def _load_network_rules(self, raw_rules: list):
        self.network_rules = raw_rules
        ctx.log.info(f"Loaded {len(self.network_rules)} network rule(s)")

    def _find_matching_rule(self, method: str | None, host: str) -> dict | None:
        host = host.lower().rstrip(".")
        for rule in self.network_rules:
            if not fnmatch(host, rule["host"].lower()):
                continue
            rule_method = rule.get("method")
            if rule_method is not None and method is not None and rule_method.upper() != method.upper():
                continue
            return rule
        return None

    def _is_request_allowed(self, method: str | None, host: str) -> bool:
        rule = self._find_matching_rule(method, host)
        return rule is not None and rule.get("action") == "allow"

    # ----------------------------------------------------------- env writer

    @staticmethod
    def _shell_escape(value: str) -> str:
        """Escape a string for safe inclusion inside double quotes in shell."""
        return (
            value.replace("\\", "\\\\")
                 .replace('"', '\\"')
                 .replace("$", "\\$")
                 .replace("`", "\\`")
                 .replace("\n", "\\n")
        )

    @staticmethod
    def _validate_env_name(name: str):
        """Raise ValueError if name is not a valid shell variable name."""
        if not _VALID_ENV_NAME.match(name):
            raise ValueError(f"Invalid env var name: {name!r}")

    def _write_placeholders_env(self):
        lines = []
        # Non-secret env vars (e.g. git identity) — passed through as-is.
        for name, value in self.env.items():
            self._validate_env_name(name)
            lines.append(f'export {name}="{self._shell_escape(value)}"')
        for name, entry in self.secrets.items():
            self._validate_env_name(name)
            lines.append(f'export {name}="{self._shell_escape(entry["placeholder"])}"')
        with open(SANDCAT_ENV_PATH, "w") as f:
            f.write("\n".join(lines) + "\n")

    # ---------------------------------------------------- substitution hooks

    def _is_streaming_request(self, flow: http.HTTPFlow) -> bool:
        """Return True for requests whose body must remain opaque (no mutation)."""
        return False

    def _prepare_streaming_request(self, flow: http.HTTPFlow):
        """Per-request streaming setup. Default: nothing to do."""
        pass

    def _normalize_authorization_header(self, value: str) -> str:
        """Sanitize the ``Authorization`` header value after substitution."""
        return value

    @staticmethod
    def _basic_auth_contains_placeholder(auth_header: str | None, placeholder: str) -> bool:
        """Default: no Basic Auth substitution support."""
        return False

    @staticmethod
    def _replace_placeholder_in_basic_auth(
        auth_header: str | None, placeholder: str, value: str
    ) -> tuple[str | None, bool]:
        """Default: do not touch Basic Auth headers. Returns (header, replaced=False)."""
        return auth_header, False

    @staticmethod
    def _is_textual_content_type(content_type: str | None) -> bool:
        """Default: any content type is eligible for body substitution."""
        return True

    # ---------------------------------------------------- debug helpers (opt-in)

    def _debug(self, message: str):
        if self.debug_enabled:
            ctx.log.info(f"[sandcat-debug] {message}")

    @staticmethod
    def _is_truthy(value) -> bool:
        if value is None:
            return False
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in {"1", "true", "yes", "on"}

    @staticmethod
    def _auth_debug_summary(header: str | None) -> str:
        """Safe fingerprint for logs: no raw secrets; detects odd bytes (401 debugging)."""
        if not header:
            return "authorization=<missing>"

        h = header.strip()
        low = h.lower()
        if low.startswith("bearer "):
            tok = h[7:].strip()
            fp = hashlib.sha256(tok.encode("utf-8")).hexdigest()[:12]
            bad = [hex(ord(c)) for c in tok if ord(c) < 32 or ord(c) == 127]
            extra = f" ctrl_bytes={bad[:8]}" if bad else ""
            return f"bearer len={len(tok)} sha256_12={fp}{extra}"

        if low.startswith("basic "):
            raw = h[6:].strip()
            try:
                dec = base64.b64decode(raw).decode("utf-8")
            except (binascii.Error, UnicodeDecodeError, ValueError) as e:
                return f"basic decode_err={e!r}"
            fp = hashlib.sha256(dec.encode("utf-8")).hexdigest()[:12]
            bad = [hex(ord(c)) for c in dec if ord(c) < 32 and c not in "\t"]
            extra = f" ctrl_bytes={bad[:8]}" if bad else ""
            return f"basic decoded_len={len(dec)} sha256_12={fp}{extra}"

        return f"other len={len(h)}"

    # ------------------------------------------------------ secret substitution

    def _substitute_secrets(self, flow: http.HTTPFlow):
        host = flow.request.pretty_host.lower()
        is_streaming = self._is_streaming_request(flow)

        pre_auth = (
            self._auth_debug_summary(flow.request.headers.get("authorization"))
            if self.debug_enabled else ""
        )

        for name, entry in self.secrets.items():
            placeholder = entry["placeholder"]
            value = entry["value"]
            allowed_hosts = entry["hosts"]
            auth_header = flow.request.headers.get("authorization", "")

            present = (
                placeholder in flow.request.url
                or placeholder in str(flow.request.headers)
                or self._basic_auth_contains_placeholder(auth_header, placeholder)
                or (
                    not is_streaming
                    and flow.request.content
                    and placeholder.encode("utf-8") in flow.request.content
                )
            )

            if not present:
                continue

            # Leak detection: block if secret is going to a disallowed host.
            if not any(fnmatch(host, pattern.lower()) for pattern in allowed_hosts):
                flow.response = http.Response.make(
                    403,
                    f"Blocked: secret {name!r} not allowed for host {host!r}\n".encode(),
                    {"Content-Type": "text/plain"},
                )
                ctx.log.warn(f"Blocked secret {name!r} leak to disallowed host {host!r}")
                return

            if placeholder in flow.request.url:
                flow.request.url = flow.request.url.replace(placeholder, value)

            for k, v in list(flow.request.headers.items()):
                if placeholder in v:
                    new_v = v.replace(placeholder, value)
                    if k.lower() == "authorization":
                        new_v = self._normalize_authorization_header(new_v)
                    flow.request.headers[k] = new_v

            updated_auth, replaced_basic = self._replace_placeholder_in_basic_auth(
                flow.request.headers.get("authorization", ""), placeholder, value
            )
            if replaced_basic and updated_auth is not None:
                flow.request.headers["authorization"] = updated_auth

            if is_streaming:
                continue

            if flow.request.content and placeholder.encode("utf-8") in flow.request.content:
                content_type = flow.request.headers.get("content-type", "")
                if self._is_textual_content_type(content_type):
                    flow.request.content = flow.request.content.replace(
                        placeholder.encode("utf-8"), value.encode("utf-8")
                    )

        if self.debug_enabled:
            post_auth = self._auth_debug_summary(flow.request.headers.get("authorization"))
            self._debug(
                f"{flow.request.method} {flow.request.pretty_host}{flow.request.path} "
                f"streaming={is_streaming} auth_pre={pre_auth} auth_post={post_auth}"
            )

    # -------------------------------------------------------------- handlers

    def request(self, flow: http.HTTPFlow):
        method = flow.request.method
        host = flow.request.pretty_host

        if not self._is_request_allowed(method, host):
            flow.response = http.Response.make(
                403,
                f"Blocked by network policy: {method} {host}\n".encode(),
                {"Content-Type": "text/plain"},
            )
            ctx.log.warn(f"Network deny: {method} {host}")
            return

        if self._is_streaming_request(flow):
            self._prepare_streaming_request(flow)

        self._substitute_secrets(flow)

    def responseheaders(self, flow: http.HTTPFlow):
        if self._is_streaming_request(flow):
            flow.response.stream = True

    def dns_request(self, flow: dns.DNSFlow):
        question = flow.request.question
        if question is None:
            flow.response = flow.request.fail(dns.response_codes.REFUSED)
            return

        host = question.name
        if not self._is_request_allowed(None, host):
            flow.response = flow.request.fail(dns.response_codes.REFUSED)
            ctx.log.warn(f"DNS deny: {host}")
