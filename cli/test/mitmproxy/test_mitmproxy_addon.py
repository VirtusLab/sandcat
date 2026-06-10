"""Unit tests for the sandcat mitmproxy addons — no mitmproxy daemon needed.

This file covers:

  - The shared :mod:`mitmproxy_addon_common` library (network rules, settings
    merging, shell escaping, op:// resolution, env file generation).
  - Both agent variants — :mod:`mitmproxy_addon_claude` and
    :mod:`mitmproxy_addon_cursor` — by parameterising shared behaviour over
    the two ``SandcatAddon`` classes.
  - Cursor-specific behaviour: Cursor Connect streaming, ``Authorization``
    header normalisation, Basic Auth substitution, secret value normalisation.
"""

import importlib
import json
import os
import re
import sys
import types
from pathlib import Path
from urllib.parse import urlsplit
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# mitmproxy stubs — install BEFORE importing the addon modules.
# ---------------------------------------------------------------------------

_ctx = MagicMock()
_http = types.ModuleType("mitmproxy.http")
_dns = types.ModuleType("mitmproxy.dns")


class _DNSQuestion:
    def __init__(self, name):
        self.name = name


class _DNSMessage:
    def __init__(self, questions=None):
        self.questions = questions or []

    @property
    def question(self):
        if len(self.questions) == 1:
            return self.questions[0]
        return None

    def fail(self, response_code):
        return {"failed": True, "response_code": response_code}


class _ResponseCodes:
    REFUSED = 5


_dns.DNSFlow = type("DNSFlow", (), {})
_dns.response_codes = _ResponseCodes()


class _Headers(dict):
    """Minimal mitmproxy-like headers for testing."""

    def items(self):
        return list(super().items())


class _Request:
    def __init__(self, method="GET", host="example.com", url="https://example.com/",
                 headers=None, content=None):
        self.method = method
        self.pretty_host = host
        self.url = url
        split = urlsplit(url)
        self.path = split.path or "/"
        if split.query:
            self.path += f"?{split.query}"
        self.headers = _Headers(headers or {})
        self.content = content
        self.stream = False


class _Response:
    @staticmethod
    def make(status, body, headers):
        return {"status": status, "body": body, "headers": headers}


_http.HTTPFlow = type("HTTPFlow", (), {})
_http.Response = _Response

sys.modules["mitmproxy"] = types.ModuleType("mitmproxy")
sys.modules["mitmproxy.ctx"] = _ctx
sys.modules["mitmproxy.http"] = _http
sys.modules["mitmproxy.dns"] = _dns
sys.modules["mitmproxy"].ctx = _ctx
sys.modules["mitmproxy"].http = _http
sys.modules["mitmproxy"].dns = _dns

# Allow importing the addon modules from the templates directory.
_SCRIPTS_DIR = str(
    Path(__file__).resolve().parents[2] / "templates" / "devcontainer" / "sandcat" / "scripts"
)
sys.path.insert(0, _SCRIPTS_DIR)

# Import after stubs are in place.
common = importlib.import_module("mitmproxy_addon_common")
claude_mod = importlib.import_module("mitmproxy_addon_claude")
cursor_mod = importlib.import_module("mitmproxy_addon_cursor")

ClaudeAddon = claude_mod.SandcatAddon
CursorAddon = cursor_mod.SandcatAddon
BaseAddon = common.SandcatAddon

# Patch targets all live in the shared library — both agent variants inherit
# their settings/secret/network code from the base class defined there.
_COMMON = "mitmproxy_addon_common"

# Parameter set for tests that should pass for both agent variants.
ADDONS = [
    pytest.param(ClaudeAddon, id="claude"),
    pytest.param(CursorAddon, id="cursor"),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_flow(method="GET", host="example.com", url=None, headers=None, content=None):
    flow = MagicMock()
    flow.request = _Request(
        method=method,
        host=host,
        url=url or f"https://{host}/",
        headers=headers,
        content=content,
    )
    flow.response = None
    return flow


def _make_dns_flow(name="example.com"):
    flow = MagicMock()
    if name is None:
        flow.request = _DNSMessage(questions=[])
    else:
        flow.request = _DNSMessage(questions=[_DNSQuestion(name)])
    flow.response = None
    return flow


# ---------------------------------------------------------------------------
# Network rules — shared logic, parameterised over both variants.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestNetworkRules:
    def test_first_match_wins_allow_before_deny(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*"},
            {"action": "deny", "host": "*"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True

    def test_first_match_wins_deny_before_allow(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "deny", "host": "*"},
            {"action": "allow", "host": "*"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is False

    def test_default_deny_on_no_match(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = []
        assert addon._is_request_allowed("GET", "example.com") is False

    def test_method_specific_rule(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*", "method": "GET"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True
        assert addon._is_request_allowed("POST", "example.com") is False

    def test_method_omitted_matches_any(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True
        assert addon._is_request_allowed("POST", "example.com") is True
        assert addon._is_request_allowed("PUT", "example.com") is True

    def test_host_glob_pattern(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*.github.com"},
        ]
        assert addon._is_request_allowed("GET", "api.github.com") is True
        assert addon._is_request_allowed("GET", "example.com") is False

    def test_full_ruleset_from_plan(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*", "method": "GET"},
            {"action": "allow", "host": "*.github.com", "method": "POST"},
            {"action": "deny", "host": "*", "method": "POST"},
            {"action": "allow", "host": "*"},
        ]
        # GET anything → allowed (rule 1)
        assert addon._is_request_allowed("GET", "example.com") is True
        # POST github → allowed (rule 2)
        assert addon._is_request_allowed("POST", "api.github.com") is True
        # POST other → denied (rule 3)
        assert addon._is_request_allowed("POST", "example.com") is False
        # PUT anything → allowed (rule 4)
        assert addon._is_request_allowed("PUT", "example.com") is True

    def test_method_matching_is_case_insensitive(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*", "method": "get"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True

    def test_none_method_bypasses_method_check(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*", "method": "GET"},
        ]
        assert addon._is_request_allowed(None, "example.com") is True

    def test_host_matching_is_case_insensitive(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "deny", "host": "evil.com"},
            {"action": "allow", "host": "*"},
        ]
        assert addon._is_request_allowed("GET", "Evil.COM") is False
        assert addon._is_request_allowed("GET", "EVIL.COM") is False

    def test_rule_host_pattern_case_insensitive(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*.GitHub.COM"},
        ]
        assert addon._is_request_allowed("GET", "api.github.com") is True

    def test_dns_trailing_dot_stripped(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [
            {"action": "allow", "host": "*.github.com"},
        ]
        assert addon._is_request_allowed(None, "api.github.com.") is True
        assert addon._is_request_allowed("GET", "api.github.com.") is True


# ---------------------------------------------------------------------------
# Secret substitution — shared logic, parameterised over both variants.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestSecretSubstitution:
    @staticmethod
    def _make_addon(addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "API_KEY": {
                "value": "real-secret-value",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_API_KEY",
            }
        }
        return addon

    def test_placeholder_replaced_in_header(self, addon_cls):
        addon = self._make_addon(addon_cls)
        flow = _make_flow(
            host="api.example.com",
            headers={"Authorization": "Bearer SANDCAT_PLACEHOLDER_API_KEY"},
        )
        addon.request(flow)
        assert flow.response is None
        assert flow.request.headers["Authorization"] == "Bearer real-secret-value"

    def test_placeholder_replaced_in_body(self, addon_cls):
        addon = self._make_addon(addon_cls)
        # Cursor gates body substitution on a textual content-type; provide one
        # so the assertion holds for both variants.
        flow = _make_flow(
            method="POST",
            host="api.example.com",
            headers={"content-type": "application/json"},
            content=b'{"key": "SANDCAT_PLACEHOLDER_API_KEY"}',
        )
        addon.request(flow)
        assert flow.response is None
        assert b"real-secret-value" in flow.request.content

    def test_placeholder_replaced_in_url(self, addon_cls):
        addon = self._make_addon(addon_cls)
        flow = _make_flow(
            host="api.example.com",
            url="https://api.example.com/?token=SANDCAT_PLACEHOLDER_API_KEY",
        )
        addon.request(flow)
        assert flow.response is None
        assert "real-secret-value" in flow.request.url

    def test_no_op_when_placeholder_absent(self, addon_cls):
        addon = self._make_addon(addon_cls)
        flow = _make_flow(host="api.example.com")
        addon.request(flow)
        assert flow.response is None
        assert "real-secret-value" not in flow.request.url

    def test_leak_detection_blocks_disallowed_host(self, addon_cls):
        addon = self._make_addon(addon_cls)
        flow = _make_flow(
            host="evil.com",
            headers={"Authorization": "Bearer SANDCAT_PLACEHOLDER_API_KEY"},
        )
        addon.request(flow)
        assert flow.response is not None
        assert flow.response["status"] == 403


# ---------------------------------------------------------------------------
# Body substitution behaviour that differs between variants:
#   - Claude: body substitution is unconditional (no content-type check).
#   - Cursor: body substitution requires a textual content-type.
# ---------------------------------------------------------------------------

class TestBodySubstitutionContentTypeGate:
    @staticmethod
    def _make_addon(addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "API_KEY": {
                "value": "real-secret",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_API_KEY",
            }
        }
        return addon

    def test_claude_substitutes_body_without_content_type(self):
        addon = self._make_addon(ClaudeAddon)
        flow = _make_flow(
            method="POST",
            host="api.example.com",
            content=b"SANDCAT_PLACEHOLDER_API_KEY",
        )
        addon.request(flow)
        assert flow.request.content == b"real-secret"

    def test_cursor_skips_body_without_textual_content_type(self):
        addon = self._make_addon(CursorAddon)
        flow = _make_flow(
            method="POST",
            host="api.example.com",
            content=b"SANDCAT_PLACEHOLDER_API_KEY",
        )
        addon.request(flow)
        assert flow.request.content == b"SANDCAT_PLACEHOLDER_API_KEY"

    def test_cursor_substitutes_body_for_json(self):
        addon = self._make_addon(CursorAddon)
        flow = _make_flow(
            method="POST",
            host="api.example.com",
            headers={"content-type": "application/json"},
            content=b"SANDCAT_PLACEHOLDER_API_KEY",
        )
        addon.request(flow)
        assert flow.request.content == b"real-secret"


# ---------------------------------------------------------------------------
# Cursor-specific: streaming traffic stays opaque.
# ---------------------------------------------------------------------------

class TestCursorStreaming:
    @staticmethod
    def _make_addon():
        addon = CursorAddon()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "CURSOR_API_KEY": {
                "value": "cursor-secret",
                "hosts": ["*.cursor.sh", "*.cursor.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_CURSOR_API_KEY",
            }
        }
        return addon

    def test_streaming_sets_stream_and_identity_encoding(self):
        addon = self._make_addon()
        flow = _make_flow(
            method="POST",
            host="api2.cursor.sh",
            url="https://api2.cursor.sh/agent.v1.AgentService/RunSSE",
            headers={"content-type": "application/connect+proto"},
            content=b"\x00\x00\x00\x00&",
        )
        addon.request(flow)
        assert flow.response is None
        assert flow.request.stream is True
        assert flow.request.headers["accept-encoding"] == "identity"
        # The Cursor template never injects CURSOR-API-KEY; placeholders go in Authorization.
        assert "CURSOR-API-KEY" not in flow.request.headers
        assert flow.request.content == b"\x00\x00\x00\x00&"

    def test_streaming_does_not_touch_body_placeholders(self):
        addon = self._make_addon()
        flow = _make_flow(
            method="POST",
            host="api2.cursor.sh",
            url="https://api2.cursor.sh/agent.v1.AgentService/RunSSE",
            headers={"content-type": "application/connect+proto"},
            content=b"SANDCAT_PLACEHOLDER_CURSOR_API_KEY",
        )
        addon.request(flow)
        assert flow.response is None
        assert flow.request.content == b"SANDCAT_PLACEHOLDER_CURSOR_API_KEY"

    def test_streaming_substitutes_bearer_placeholder(self):
        addon = self._make_addon()
        flow = _make_flow(
            method="POST",
            host="api2.cursor.sh",
            url="https://api2.cursor.sh/agent.v1.AgentService/RunSSE",
            headers={
                "content-type": "application/connect+proto",
                "authorization": "Bearer SANDCAT_PLACEHOLDER_CURSOR_API_KEY",
            },
        )
        addon.request(flow)
        assert flow.response is None
        assert flow.request.headers["authorization"] == "Bearer cursor-secret"

    def test_streaming_response_is_marked_streaming(self):
        addon = self._make_addon()
        flow = _make_flow(
            method="POST",
            host="api2.cursor.sh",
            url="https://api2.cursor.sh/agent.v1.AgentService/RunSSE",
            headers={"content-type": "application/connect+proto"},
        )
        flow.response = types.SimpleNamespace(stream=False)
        addon.responseheaders(flow)
        assert flow.response.stream is True

    def test_repository_service_path_is_streaming(self):
        addon = self._make_addon()
        flow = _make_flow(
            method="POST",
            host="api3.cursor.sh",
            url="https://api3.cursor.sh/aiserver.v1.RepositoryService/Foo",
        )
        assert addon._is_streaming_request(flow) is True

    def test_non_cursor_host_not_streaming(self):
        # Even if the path looks Cursor-like, a non-Cursor host should never
        # be classified as streaming.
        addon = self._make_addon()
        flow = _make_flow(
            method="POST",
            host="api.openai.com",
            url="https://api.openai.com/agent.v1.AgentService/Run",
        )
        assert addon._is_streaming_request(flow) is False

    def test_cursor_host_without_streaming_indicator_not_streaming(self):
        addon = self._make_addon()
        flow = _make_flow(
            method="GET",
            host="cursor.com",
            url="https://cursor.com/about",
        )
        assert addon._is_streaming_request(flow) is False

    def test_content_type_alone_does_not_trigger_streaming(self):
        # Regression: a client-supplied application/connect+proto content-type
        # must NOT flip on streaming when the path is unrelated. Otherwise
        # any request with the right header could bypass body substitution
        # and the content-based placeholder leak check.
        addon = self._make_addon()
        flow = _make_flow(
            method="POST",
            host="api.cursor.sh",
            url="https://api.cursor.sh/some/other/endpoint",
            headers={"content-type": "application/connect+proto"},
        )
        assert addon._is_streaming_request(flow) is False

    def test_claude_responseheaders_is_noop(self):
        """Base behaviour: never touches the response stream flag."""
        addon = ClaudeAddon()
        flow = _make_flow(host="example.com")
        flow.response = types.SimpleNamespace(stream=False)
        addon.responseheaders(flow)
        assert flow.response.stream is False

    def test_cursor_responseheaders_noop_for_non_streaming(self):
        """Non-streaming Cursor requests must not be marked stream=True.

        Otherwise mitmproxy would skip body buffering on regular JSON
        endpoints, defeating the body-content placeholder leak check.
        """
        addon = self._make_addon()
        flow = _make_flow(
            method="GET",
            host="cursor.com",
            url="https://cursor.com/about",
        )
        flow.response = types.SimpleNamespace(stream=False)
        addon.responseheaders(flow)
        assert flow.response.stream is False

    def test_streaming_to_disallowed_host_blocks_authorization_leak(self):
        """Even on a streaming path, leak detection in `_substitute_secrets`
        must run on URL/header/Basic-Auth surfaces.

        The network allowlist may permit a host via wildcard, but the
        secret's per-key allowlist (`hosts`) is narrower. A streaming POST
        whose Authorization header carries the placeholder, addressed to a
        host that is *not* in the secret's hosts, must yield a 403.
        """
        addon = CursorAddon()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        # Secret only allowed for api-allowed.cursor.sh, but the request
        # below goes to api2.cursor.sh.
        addon.secrets = {
            "CURSOR_API_KEY": {
                "value": "cursor-secret",
                "hosts": ["api-allowed.cursor.sh"],
                "placeholder": "SANDCAT_PLACEHOLDER_CURSOR_API_KEY",
            }
        }

        flow = _make_flow(
            method="POST",
            host="api2.cursor.sh",
            url="https://api2.cursor.sh/agent.v1.AgentService/RunSSE",
            headers={
                "content-type": "application/connect+proto",
                "authorization": "Bearer SANDCAT_PLACEHOLDER_CURSOR_API_KEY",
            },
            content=b"\x00\x00\x00\x00&",
        )
        # Sanity check: this IS a streaming path so the body-side substitution
        # would skip — the leak detection has to fire from the auth header.
        assert addon._is_streaming_request(flow) is True

        addon.request(flow)

        assert flow.response is not None
        # Stub ``http.Response.make`` returns ``{"status", "body", "headers"}``.
        assert flow.response["status"] == 403
        assert b"CURSOR_API_KEY" in flow.response["body"]
        # The original placeholder must NOT have been substituted.
        assert flow.request.headers["authorization"] == (
            "Bearer SANDCAT_PLACEHOLDER_CURSOR_API_KEY"
        )


# ---------------------------------------------------------------------------
# Cursor-specific: Basic Auth substitution.
# ---------------------------------------------------------------------------

class TestCursorBasicAuth:
    @staticmethod
    def _make_addon():
        addon = CursorAddon()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "API_KEY": {
                "value": "real-pass",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_API_KEY",
            }
        }
        return addon

    def test_basic_auth_placeholder_substituted(self):
        import base64

        encoded = base64.b64encode(b"user:SANDCAT_PLACEHOLDER_API_KEY").decode("ascii")
        addon = self._make_addon()
        flow = _make_flow(
            host="api.example.com",
            headers={"authorization": f"Basic {encoded}"},
        )
        addon.request(flow)
        assert flow.response is None
        assert flow.request.headers["authorization"].startswith("Basic ")
        new_encoded = flow.request.headers["authorization"].split(" ", 1)[1]
        assert base64.b64decode(new_encoded) == b"user:real-pass"

    def test_basic_auth_no_placeholder_untouched(self):
        import base64

        encoded = base64.b64encode(b"user:plain-pass").decode("ascii")
        addon = self._make_addon()
        flow = _make_flow(
            host="api.example.com",
            headers={"authorization": f"Basic {encoded}"},
        )
        addon.request(flow)
        assert flow.request.headers["authorization"] == f"Basic {encoded}"

    def test_basic_auth_invalid_base64_returns_unchanged(self):
        # Direct unit test of the helper: invalid base64 should not raise.
        # "AAA" is missing padding and triggers binascii.Error.
        _, replaced = CursorAddon._replace_placeholder_in_basic_auth(
            "Basic AAA", "X", "Y"
        )
        assert replaced is False

    def test_basic_auth_empty_payload_returns_unchanged(self):
        # "Basic " with empty token short-circuits before decoding.
        _, replaced = CursorAddon._replace_placeholder_in_basic_auth(
            "Basic ", "X", "Y"
        )
        assert replaced is False

    def test_basic_auth_non_basic_scheme_unchanged(self):
        result, replaced = CursorAddon._replace_placeholder_in_basic_auth(
            "Bearer abc", "P", "v"
        )
        assert replaced is False
        assert result == "Bearer abc"

    def test_claude_does_not_touch_basic_auth(self):
        """Base addon never inspects Basic Auth payloads."""
        import base64

        encoded = base64.b64encode(b"user:SANDCAT_PLACEHOLDER_API_KEY").decode("ascii")
        addon = ClaudeAddon()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "API_KEY": {
                "value": "real-pass",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_API_KEY",
            }
        }
        flow = _make_flow(
            host="api.example.com",
            headers={"authorization": f"Basic {encoded}"},
        )
        addon.request(flow)
        # Claude leaves the encoded payload untouched (placeholder hidden inside base64).
        assert flow.request.headers["authorization"] == f"Basic {encoded}"


# ---------------------------------------------------------------------------
# Cursor-specific: Authorization header normalisation after substitution.
# ---------------------------------------------------------------------------

class TestCursorAuthorizationNormalization:
    def test_bearer_token_trimmed(self):
        addon = CursorAddon()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "T": {
                "value": "  real-token  ",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_T",
            }
        }
        flow = _make_flow(
            host="api.example.com",
            headers={"authorization": "Bearer SANDCAT_PLACEHOLDER_T"},
        )
        addon.request(flow)
        assert flow.request.headers["authorization"] == "Bearer real-token"

    def test_bearer_scheme_case_preserved(self):
        addon = CursorAddon()
        # Direct hook test
        assert (
            addon._normalize_authorization_header("bearer  abc  ") == "bearer abc"
        )
        assert (
            addon._normalize_authorization_header("BEARER abc") == "BEARER abc"
        )

    def test_non_bearer_passthrough_only_strips(self):
        addon = CursorAddon()
        assert addon._normalize_authorization_header("Basic abc==  ") == "Basic abc=="

    def test_claude_does_not_trim_authorization(self):
        addon = ClaudeAddon()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "T": {
                "value": " spacey ",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_T",
            }
        }
        flow = _make_flow(
            host="api.example.com",
            headers={"authorization": "Bearer SANDCAT_PLACEHOLDER_T"},
        )
        addon.request(flow)
        # Claude does no normalization — the leading/trailing spaces survive.
        assert flow.request.headers["authorization"] == "Bearer  spacey "


# ---------------------------------------------------------------------------
# Cursor-specific: secret value normalization.
# ---------------------------------------------------------------------------

class TestCursorSecretNormalization:
    def test_strips_whitespace(self):
        assert CursorAddon._normalize_secret_value("  abc  ") == "abc"

    def test_strips_bom(self):
        assert CursorAddon._normalize_secret_value("\ufeffabc") == "abc"

    def test_handles_none(self):
        assert CursorAddon._normalize_secret_value(None) == ""

    def test_handles_non_string(self):
        assert CursorAddon._normalize_secret_value(123) == "123"

    def test_claude_default_is_passthrough(self):
        # Base/claude does not strip — values come through unchanged.
        assert ClaudeAddon._normalize_secret_value("  abc  ") == "  abc  "
        assert ClaudeAddon._normalize_secret_value(None) == ""


# ---------------------------------------------------------------------------
# Integration — request handler ordering.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestIntegration:
    def test_network_deny_blocks_before_substitution(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "deny", "host": "*"}]
        addon.secrets = {
            "API_KEY": {
                "value": "real-secret-value",
                "hosts": ["example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_API_KEY",
            }
        }
        flow = _make_flow(
            host="example.com",
            headers={"Authorization": "Bearer SANDCAT_PLACEHOLDER_API_KEY"},
        )
        addon.request(flow)
        assert flow.response is not None
        assert flow.response["status"] == 403
        assert b"network policy" in flow.response["body"]
        # Secret should NOT have been substituted
        assert flow.request.headers["Authorization"] == "Bearer SANDCAT_PLACEHOLDER_API_KEY"

    def test_network_allow_plus_substitution(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "API_KEY": {
                "value": "real-secret-value",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_API_KEY",
            }
        }
        flow = _make_flow(
            host="api.example.com",
            headers={"Authorization": "Bearer SANDCAT_PLACEHOLDER_API_KEY"},
        )
        addon.request(flow)
        assert flow.response is None
        assert flow.request.headers["Authorization"] == "Bearer real-secret-value"


# ---------------------------------------------------------------------------
# DNS proxy — shared logic, parameterised over both variants.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestDNSProxy:
    def test_allowed_host_passes_through(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        flow = _make_dns_flow("example.com")
        addon.dns_request(flow)
        assert flow.response is None

    def test_denied_host_returns_refused(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "deny", "host": "*"}]
        flow = _make_dns_flow("example.com")
        addon.dns_request(flow)
        assert flow.response is not None
        assert flow.response["response_code"] == 5

    def test_empty_questions_returns_refused(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        flow = _make_dns_flow(name=None)
        addon.dns_request(flow)
        assert flow.response is not None
        assert flow.response["response_code"] == 5

    def test_dns_trailing_dot_allowed(self, addon_cls):
        addon = addon_cls()
        addon.network_rules = [{"action": "allow", "host": "*.github.com"}]
        flow = _make_dns_flow("api.github.com.")
        addon.dns_request(flow)
        assert flow.response is None


# ---------------------------------------------------------------------------
# Config loading — exercises the shared load() + write paths.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestConfigLoading:
    def test_missing_settings_file_disables_addon(self, addon_cls, tmp_path):
        addon = addon_cls()
        with patch(f"{_COMMON}.os.path.isfile", return_value=False), \
             patch(f"{_COMMON}.SANDCAT_DNS_CONF_PATH", str(tmp_path / "dns.conf")):
            addon.load(MagicMock())
        assert addon.env == {}
        assert addon.secrets == {}
        assert addon.network_rules == []

    def test_missing_secrets_key_uses_empty(self, addon_cls, tmp_path):
        settings = {"network": [{"action": "allow", "host": "*"}]}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(tmp_path / "sandcat.env")), \
             patch(f"{_COMMON}.SANDCAT_DNS_CONF_PATH", str(tmp_path / "dns.conf")):
            addon.load(MagicMock())
        assert addon.secrets == {}
        assert len(addon.network_rules) == 1

    def test_missing_network_key_uses_empty(self, addon_cls, tmp_path):
        settings = {"secrets": {"KEY": {"value": "v", "hosts": ["h.com"]}}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(tmp_path / "sandcat.env")), \
             patch(f"{_COMMON}.SANDCAT_DNS_CONF_PATH", str(tmp_path / "dns.conf")):
            addon.load(MagicMock())
        assert len(addon.secrets) == 1
        assert addon.network_rules == []

    def test_placeholders_env_written_correctly(self, addon_cls, tmp_path):
        settings = {"secrets": {
            "A": {"value": "va", "hosts": []},
            "B": {"value": "vb", "hosts": []},
        }}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export A="SANDCAT_PLACEHOLDER_A"' in content
        assert 'export B="SANDCAT_PLACEHOLDER_B"' in content

    def test_env_vars_written_to_placeholders_env(self, addon_cls, tmp_path):
        settings = {
            "env": {"GIT_USER_NAME": "Alice", "GIT_USER_EMAIL": "alice@example.com"},
            "secrets": {"K": {"value": "v", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export GIT_USER_NAME="Alice"' in content
        assert 'export GIT_USER_EMAIL="alice@example.com"' in content
        assert 'export K="SANDCAT_PLACEHOLDER_K"' in content

    def test_env_vars_partial(self, addon_cls, tmp_path):
        settings = {"env": {"EDITOR": "vim"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export EDITOR="vim"' in content

    def test_missing_env_section_omits_vars(self, addon_cls, tmp_path):
        settings = {"secrets": {"K": {"value": "v", "hosts": []}}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert content.startswith('export K=')


# ---------------------------------------------------------------------------
# Shell escaping — applies regardless of variant.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestShellEscaping:
    def test_double_quotes_escaped(self, addon_cls, tmp_path):
        settings = {"env": {"X": 'val"ue'}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export X="val\\"ue"' in content

    def test_backslashes_escaped(self, addon_cls, tmp_path):
        settings = {"env": {"X": "a\\b"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export X="a\\\\b"' in content

    def test_dollar_and_backtick_escaped(self, addon_cls, tmp_path):
        settings = {"env": {"X": "$(rm -rf /)`cmd`"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export X="\\$(rm -rf /)\\`cmd\\`"' in content


class TestShellEscapingStaticHelpers:
    """Static helpers live in the shared library; both variants reuse them."""

    def test_newlines_escaped(self):
        assert BaseAddon._shell_escape("line1\nline2") == "line1\\nline2"

    def test_plain_values_unchanged(self):
        assert BaseAddon._shell_escape("hello world") == "hello world"
        assert BaseAddon._shell_escape("sk-ant-abc123") == "sk-ant-abc123"

    def test_helpers_inherited_by_variants(self):
        # Sanity: subclasses inherit the same helper from the base.
        assert ClaudeAddon._shell_escape == BaseAddon._shell_escape
        assert CursorAddon._shell_escape == BaseAddon._shell_escape


# ---------------------------------------------------------------------------
# Env var name validation (shared).
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestEnvVarNameValidation:
    def test_valid_names(self, addon_cls):
        for name in ["FOO", "BAR_BAZ", "_PRIVATE", "a1b2"]:
            addon_cls._validate_env_name(name)  # should not raise

    def test_invalid_names(self, addon_cls):
        for name in ["1BAD", "FOO BAR", 'X"; curl evil.com #', "a-b", ""]:
            with pytest.raises(ValueError):
                addon_cls._validate_env_name(name)

    def test_invalid_env_name_blocks_write(self, addon_cls, tmp_path):
        settings = {"env": {'BAD NAME': "value"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            with pytest.raises(ValueError):
                addon.load(MagicMock())

    def test_invalid_secret_name_blocks_write(self, addon_cls, tmp_path):
        settings = {"secrets": {"BAD;NAME": {"value": "v", "hosts": []}}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            with pytest.raises(ValueError):
                addon.load(MagicMock())


# ---------------------------------------------------------------------------
# 1Password secret resolution (shared classmethod).
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestOpSecretResolution:
    def test_op_reference_resolved_via_subprocess(self, addon_cls):
        entry = {"op": "op://vault/item/field", "hosts": ["api.example.com"]}
        with patch(f"{_COMMON}.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="secret-value\n", stderr="")
            value = addon_cls._resolve_secret_value("KEY", entry)
        assert value == "secret-value"
        mock_run.assert_called_once_with(
            ["op", "read", "op://vault/item/field"],
            capture_output=True, text=True, timeout=30,
        )

    def test_value_field_still_works(self, addon_cls):
        entry = {"value": "plain-secret", "hosts": []}
        value = addon_cls._resolve_secret_value("KEY", entry)
        assert value == "plain-secret"

    def test_both_value_and_op_raises(self, addon_cls):
        entry = {"value": "x", "op": "op://vault/item/field", "hosts": []}
        with pytest.raises(ValueError, match="exactly one of 'value', 'op', or 'pass'"):
            addon_cls._resolve_secret_value("KEY", entry)

    def test_both_op_and_pass_raises(self, addon_cls):
        entry = {"op": "op://vault/item/field", "pass": "pass://vault/item/field", "hosts": []}
        with pytest.raises(ValueError, match="exactly one of 'value', 'op', or 'pass'"):
            addon_cls._resolve_secret_value("KEY", entry)

    def test_neither_value_nor_op_raises(self, addon_cls):
        entry = {"hosts": ["example.com"]}
        with pytest.raises(ValueError, match="exactly one of 'value', 'op', or 'pass'"):
            addon_cls._resolve_secret_value("KEY", entry)

    def test_pass_reference_resolved_via_subprocess(self, addon_cls):
        entry = {"pass": "pass://vault/item/field", "hosts": ["api.example.com"]}
        with patch(f"{_COMMON}.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="secret-value\n", stderr="")
            value = addon_cls._resolve_secret_value("KEY", entry)
        assert value == "secret-value"
        mock_run.assert_called_once_with(
            ["pass-cli", "item", "view", "pass://vault/item/field"],
            capture_output=True, text=True, timeout=30,
        )

    def test_pass_without_prefix_raises(self, addon_cls):
        entry = {"pass": "vault/item/field", "hosts": []}
        with pytest.raises(ValueError, match="must start with 'pass://'"):
            addon_cls._resolve_secret_value("KEY", entry)

    def test_pass_cli_not_found_raises(self, addon_cls):
        entry = {"pass": "pass://vault/item/field", "hosts": []}
        with patch(f"{_COMMON}.subprocess.run", side_effect=FileNotFoundError):
            with pytest.raises(RuntimeError, match="'pass-cli' not found"):
                addon_cls._resolve_secret_value("KEY", entry)

    def test_pass_cli_failure_raises(self, addon_cls):
        entry = {"pass": "pass://vault/item/field", "hosts": []}
        with patch(f"{_COMMON}.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1, stdout="", stderr="unauthorized"
            )
            with pytest.raises(RuntimeError, match="'pass-cli' read failed"):
                addon_cls._resolve_secret_value("KEY", entry)

    def test_op_without_prefix_raises(self, addon_cls):
        entry = {"op": "vault/item/field", "hosts": []}
        with pytest.raises(ValueError, match="must start with 'op://'"):
            addon_cls._resolve_secret_value("KEY", entry)

    def test_op_cli_not_found_raises(self, addon_cls):
        entry = {"op": "op://vault/item/field", "hosts": []}
        with patch(f"{_COMMON}.subprocess.run", side_effect=FileNotFoundError):
            with pytest.raises(RuntimeError, match="'op' CLI not found"):
                addon_cls._resolve_secret_value("KEY", entry)

    def test_op_cli_failure_raises(self, addon_cls):
        entry = {"op": "op://vault/item/field", "hosts": []}
        with patch(f"{_COMMON}.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1, stdout="", stderr="authorization required"
            )
            with pytest.raises(RuntimeError, match="authorization required"):
                addon_cls._resolve_secret_value("KEY", entry)

    def test_op_reference_in_full_load(self, addon_cls, tmp_path):
        settings = {"secrets": {
            "API_KEY": {"op": "op://vault/item/field", "hosts": ["api.example.com"]},
        }}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="resolved-secret\n", stderr="")
            addon.load(MagicMock())
        assert addon.secrets["API_KEY"]["value"] == "resolved-secret"
        content = env_path.read_text()
        assert 'export API_KEY="SANDCAT_PLACEHOLDER_API_KEY"' in content

    def test_op_failure_logs_warning_and_continues(self, addon_cls, tmp_path):
        settings = {"secrets": {
            "BAD": {"op": "op://vault/item/field", "hosts": []},
            "GOOD": {"value": "ok", "hosts": []},
        }}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stdout="", stderr="vault not found")
            addon.load(MagicMock())
        assert addon.secrets["BAD"]["value"] == ""
        assert addon.secrets["GOOD"]["value"] == "ok"

    def test_op_token_from_settings(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.delenv("OP_SERVICE_ACCOUNT_TOKEN", raising=False)
        settings = {
            "op_service_account_token": "ops_test_token",
            "secrets": {"KEY": {"op": "op://vault/item/field", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="secret\n", stderr="")
            addon.load(MagicMock())
        assert os.environ.get("OP_SERVICE_ACCOUNT_TOKEN") == "ops_test_token"
        monkeypatch.delenv("OP_SERVICE_ACCOUNT_TOKEN", raising=False)

    def test_op_token_env_var_takes_precedence(self, addon_cls, monkeypatch):
        monkeypatch.setenv("OP_SERVICE_ACCOUNT_TOKEN", "from_env")
        addon_cls._configure_op_token("from_settings")
        assert os.environ["OP_SERVICE_ACCOUNT_TOKEN"] == "from_env"

    def test_op_token_not_set_when_empty(self, addon_cls, monkeypatch):
        monkeypatch.delenv("OP_SERVICE_ACCOUNT_TOKEN", raising=False)
        addon_cls._configure_op_token("")
        assert "OP_SERVICE_ACCOUNT_TOKEN" not in os.environ

    def test_op_token_not_set_when_none(self, addon_cls, monkeypatch):
        monkeypatch.delenv("OP_SERVICE_ACCOUNT_TOKEN", raising=False)
        addon_cls._configure_op_token(None)
        assert "OP_SERVICE_ACCOUNT_TOKEN" not in os.environ

    def test_proton_pass_token_from_settings(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.delenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", raising=False)
        settings = {
            "proton_pass_token": "pst_test_token",
            "secrets": {"KEY": {"pass": "pass://vault/item/field", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                return MagicMock(returncode=0, stdout="", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "info":
                return MagicMock(returncode=0, stdout="Personal Access Token: pst_test_token\n", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "item" and cmd[2] == "view":
                return MagicMock(returncode=0, stdout="secret\n", stderr="")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            addon.load(MagicMock())
        assert os.environ.get("PROTON_PASS_PERSONAL_ACCESS_TOKEN") == "pst_test_token"
        monkeypatch.delenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", raising=False)

    def test_proton_pass_token_env_var_takes_precedence(self, addon_cls, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "from_env")
        addon_cls._configure_proton_pass_token("from_settings")
        assert os.environ["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] == "from_env"

    def test_pass_login_called_once_on_load_with_pass_secrets(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "pst_test")
        settings = {
            "secrets": {
                "A": {"pass": "pass://vault/item/a", "hosts": ["a.com"]},
                "B": {"pass": "pass://vault/item/b", "hosts": ["b.com"]},
            }
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        login_calls = []

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                login_calls.append(True)
                return MagicMock(returncode=0, stdout="", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "info":
                return MagicMock(returncode=0, stdout="Personal Access Token: test\n", stderr="")
            return MagicMock(returncode=0, stdout="secret\n", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            addon.load(MagicMock())

        assert len(login_calls) == 1, "pass-cli login must be called exactly once"

    def test_pass_login_skipped_when_no_pass_secrets(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "pst_test")
        settings = {
            "secrets": {"KEY": {"value": "plain", "hosts": ["a.com"]}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        login_calls = []

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                login_calls.append(True)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            addon.load(MagicMock())

        assert login_calls == [], "pass-cli login must not be called when there are no pass:// secrets"

    def test_pass_login_failure_all_pass_secrets_empty(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "pst_test")
        settings = {
            "secrets": {
                "BAD": {"pass": "pass://vault/item/field", "hosts": []},
                "GOOD": {"value": "plain", "hosts": []},
            }
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                return MagicMock(returncode=1, stdout="", stderr="authentication failed")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            addon.load(MagicMock())

        assert addon.secrets["BAD"]["value"] == "", "pass:// secret must be empty when login failed"
        assert addon.secrets["GOOD"]["value"] == "plain", "value secret must still resolve when pass login failed"

    def test_pat_verification_passes_for_pat_session(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "pst_test")
        settings = {
            "secrets": {"KEY": {"pass": "pass://vault/item/field", "hosts": ["a.com"]}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                return MagicMock(returncode=0, stdout="", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "info":
                return MagicMock(returncode=0, stdout="Personal Access Token: sandcat\n", stderr="")
            return MagicMock(returncode=0, stdout="resolved\n", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            addon.load(MagicMock())  # must not raise

        assert addon.secrets["KEY"]["value"] == "resolved"

    def test_pat_verification_hard_blocks_user_account_session(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "account-password")
        settings = {
            "secrets": {"KEY": {"pass": "pass://vault/item/field", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        logout_calls = []

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                return MagicMock(returncode=0, stdout="", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "info":
                # Simulates a full account session — no PAT indicator
                return MagicMock(returncode=0, stdout="Logged in as: user@example.com\n", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "logout":
                logout_calls.append(True)
                return MagicMock(returncode=0, stdout="", stderr="")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            with pytest.raises(RuntimeError, match="SECURITY"):
                addon.load(MagicMock())

        assert len(logout_calls) == 1, "pass-cli logout must be called once to wipe the non-PAT session"

    def test_pat_verification_reports_auth_failure_distinctly(self, addon_cls, tmp_path, monkeypatch):
        # `pass-cli info` exiting non-zero means the session could not be
        # verified (bad/expired token) — NOT a full-account credential. The
        # error must say so rather than firing the misleading SECURITY message.
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "pst_expired")
        settings = {
            "secrets": {"KEY": {"pass": "pass://vault/item/field", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        logout_calls = []

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                return MagicMock(returncode=0, stdout="", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "info":
                return MagicMock(returncode=1, stdout="", stderr="session expired")
            if cmd[0] == "pass-cli" and cmd[1] == "logout":
                logout_calls.append(True)
                return MagicMock(returncode=0, stdout="", stderr="")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            with pytest.raises(RuntimeError) as excinfo:
                addon.load(MagicMock())

        msg = str(excinfo.value)
        assert "could not verify" in msg, "auth-failure error must explain the session could not be verified"
        assert "SECURITY" not in msg, "auth failure must not masquerade as a full-account security error"
        assert len(logout_calls) == 1, "pass-cli logout must wipe the unverifiable session"

    def test_pat_verification_skipped_when_no_pass_secrets(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "anything")
        settings = {
            "secrets": {"KEY": {"op": "op://vault/item/field", "hosts": ["a.com"]}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        info_calls = []

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "info":
                info_calls.append(True)
            if cmd[0] == "op":
                return MagicMock(returncode=0, stdout="resolved\n", stderr="")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            addon.load(MagicMock())

        assert info_calls == [], "pass-cli info must not be called when there are no pass:// secrets"


class TestPassCliPatSessionDetection:
    """Unit tests for PAT session detection from pass-cli info output."""

    @pytest.mark.parametrize(
        "stdout",
        [
            "Personal Access Token: sandcat\n",
            "PERSONAL ACCESS TOKEN: pst_test\n",
            "personal access token: pst_test\n",
            "Personal\tAccess\tToken: sandcat\n",
            # Real output shape: leading "- " and surrounding whitespace.
            "- Release track: stable\n- Personal Access Token: sandcat\n",
            "-   personal access token  :  sandcat\n",
        ],
    )
    def test_pass_cli_session_is_pat_accepts_varied_casing_and_spacing(self, stdout):
        assert common._pass_cli_session_is_pat(stdout) is True

    @pytest.mark.parametrize(
        "stdout",
        [
            "",
            "Logged in as: user@example.com\n",
            "- Email: user@proton.me\n- Username: alice\n",
            "Release track: stable\nID: abc\n",
            # Hardening: the phrase appearing inside a field *value* (not as a
            # line-start label) must NOT be read as a PAT session.
            "- Username: personal access token\n- Email: a@b.com\n",
            "- Username: personal access token: foo\n",
        ],
    )
    def test_pass_cli_session_is_pat_rejects_account_session_output(self, stdout):
        assert common._pass_cli_session_is_pat(stdout) is False

    @pytest.mark.parametrize("addon_cls", ADDONS)
    def test_pat_verification_accepts_odd_casing_info_output(self, addon_cls, tmp_path, monkeypatch):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "pst_test")
        settings = {
            "secrets": {"KEY": {"pass": "pass://vault/item/field", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        def mock_run_side_effect(cmd, **kwargs):
            if cmd[0] == "pass-cli" and cmd[1] == "login":
                return MagicMock(returncode=0, stdout="", stderr="")
            if cmd[0] == "pass-cli" and cmd[1] == "info":
                return MagicMock(
                    returncode=0,
                    stdout="PERSONAL\tACCESS\tTOKEN: sandcat\n",
                    stderr="",
                )
            return MagicMock(returncode=0, stdout="resolved\n", stderr="")

        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run_side_effect):
            addon.load(MagicMock())

        assert addon.secrets["KEY"]["value"] == "resolved"


# ---------------------------------------------------------------------------
# pass-cli PAT-detection contract — bump-gated against the pinned version.
#
# pass-cli is pinned by version + per-arch sha256 in
# images/mitmproxy-pass/pass-cli.env, so its `pass-cli info` output cannot drift
# under us without a deliberate bump. These tests lock the regex against golden
# samples of that output and fail if the pin is bumped without re-capturing the
# goldens (see cli/test/mitmproxy/fixtures/pass-cli/README.md).
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[3]
_PASS_CLI_ENV = _REPO_ROOT / "images" / "mitmproxy-pass" / "pass-cli.env"
_PASS_CLI_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "pass-cli"


def _read_env_file(path: Path) -> dict:
    """Parse a simple KEY=value .env file (ignores comments and blank lines)."""
    out = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if sep:
            out[key.strip()] = value.strip()
    return out


class TestPassCliPatContract:
    """Locks the PAT-detection heuristic against the pinned pass-cli output."""

    def test_pinned_env_has_version_and_checksums(self):
        env = _read_env_file(_PASS_CLI_ENV)
        assert env.get("PASS_CLI_VERSION"), "PASS_CLI_VERSION missing from pass-cli.env"
        for arch in ("PASS_CLI_SHA256_X86_64", "PASS_CLI_SHA256_AARCH64"):
            assert re.fullmatch(r"[0-9a-f]{64}", env.get(arch, "")), (
                f"{arch} must be a 64-char sha256 hex digest"
            )

    def test_goldens_were_captured_against_pinned_version(self):
        env = _read_env_file(_PASS_CLI_ENV)
        golden_version = (_PASS_CLI_FIXTURES / "VERSION").read_text().strip()
        assert golden_version == env["PASS_CLI_VERSION"], (
            "pass-cli was bumped without re-capturing the golden `pass-cli info` "
            "samples. See cli/test/mitmproxy/fixtures/pass-cli/README.md."
        )

    def test_pat_session_golden_is_detected_as_pat(self):
        pat_output = (_PASS_CLI_FIXTURES / "info_pat.txt").read_text()
        assert common._pass_cli_session_is_pat(pat_output) is True, (
            "PAT-session `pass-cli info` golden no longer matches the detection "
            "regex — upstream wording likely changed; update _PAT_SESSION_MARKER."
        )

    def test_full_account_golden_is_rejected(self):
        account_output = (_PASS_CLI_FIXTURES / "info_full_account.txt").read_text()
        assert common._pass_cli_session_is_pat(account_output) is False, (
            "Full-account `pass-cli info` golden now matches the PAT detection "
            "regex — the security guarantee is broken; tighten _PAT_SESSION_MARKER."
        )


# ---------------------------------------------------------------------------
# Startup diagnostics — warnings and per-secret summaries that help users
# spot misconfigurations such as putting a ``pass://`` reference under the
# ``value`` field instead of the ``pass`` field.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestStartupDiagnostics:
    """Locks in the diagnostic logging emitted at addon load time."""

    def test_secret_source_helper_identifies_known_sources(self, addon_cls):
        assert addon_cls._secret_source({"value": "x"}) == "value"
        assert addon_cls._secret_source({"op": "op://a/b/c"}) == "op"
        assert addon_cls._secret_source({"pass": "pass://a/b/c"}) == "pass"

    def test_secret_source_helper_flags_invalid_entries(self, addon_cls):
        assert addon_cls._secret_source({}) == "invalid(missing)"
        assert "invalid(multiple:" in addon_cls._secret_source(
            {"value": "x", "pass": "pass://a/b/c"}
        )

    def test_value_field_with_pass_reference_emits_warning(
        self, addon_cls, tmp_path, monkeypatch
    ):
        monkeypatch.delenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", raising=False)
        settings = {
            "secrets": {
                "API_KEY": {
                    "value": "pass://Vault/Item/secret",
                    "hosts": ["api.example.com"],
                },
            },
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        log = MagicMock()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.ctx.log", log):
            addon.load(MagicMock())

        warn_msgs = [c.args[0] for c in log.warn.call_args_list]
        assert any(
            "'value' field starts with 'pass://'" in m
            and "API_KEY" in m
            and '"pass":' in m
            for m in warn_msgs
        ), f"expected pass:// misuse warning, got: {warn_msgs}"

    def test_value_field_with_op_reference_emits_warning(
        self, addon_cls, tmp_path
    ):
        settings = {
            "secrets": {
                "API_KEY": {"value": "op://Vault/Item/field", "hosts": []},
            },
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        log = MagicMock()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.ctx.log", log):
            addon.load(MagicMock())

        warn_msgs = [c.args[0] for c in log.warn.call_args_list]
        assert any(
            "'value' field starts with 'op://'" in m and '"op":' in m
            for m in warn_msgs
        ), f"expected op:// misuse warning, got: {warn_msgs}"

    def test_plain_value_does_not_emit_misuse_warning(
        self, addon_cls, tmp_path
    ):
        settings = {
            "secrets": {"API_KEY": {"value": "plain-secret", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        log = MagicMock()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.ctx.log", log):
            addon.load(MagicMock())

        warn_msgs = [c.args[0] for c in log.warn.call_args_list]
        assert not any("'value' field starts with" in m for m in warn_msgs), \
            f"unexpected misuse warning: {warn_msgs}"

    def test_per_secret_summary_includes_source_and_length(
        self, addon_cls, tmp_path
    ):
        settings = {
            "secrets": {
                "PLAIN": {"value": "abcdef", "hosts": ["a.com", "b.com"]},
            },
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        log = MagicMock()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.ctx.log", log):
            addon.load(MagicMock())

        info_msgs = [c.args[0] for c in log.info.call_args_list]
        assert any(
            "Secret 'PLAIN':" in m and "source=value" in m
            and "resolved_len=6" in m and "hosts=2" in m
            for m in info_msgs
        ), f"expected per-secret summary, got: {info_msgs}"

    def test_per_secret_summary_does_not_leak_value(
        self, addon_cls, tmp_path
    ):
        settings = {
            "secrets": {
                "PLAIN": {"value": "super-secret-shibboleth", "hosts": []},
            },
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        log = MagicMock()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.ctx.log", log):
            addon.load(MagicMock())

        all_msgs = (
            [c.args[0] for c in log.info.call_args_list]
            + [c.args[0] for c in log.warn.call_args_list]
        )
        assert not any("shibboleth" in m for m in all_msgs), \
            f"secret value leaked into logs: {all_msgs}"

    def test_proton_pass_token_applied_from_settings_logged(
        self, addon_cls, monkeypatch
    ):
        monkeypatch.delenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", raising=False)
        log = MagicMock()
        with patch(f"{_COMMON}.ctx.log", log):
            addon_cls._configure_proton_pass_token("pst_abc")
        info_msgs = [c.args[0] for c in log.info.call_args_list]
        assert any(
            "proton_pass_token: applied from settings" in m and "len=7" in m
            for m in info_msgs
        ), f"expected applied log, got: {info_msgs}"
        monkeypatch.delenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", raising=False)

    def test_proton_pass_token_env_precedence_logged(
        self, addon_cls, monkeypatch
    ):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "from_env")
        log = MagicMock()
        with patch(f"{_COMMON}.ctx.log", log):
            addon_cls._configure_proton_pass_token("from_settings")
        info_msgs = [c.args[0] for c in log.info.call_args_list]
        assert any(
            "using existing PROTON_PASS_PERSONAL_ACCESS_TOKEN from environment"
            in m for m in info_msgs
        ), f"expected env-precedence log, got: {info_msgs}"

    def test_proton_pass_token_missing_logged(self, addon_cls, monkeypatch):
        monkeypatch.delenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", raising=False)
        log = MagicMock()
        with patch(f"{_COMMON}.ctx.log", log):
            addon_cls._configure_proton_pass_token(None)
        info_msgs = [c.args[0] for c in log.info.call_args_list]
        assert any(
            "proton_pass_token: not configured" in m for m in info_msgs
        ), f"expected missing-token log, got: {info_msgs}"

    def test_pass_cli_login_success_emits_info(
        self, addon_cls, tmp_path, monkeypatch
    ):
        monkeypatch.setenv("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "pst_test")
        settings = {
            "secrets": {"K": {"pass": "pass://v/i/f", "hosts": ["a.com"]}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()

        def mock_run(cmd, **kwargs):
            if cmd[:2] == ["pass-cli", "info"]:
                return MagicMock(
                    returncode=0,
                    stdout="Personal Access Token: pst_test\n",
                    stderr="",
                )
            return MagicMock(returncode=0, stdout="ok\n", stderr="")

        log = MagicMock()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.subprocess.run", side_effect=mock_run), \
             patch(f"{_COMMON}.ctx.log", log):
            addon.load(MagicMock())

        info_msgs = [c.args[0] for c in log.info.call_args_list]
        assert any("pass-cli login: succeeded" in m for m in info_msgs), \
            f"expected pass-cli login success log, got: {info_msgs}"
        assert any(
            "pass-cli info: confirmed Personal Access Token (PAT) session" in m
            for m in info_msgs
        ), f"expected PAT verification log, got: {info_msgs}"


# ---------------------------------------------------------------------------
# Settings merging — pure shared logic on the base class.
# ---------------------------------------------------------------------------

class TestSettingsMerging:
    """Static merge helper lives in the shared library."""

    def test_env_higher_precedence_wins(self):
        layers = [
            {"env": {"A": "user", "B": "user"}},
            {"env": {"B": "project"}},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["env"] == {"A": "user", "B": "project"}

    def test_secrets_higher_precedence_wins(self):
        layers = [
            {"secrets": {
                "KEY1": {"value": "v1-user", "hosts": ["a.com"]},
                "KEY2": {"value": "v2-user", "hosts": ["b.com"]},
            }},
            {"secrets": {
                "KEY2": {"value": "v2-project", "hosts": ["c.com"]},
            }},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["secrets"]["KEY1"]["value"] == "v1-user"
        assert merged["secrets"]["KEY2"]["value"] == "v2-project"
        assert merged["secrets"]["KEY2"]["hosts"] == ["c.com"]

    def test_network_rules_highest_precedence_first(self):
        layers = [
            {"network": [{"action": "allow", "host": "user.com"}]},
            {"network": [{"action": "allow", "host": "project.com"}]},
            {"network": [{"action": "deny", "host": "local.com"}]},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["network"] == [
            {"action": "deny", "host": "local.com"},
            {"action": "allow", "host": "project.com"},
            {"action": "allow", "host": "user.com"},
        ]

    def test_missing_sections_treated_as_empty(self):
        layers = [
            {"env": {"A": "1"}},
            {"network": [{"action": "allow", "host": "*"}]},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["env"] == {"A": "1"}
        assert merged["secrets"] == {}
        assert merged["network"] == [{"action": "allow", "host": "*"}]
        assert merged["op_service_account_token"] is None
        assert merged["proton_pass_token"] is None

    def test_op_token_highest_precedence_wins(self):
        layers = [
            {"op_service_account_token": "user_token"},
            {"op_service_account_token": "project_token"},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["op_service_account_token"] == "project_token"

    def test_op_token_skips_empty(self):
        layers = [
            {"op_service_account_token": "user_token"},
            {"op_service_account_token": ""},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["op_service_account_token"] == "user_token"

    def test_op_token_absent(self):
        layers = [{"env": {"A": "1"}}]
        merged = BaseAddon._merge_settings(layers)
        assert merged["op_service_account_token"] is None
        assert merged["proton_pass_token"] is None

    def test_proton_pass_token_highest_precedence_wins(self):
        layers = [
            {"proton_pass_token": "user_pass"},
            {"proton_pass_token": "project_pass"},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["proton_pass_token"] == "project_pass"

    def test_proton_pass_token_skips_empty(self):
        layers = [
            {"proton_pass_token": "user_pass"},
            {"proton_pass_token": ""},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["proton_pass_token"] == "user_pass"

    def test_empty_layers_list(self):
        merged = BaseAddon._merge_settings([])
        assert merged == {
            "env": {},
            "secrets": {},
            "network": [],
            "op_service_account_token": None,
            "dns_servers": None,
            "proton_pass_token": None,
        }

    def test_dns_servers_highest_precedence_wins(self):
        layers = [
            {"dns_servers": ["10.0.0.1"]},
            {"dns_servers": ["10.0.0.2", "10.0.0.3"]},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["dns_servers"] == ["10.0.0.2", "10.0.0.3"]

    def test_dns_servers_explicit_empty_wins_over_lower_layer(self):
        # Higher-precedence layer explicitly sets [] → resets to "no overrides",
        # the wg-client falls back to its hardcoded defaults.
        layers = [
            {"dns_servers": ["10.0.0.1"]},
            {"dns_servers": []},
        ]
        merged = BaseAddon._merge_settings(layers)
        assert merged["dns_servers"] == []

    def test_dns_servers_absent(self):
        layers = [{"env": {"A": "1"}}]
        merged = BaseAddon._merge_settings(layers)
        assert merged["dns_servers"] is None

    def test_dns_servers_lower_layer_used_when_higher_layer_omits_key(self):
        # Most common shape: user sets corp DNS, project doesn't touch it.
        layers = [{"dns_servers": ["10.0.0.1"]}, {"env": {"A": "1"}}]
        merged = BaseAddon._merge_settings(layers)
        assert merged["dns_servers"] == ["10.0.0.1"]

    def test_dns_servers_explicit_null_overrides_lower_layer(self):
        # A higher layer with explicit null resets the merge — wg-client falls
        # back to defaults.
        layers = [{"dns_servers": ["10.0.0.1"]}, {"dns_servers": None}]
        merged = BaseAddon._merge_settings(layers)
        assert merged["dns_servers"] is None


# ---------------------------------------------------------------------------
# Multi-file loading — exercises the shared layer-reading loop.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestMultiFileLoading:
    def test_loads_multiple_settings_files(self, addon_cls, tmp_path):
        user_settings = {
            "env": {"A": "user"},
            "network": [{"action": "allow", "host": "user.com"}],
        }
        project_settings = {"env": {"A": "project", "B": "project"}}
        (tmp_path / "user.json").write_text(json.dumps(user_settings))
        (tmp_path / "project.json").write_text(json.dumps(project_settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS",
                   [str(tmp_path / "user.json"), str(tmp_path / "project.json")]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        assert addon.env == {"A": "project", "B": "project"}
        assert addon.network_rules == [{"action": "allow", "host": "user.com"}]

    def test_skips_missing_files(self, addon_cls, tmp_path):
        user_settings = {"env": {"A": "user"}}
        (tmp_path / "user.json").write_text(json.dumps(user_settings))
        env_path = tmp_path / "sandcat.env"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [
            str(tmp_path / "user.json"),
            str(tmp_path / "missing.json"),
            str(tmp_path / "also-missing.json"),
        ]), patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        assert addon.env == {"A": "user"}


# ---------------------------------------------------------------------------
# Shared library helpers — purely unit tests on the base class.
# ---------------------------------------------------------------------------

class TestCommonHelpers:
    def test_is_truthy_true_values(self):
        for v in ["1", "true", "TRUE", "yes", "ON", " on ", True]:
            assert BaseAddon._is_truthy(v) is True

    def test_is_truthy_false_values(self):
        for v in ["0", "false", "no", "off", "", None, False]:
            assert BaseAddon._is_truthy(v) is False

    def test_default_is_textual_content_type_returns_true(self):
        # Base default: any content type passes.
        assert BaseAddon._is_textual_content_type("") is True
        assert BaseAddon._is_textual_content_type(None) is True
        assert BaseAddon._is_textual_content_type("application/octet-stream") is True

    def test_default_is_streaming_request_false(self):
        addon = BaseAddon()
        flow = _make_flow(host="example.com")
        assert addon._is_streaming_request(flow) is False

    def test_default_basic_auth_helpers_are_inert(self):
        assert BaseAddon._basic_auth_contains_placeholder("Basic xxx", "P") is False
        assert BaseAddon._replace_placeholder_in_basic_auth("Basic xxx", "P", "v") == ("Basic xxx", False)

    def test_default_normalize_authorization_header_is_passthrough(self):
        addon = BaseAddon()
        assert addon._normalize_authorization_header("Bearer  abc  ") == "Bearer  abc  "

    def test_auth_debug_summary_missing(self):
        assert BaseAddon._auth_debug_summary(None).startswith("authorization=<missing>")
        assert BaseAddon._auth_debug_summary("").startswith("authorization=<missing>")

    def test_auth_debug_summary_bearer_format(self):
        summary = BaseAddon._auth_debug_summary("Bearer abc")
        assert summary.startswith("bearer len=3")
        assert "sha256_12=" in summary

    def test_auth_debug_summary_basic_format(self):
        import base64

        encoded = base64.b64encode(b"user:pass").decode("ascii")
        summary = BaseAddon._auth_debug_summary(f"Basic {encoded}")
        assert summary.startswith("basic decoded_len=9")

    def test_auth_debug_summary_other(self):
        assert BaseAddon._auth_debug_summary("Digest xyz").startswith("other len=")


# ---------------------------------------------------------------------------
# Cursor textual content-type gate (direct unit tests).
# ---------------------------------------------------------------------------

class TestCursorTextualContentType:
    @pytest.mark.parametrize("ct", [
        "application/json",
        "application/json; charset=utf-8",
        "text/plain",
        "text/html",
        "application/x-www-form-urlencoded",
        "application/vnd.api+json",
        "application/atom+xml",
        "application/javascript",
        "application/graphql",
        "application/xml",
    ])
    def test_textual_types(self, ct):
        assert CursorAddon._is_textual_content_type(ct) is True

    @pytest.mark.parametrize("ct", [
        "",
        None,
        "application/octet-stream",
        "image/png",
        "application/connect+proto",
        "application/grpc",
    ])
    def test_non_textual_types(self, ct):
        assert CursorAddon._is_textual_content_type(ct) is False


# ---------------------------------------------------------------------------
# Cursor debug flag — wired up via SANDCAT_MITM_DEBUG.
# ---------------------------------------------------------------------------

class TestCursorDebugFlag:
    def test_debug_disabled_by_default(self, tmp_path, monkeypatch):
        monkeypatch.delenv("SANDCAT_MITM_DEBUG", raising=False)
        settings = {"env": {"A": "1"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = CursorAddon()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        assert addon.debug_enabled is False

    def test_debug_enabled_via_env_var(self, tmp_path, monkeypatch):
        monkeypatch.setenv("SANDCAT_MITM_DEBUG", "1")
        settings = {"env": {"A": "1"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = CursorAddon()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        assert addon.debug_enabled is True

    def test_debug_enabled_via_settings(self, tmp_path, monkeypatch):
        monkeypatch.delenv("SANDCAT_MITM_DEBUG", raising=False)
        settings = {"env": {"SANDCAT_MITM_DEBUG": "true"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = CursorAddon()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        assert addon.debug_enabled is True

    def test_claude_does_not_read_debug_flag(self, tmp_path, monkeypatch):
        monkeypatch.setenv("SANDCAT_MITM_DEBUG", "1")
        settings = {"env": {"A": "1"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = ClaudeAddon()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        # Claude variant doesn't override _on_settings_merged → flag stays False.
        assert addon.debug_enabled is False

    def test_debug_not_exported_to_sandcat_env(self, tmp_path, monkeypatch):
        monkeypatch.delenv("SANDCAT_MITM_DEBUG", raising=False)
        settings = {
            "env": {"SANDCAT_MITM_DEBUG": "1", "GIT_USER_NAME": "dev"},
            "network": [{"action": "allow", "host": "*"}],
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = CursorAddon()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        written = env_path.read_text()
        assert "SANDCAT_MITM_DEBUG" not in written
        assert 'export GIT_USER_NAME="dev"' in written

    def test_debug_logs_to_stderr_on_request(self, tmp_path, monkeypatch, capsys):
        monkeypatch.delenv("SANDCAT_MITM_DEBUG", raising=False)
        settings = {
            "env": {"SANDCAT_MITM_DEBUG": "1"},
            "network": [{"action": "allow", "host": "*"}],
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = CursorAddon()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(p)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        capsys.readouterr()  # discard startup debug line
        flow = _make_flow(host="api2.cursor.sh", url="https://api2.cursor.sh/health")
        addon.request(flow)
        err = capsys.readouterr().err
        assert "[sandcat-debug]" in err
        assert "api2.cursor.sh/health" in err


# ---------------------------------------------------------------------------
# DNS server override — settings → dns.conf sidecar consumed by wg-client.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("addon_cls", ADDONS)
class TestDnsServersConfig:
    @staticmethod
    def _load(addon_cls, settings, tmp_path):
        # settings=None simulates the "no settings files exist" branch — the
        # patched SETTINGS_PATHS still points at tmp_path/settings.json, but
        # the file is never created.
        settings_path = tmp_path / "settings.json"
        if settings is not None:
            settings_path.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        dns_conf_path = tmp_path / "dns.conf"
        addon = addon_cls()
        with patch(f"{_COMMON}.SETTINGS_PATHS", [str(settings_path)]), \
             patch(f"{_COMMON}.SANDCAT_ENV_PATH", str(env_path)), \
             patch(f"{_COMMON}.SANDCAT_DNS_CONF_PATH", str(dns_conf_path)):
            addon.load(MagicMock())
        return addon, dns_conf_path

    def test_no_dns_servers_setting_writes_empty_file(self, addon_cls, tmp_path):
        # Empty file (not absent) so its presence is a valid "addon loaded"
        # sentinel for the mitmproxy healthcheck; wg-client treats empty as
        # "no overrides — use defaults".
        addon, dns_conf_path = self._load(addon_cls, {"env": {"A": "1"}}, tmp_path)
        assert addon.dns_servers == []
        assert dns_conf_path.read_text() == ""

    def test_custom_dns_servers_written_one_per_line(self, addon_cls, tmp_path):
        addon, dns_conf_path = self._load(
            addon_cls, {"dns_servers": ["10.0.0.10", "10.0.0.11"]}, tmp_path,
        )
        assert addon.dns_servers == ["10.0.0.10", "10.0.0.11"]
        assert dns_conf_path.read_text() == "10.0.0.10\n10.0.0.11\n"

    def test_empty_list_writes_empty_file_so_wg_client_uses_defaults(self, addon_cls, tmp_path):
        addon, dns_conf_path = self._load(addon_cls, {"dns_servers": []}, tmp_path)
        assert addon.dns_servers == []
        assert dns_conf_path.read_text() == ""

    def test_malformed_non_list_skipped(self, addon_cls, tmp_path):
        addon, dns_conf_path = self._load(
            addon_cls, {"dns_servers": "10.0.0.10"}, tmp_path,
        )
        assert addon.dns_servers == []
        assert dns_conf_path.read_text() == ""

    def test_non_string_entries_dropped(self, addon_cls, tmp_path):
        addon, dns_conf_path = self._load(
            addon_cls,
            {"dns_servers": ["10.0.0.10", 1234, None, "10.0.0.11"]},
            tmp_path,
        )
        assert addon.dns_servers == ["10.0.0.10", "10.0.0.11"]
        assert dns_conf_path.read_text() == "10.0.0.10\n10.0.0.11\n"

    def test_blank_entries_dropped(self, addon_cls, tmp_path):
        addon, dns_conf_path = self._load(
            addon_cls,
            {"dns_servers": ["", "  ", "10.0.0.10", "\t"]},
            tmp_path,
        )
        assert addon.dns_servers == ["10.0.0.10"]
        assert dns_conf_path.read_text() == "10.0.0.10\n"

    def test_entries_are_stripped(self, addon_cls, tmp_path):
        addon, dns_conf_path = self._load(
            addon_cls, {"dns_servers": ["  10.0.0.10  ", "\t10.0.0.11"]}, tmp_path,
        )
        assert addon.dns_servers == ["10.0.0.10", "10.0.0.11"]

    @pytest.mark.parametrize("separator", ["\n", "\r", "\r\n"])
    def test_entries_with_embedded_newlines_dropped(self, addon_cls, tmp_path, separator):
        addon, dns_conf_path = self._load(
            addon_cls,
            {"dns_servers": [f"10.0.0.10{separator}evil-line", "10.0.0.11"]},
            tmp_path,
        )
        assert addon.dns_servers == ["10.0.0.11"]
        assert dns_conf_path.read_text() == "10.0.0.11\n"

    def test_stale_dns_conf_overwritten_with_new_contents(self, addon_cls, tmp_path):
        # A previous run wrote nameservers; a new load with different values
        # must replace the file exactly (no leftover stale lines).
        (tmp_path / "dns.conf").write_text("9.9.9.9\n9.9.9.10\n")
        _, dns_conf_path = self._load(
            addon_cls, {"dns_servers": ["10.0.0.10"]}, tmp_path,
        )
        assert dns_conf_path.read_text() == "10.0.0.10\n"

    @pytest.mark.parametrize("bad_entry", [
        "not-an-ip",
        "intranet.corp.example.com",
        "1.1.1.1; rm -rf /",
        "999.999.999.999",
        "10.0.0",
    ])
    def test_non_ip_entries_dropped(self, addon_cls, tmp_path, bad_entry):
        addon, dns_conf_path = self._load(
            addon_cls,
            {"dns_servers": [bad_entry, "10.0.0.10"]},
            tmp_path,
        )
        assert addon.dns_servers == ["10.0.0.10"]
        assert dns_conf_path.read_text() == "10.0.0.10\n"

    def test_ipv6_entries_accepted(self, addon_cls, tmp_path):
        addon, dns_conf_path = self._load(
            addon_cls,
            {"dns_servers": ["2001:4860:4860::8888", "::1"]},
            tmp_path,
        )
        assert addon.dns_servers == ["2001:4860:4860::8888", "::1"]
        assert dns_conf_path.read_text() == "2001:4860:4860::8888\n::1\n"

    def test_stale_dns_conf_cleared_when_all_settings_files_absent(
        self, addon_cls, tmp_path,
    ):
        # Persistent volume case: a previous run wrote dns.conf, then the user
        # deletes every settings layer. The next load must clear the sidecar so
        # wg-client falls back to defaults — otherwise the old corp DNS sticks.
        (tmp_path / "dns.conf").write_text("10.0.0.99\n")
        _, dns_conf_path = self._load(addon_cls, None, tmp_path)
        assert dns_conf_path.read_text() == ""

    def test_stale_dns_conf_cleared_when_setting_dropped(self, addon_cls, tmp_path):
        # Simulate a previous run that wrote dns.conf, then the user removes
        # `dns_servers` from settings — the file must be overwritten empty so
        # wg-client falls back to defaults.
        (tmp_path / "dns.conf").write_text("10.0.0.99\n")
        _, dns_conf_path = self._load(addon_cls, {"env": {"A": "1"}}, tmp_path)
        assert dns_conf_path.read_text() == ""
