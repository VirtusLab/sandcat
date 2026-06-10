"""
Cursor-focused mitmproxy addon: network policy + secret substitution.

This variant builds on the shared :mod:`mitmproxy_addon_common` library and
adds Cursor-specific behaviour:

  - Cursor Connect streaming traffic stays opaque (no body mutation).
    Streaming detection is *path-only* (``/agent.v1.AgentService/Run*``,
    ``/aiserver.v1.RepositoryService/...``) — we deliberately do not honour
    a client-supplied ``content-type: application/connect+proto`` header,
    because that would let any request with the right header bypass body
    placeholder substitution and content-based leak detection.
  - Body substitution applies only to textual content types (JSON, XML,
    form-encoded, ``+json`` / ``+xml`` suffixes). Cursor's binary protobuf
    payloads are not safe to mutate by-byte, and Cursor secret placeholders
    only ride in URL/header/Basic-Auth surfaces anyway.
  - Placeholder substitution still applies to URL, headers, and Basic Auth.
  - Resolved secret values are stripped (whitespace / BOM) — common 401 cause.
  - The ``Authorization`` header is normalised after substitution.
  - Optional debug logging via the ``SANDCAT_MITM_DEBUG`` env var or setting.
"""

import base64
import binascii
import os

from mitmproxy import http

from mitmproxy_addon_common import SandcatAddon as _SandcatAddonBase


class SandcatAddon(_SandcatAddonBase):
    """Cursor-specific overrides on top of the shared addon library."""

    # ---------------------------------------------------------- settings hook

    def _on_settings_merged(self, merged: dict):
        env = merged.setdefault("env", {})
        raw_debug = env.pop(
            "SANDCAT_MITM_DEBUG", os.environ.get("SANDCAT_MITM_DEBUG", "")
        )
        self.debug_enabled = self._is_truthy(raw_debug)
        if self.debug_enabled:
            self._debug(
                "enabled — per-request auth/substitution logging active"
            )

    # --------------------------------------------------- secret normalization

    @staticmethod
    def _normalize_secret_value(value) -> str:
        """Strip accidental whitespace/newlines from JSON or CLI output (common 401 cause)."""
        if value is None:
            return ""
        s = str(value).strip()
        # Strip UTF-8 BOM from pasted JSON / editor exports (invisible in most UIs).
        return s.lstrip("\ufeff")

    # --------------------------------------- authorization header normalization

    def _normalize_authorization_header(self, value: str) -> str:
        """Trim token after substitution; preserve the client's Bearer scheme spelling
        (RFC 7235 is case-insensitive, but some stacks are picky)."""
        v = value.strip()
        if len(v) >= 7 and v[:7].lower() == "bearer ":
            token = v[7:].strip()
            scheme = v[:6]  # preserve e.g. Bearer / bearer / BEARER
            return f"{scheme} {token}"
        return v

    # ---------------------------------------- streaming detection / preparation

    @staticmethod
    def _is_cursor_host(host: str) -> bool:
        host = host.lower().rstrip(".")
        return (
            host == "cursor.sh"
            or host == "cursor.com"
            or host.endswith(".cursor.sh")
            or host.endswith(".cursor.com")
        )

    def _is_streaming_request(self, flow: http.HTTPFlow) -> bool:
        # Streaming detection is path-only by design — see module docstring.
        host = flow.request.pretty_host.lower()
        if not self._is_cursor_host(host):
            return False

        path = flow.request.path
        return (
            path.startswith("/agent.v1.AgentService/Run")
            or path.startswith("/agent.v1.AgentService/RunSSE")
            or path.startswith("/aiserver.v1.RepositoryService/")
        )

    @staticmethod
    def _prepare_streaming_request(flow: http.HTTPFlow):
        flow.request.headers["accept-encoding"] = "identity"
        flow.request.stream = True

    # ---------------------------------------------- textual content-type gate

    @staticmethod
    def _is_textual_content_type(content_type: str | None) -> bool:
        if not content_type:
            return False
        media_type = content_type.split(";", 1)[0].strip().lower()
        return (
            media_type.startswith("text/")
            or media_type
            in {
                "application/json",
                "application/x-www-form-urlencoded",
                "application/xml",
                "application/javascript",
                "application/graphql",
            }
            or media_type.endswith("+json")
            or media_type.endswith("+xml")
        )

    # ----------------------------------------------------- basic auth helpers

    @staticmethod
    def _basic_auth_contains_placeholder(auth_header: str | None, placeholder: str) -> bool:
        if not auth_header or not auth_header.lower().startswith("basic "):
            return False
        encoded = auth_header.split(" ", 1)[1].strip()
        if not encoded:
            return False
        try:
            decoded = base64.b64decode(encoded).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            return False
        return placeholder in decoded

    @staticmethod
    def _replace_placeholder_in_basic_auth(
        auth_header: str | None, placeholder: str, value: str
    ) -> tuple[str | None, bool]:
        if not auth_header or not auth_header.lower().startswith("basic "):
            return auth_header, False
        encoded = auth_header.split(" ", 1)[1].strip()
        if not encoded:
            return auth_header, False
        try:
            decoded = base64.b64decode(encoded).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            return auth_header, False
        if placeholder not in decoded:
            return auth_header, False
        replaced = decoded.replace(placeholder, value)
        # Trim only outer CR/LF; avoids invisible line-ending damage from clients/editors.
        replaced = replaced.strip("\r\n")
        new_encoded = base64.b64encode(replaced.encode("utf-8")).decode("ascii")
        return f"Basic {new_encoded}", True


addons = [SandcatAddon()]
