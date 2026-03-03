"""Unit tests for mitmproxy-addon.py — no mitmproxy daemon needed."""

import json
import sys
import types
from unittest.mock import MagicMock, patch

import pytest

# Stub out mitmproxy imports so tests run without installing mitmproxy
_ctx = MagicMock()
_http = types.ModuleType("mitmproxy.http")


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
        self.headers = _Headers(headers or {})
        self.content = content


class _Response:
    @staticmethod
    def make(status, body, headers):
        return {"status": status, "body": body, "headers": headers}


_http.HTTPFlow = type("HTTPFlow", (), {})
_http.Response = _Response

sys.modules["mitmproxy"] = types.ModuleType("mitmproxy")
sys.modules["mitmproxy.ctx"] = _ctx
sys.modules["mitmproxy.http"] = _http
sys.modules["mitmproxy"].ctx = _ctx
sys.modules["mitmproxy"].http = _http

# Import after mitmproxy stubs are installed in sys.modules above.
from mitmproxy_addon import SandcatAddon, SETTINGS_PATHS  # noqa: E402


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


# ---------------------------------------------------------------------------
# Network rules
# ---------------------------------------------------------------------------

class TestNetworkRules:
    def test_first_match_wins_allow_before_deny(self):
        addon = SandcatAddon()
        addon.network_rules = [
            {"action": "allow", "host": "*"},
            {"action": "deny", "host": "*"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True

    def test_first_match_wins_deny_before_allow(self):
        addon = SandcatAddon()
        addon.network_rules = [
            {"action": "deny", "host": "*"},
            {"action": "allow", "host": "*"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is False

    def test_default_deny_on_no_match(self):
        addon = SandcatAddon()
        addon.network_rules = []
        assert addon._is_request_allowed("GET", "example.com") is False

    def test_method_specific_rule(self):
        addon = SandcatAddon()
        addon.network_rules = [
            {"action": "allow", "host": "*", "method": "GET"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True
        assert addon._is_request_allowed("POST", "example.com") is False

    def test_method_omitted_matches_any(self):
        addon = SandcatAddon()
        addon.network_rules = [
            {"action": "allow", "host": "*"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True
        assert addon._is_request_allowed("POST", "example.com") is True
        assert addon._is_request_allowed("PUT", "example.com") is True

    def test_host_glob_pattern(self):
        addon = SandcatAddon()
        addon.network_rules = [
            {"action": "allow", "host": "*.github.com"},
        ]
        assert addon._is_request_allowed("GET", "api.github.com") is True
        assert addon._is_request_allowed("GET", "example.com") is False

    def test_full_ruleset_from_plan(self):
        addon = SandcatAddon()
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

    def test_method_matching_is_case_insensitive(self):
        addon = SandcatAddon()
        addon.network_rules = [
            {"action": "allow", "host": "*", "method": "get"},
        ]
        assert addon._is_request_allowed("GET", "example.com") is True


# ---------------------------------------------------------------------------
# Secret substitution
# ---------------------------------------------------------------------------

class TestSecretSubstitution:
    def _make_addon_with_secrets(self):
        addon = SandcatAddon()
        addon.network_rules = [{"action": "allow", "host": "*"}]
        addon.secrets = {
            "API_KEY": {
                "value": "real-secret-value",
                "hosts": ["api.example.com"],
                "placeholder": "SANDCAT_PLACEHOLDER_API_KEY",
            }
        }
        return addon

    def test_placeholder_replaced_in_header(self):
        addon = self._make_addon_with_secrets()
        flow = _make_flow(
            host="api.example.com",
            headers={"Authorization": "Bearer SANDCAT_PLACEHOLDER_API_KEY"},
        )
        addon.request(flow)
        assert flow.response is None
        assert flow.request.headers["Authorization"] == "Bearer real-secret-value"

    def test_placeholder_replaced_in_body(self):
        addon = self._make_addon_with_secrets()
        flow = _make_flow(
            method="POST",
            host="api.example.com",
            content=b'{"key": "SANDCAT_PLACEHOLDER_API_KEY"}',
        )
        addon.request(flow)
        assert flow.response is None
        assert b"real-secret-value" in flow.request.content

    def test_placeholder_replaced_in_url(self):
        addon = self._make_addon_with_secrets()
        flow = _make_flow(
            host="api.example.com",
            url="https://api.example.com/?token=SANDCAT_PLACEHOLDER_API_KEY",
        )
        addon.request(flow)
        assert flow.response is None
        assert "real-secret-value" in flow.request.url

    def test_no_op_when_placeholder_absent(self):
        addon = self._make_addon_with_secrets()
        flow = _make_flow(host="api.example.com")
        addon.request(flow)
        assert flow.response is None
        assert "real-secret-value" not in flow.request.url

    def test_leak_detection_blocks_disallowed_host(self):
        addon = self._make_addon_with_secrets()
        flow = _make_flow(
            host="evil.com",
            headers={"Authorization": "Bearer SANDCAT_PLACEHOLDER_API_KEY"},
        )
        addon.request(flow)
        assert flow.response is not None
        assert flow.response["status"] == 403


# ---------------------------------------------------------------------------
# Integration
# ---------------------------------------------------------------------------

class TestIntegration:
    def test_network_deny_blocks_before_substitution(self):
        addon = SandcatAddon()
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

    def test_network_allow_plus_substitution(self):
        addon = SandcatAddon()
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
# Config loading
# ---------------------------------------------------------------------------

class TestConfigLoading:
    def test_missing_settings_file_disables_addon(self):
        addon = SandcatAddon()
        with patch("mitmproxy_addon.os.path.isfile", return_value=False):
            addon.load(MagicMock())
        assert addon.env == {}
        assert addon.secrets == {}
        assert addon.network_rules == []

    def test_missing_secrets_key_uses_empty(self, tmp_path):
        settings = {"network": [{"action": "allow", "host": "*"}]}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(tmp_path / "sandcat.env")):
            addon.load(MagicMock())
        assert addon.secrets == {}
        assert len(addon.network_rules) == 1

    def test_missing_network_key_uses_empty(self, tmp_path):
        settings = {"secrets": {
            "KEY": {"value": "v", "hosts": ["h.com"]}
        }}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(tmp_path / "sandcat.env")):
            addon.load(MagicMock())
        assert len(addon.secrets) == 1
        assert addon.network_rules == []

    def test_placeholders_env_written_correctly(self, tmp_path):
        settings = {"secrets": {
            "A": {"value": "va", "hosts": []},
            "B": {"value": "vb", "hosts": []},
        }}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export A="SANDCAT_PLACEHOLDER_A"' in content
        assert 'export B="SANDCAT_PLACEHOLDER_B"' in content

    def test_env_vars_written_to_placeholders_env(self, tmp_path):
        settings = {
            "env": {"GIT_USER_NAME": "Alice", "GIT_USER_EMAIL": "alice@example.com"},
            "secrets": {"K": {"value": "v", "hosts": []}},
        }
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export GIT_USER_NAME="Alice"' in content
        assert 'export GIT_USER_EMAIL="alice@example.com"' in content
        assert 'export K="SANDCAT_PLACEHOLDER_K"' in content

    def test_env_vars_partial(self, tmp_path):
        settings = {"env": {"EDITOR": "vim"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export EDITOR="vim"' in content

    def test_missing_env_section_omits_vars(self, tmp_path):
        settings = {"secrets": {"K": {"value": "v", "hosts": []}}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert content.startswith('export K=')


# ---------------------------------------------------------------------------
# Shell escaping
# ---------------------------------------------------------------------------

class TestShellEscaping:
    def test_double_quotes_escaped(self, tmp_path):
        settings = {"env": {"X": 'val"ue'}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export X="val\\"ue"' in content

    def test_backslashes_escaped(self, tmp_path):
        settings = {"env": {"X": "a\\b"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export X="a\\\\b"' in content

    def test_dollar_and_backtick_escaped(self, tmp_path):
        settings = {"env": {"X": "$(rm -rf /)`cmd`"}}
        p = tmp_path / "settings.json"
        p.write_text(json.dumps(settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(p)]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        content = env_path.read_text()
        assert 'export X="\\$(rm -rf /)\\`cmd\\`"' in content

    def test_plain_values_unchanged(self):
        assert SandcatAddon._shell_escape("hello world") == "hello world"
        assert SandcatAddon._shell_escape("sk-ant-abc123") == "sk-ant-abc123"


# ---------------------------------------------------------------------------
# Settings merging
# ---------------------------------------------------------------------------

class TestSettingsMerging:
    def test_env_higher_precedence_wins(self):
        layers = [
            {"env": {"A": "user", "B": "user"}},
            {"env": {"B": "project"}},
        ]
        merged = SandcatAddon._merge_settings(layers)
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
        merged = SandcatAddon._merge_settings(layers)
        assert merged["secrets"]["KEY1"]["value"] == "v1-user"
        assert merged["secrets"]["KEY2"]["value"] == "v2-project"
        assert merged["secrets"]["KEY2"]["hosts"] == ["c.com"]

    def test_network_rules_highest_precedence_first(self):
        layers = [
            {"network": [{"action": "allow", "host": "user.com"}]},
            {"network": [{"action": "allow", "host": "project.com"}]},
            {"network": [{"action": "deny", "host": "local.com"}]},
        ]
        merged = SandcatAddon._merge_settings(layers)
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
        merged = SandcatAddon._merge_settings(layers)
        assert merged["env"] == {"A": "1"}
        assert merged["secrets"] == {}
        assert merged["network"] == [{"action": "allow", "host": "*"}]

    def test_empty_layers_list(self):
        merged = SandcatAddon._merge_settings([])
        assert merged == {"env": {}, "secrets": {}, "network": []}



class TestMultiFileLoading:
    def test_loads_multiple_settings_files(self, tmp_path):
        user_settings = {"env": {"A": "user"}, "network": [{"action": "allow", "host": "user.com"}]}
        project_settings = {"env": {"A": "project", "B": "project"}}
        (tmp_path / "user.json").write_text(json.dumps(user_settings))
        (tmp_path / "project.json").write_text(json.dumps(project_settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [str(tmp_path / "user.json"), str(tmp_path / "project.json")]), \
             patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        assert addon.env == {"A": "project", "B": "project"}
        assert addon.network_rules == [{"action": "allow", "host": "user.com"}]

    def test_skips_missing_files(self, tmp_path):
        user_settings = {"env": {"A": "user"}}
        (tmp_path / "user.json").write_text(json.dumps(user_settings))
        env_path = tmp_path / "sandcat.env"
        addon = SandcatAddon()
        with patch("mitmproxy_addon.SETTINGS_PATHS", [
            str(tmp_path / "user.json"),
            str(tmp_path / "missing.json"),
            str(tmp_path / "also-missing.json"),
        ]), patch("mitmproxy_addon.SANDCAT_ENV_PATH", str(env_path)):
            addon.load(MagicMock())
        assert addon.env == {"A": "user"}

