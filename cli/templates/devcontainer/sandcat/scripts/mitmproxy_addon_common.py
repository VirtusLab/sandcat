"""
Shared mitmproxy addon library for sandcat.

Provides a base ``SandcatAddon`` class that agent-specific addons subclass.
The base implements all behavior that is identical across agents:

  - Settings layer loading and merging (user / project / local).
  - 1Password (``op://``) and Proton Pass (``pass://``) reference resolution.
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

Proton Pass authentication
--------------------------
``pass://`` secrets require a Personal Access Token (PAT), **not** a full
Proton account credential.  A PAT is created with ``pass-cli pat create``
and scoped to specific vaults/items via ``pass-cli pat access grant``.
A PAT starts with zero access by default, which limits the blast radius if
the token is ever compromised.

Using a full account credential is rejected: after ``pass-cli login`` the
addon runs ``pass-cli info`` and checks for ``"Personal Access Token"`` in
the output.  If instead a user e-mail is shown the session is wiped with
``pass-cli logout`` and the addon load fails, refusing to start mitmproxy.
"""

import base64
import binascii
import hashlib
import ipaddress
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
# Sidecar file consumed by wg-client to override /etc/resolv.conf nameservers.
# One IPv4/IPv6 address per line; empty or missing file means "use defaults".
# (glibc/musl resolvers reject hostnames in `nameserver` directives.)
SANDCAT_DNS_CONF_PATH = "/home/mitmproxy/.mitmproxy/dns.conf"

logger = logging.getLogger(__name__)


# PAT sessions print a `Personal Access Token: <name>` field; full accounts
# print `ID`/`Username`/`Email` instead. Anchor to a line-start label (optional
# leading `- ` and a trailing colon) so a full-account *value* that happens to
# contain the phrase (e.g. a username "personal access token") can't be mistaken
# for a PAT. Casing/spacing-tolerant; format drift is caught by the golden
# contract test (see cli/test/mitmproxy/fixtures/pass-cli/).
_PAT_SESSION_MARKER = re.compile(
    r"^\s*-?\s*personal\s+access\s+token\s*:", re.IGNORECASE | re.MULTILINE
)


def _pass_cli_session_is_pat(stdout: str) -> bool:
    """Return True when ``pass-cli info`` output indicates a PAT session."""
    return bool(_PAT_SESSION_MARKER.search(stdout or ""))


class SandcatAddon:
    """Base sandcat addon: network policy + secret substitution."""

    def __init__(self):
        self.secrets: dict[str, dict] = {}  # name -> {value, hosts, placeholder}
        self.network_rules: list[dict] = []
        self.env: dict[str, str] = {}  # non-secret env vars (e.g. git identity)
        self.dns_servers: list[str] = []  # custom upstream DNS for wg-client
        self.debug_enabled = False  # subclasses may flip this in _on_settings_merged
        self._pass_cli_logged_in = False  # True only after a successful pass-cli login

    # ------------------------------------------------------------------ load

    def load(self, loader):
        layers = []
        for path in SETTINGS_PATHS:
            if os.path.isfile(path):
                with open(path) as f:
                    layers.append(json.load(f))

        if not layers:
            # Write an empty dns.conf so wg-client treats it as "no overrides"
            # (falling back to defaults) AND so the file's presence still
            # signals "addon has loaded" for the mitmproxy healthcheck.
            self._write_dns_conf()
            logger.info("No settings files found — addon disabled")
            return

        merged = self._merge_settings(layers)
        self._on_settings_merged(merged)

        self._configure_op_token(merged.get("op_service_account_token"))
        self._configure_proton_pass_token(merged.get("proton_pass_token"))

        has_pass_secrets = any("pass" in e for e in merged["secrets"].values())
        self._pass_cli_logged_in = self._pass_cli_login_if_needed(has_pass_secrets)
        if has_pass_secrets and self._pass_cli_logged_in:
            self._verify_pat_auth_or_die()

        self.env = merged["env"]
        self._load_secrets(merged["secrets"])
        self._load_network_rules(merged["network"])
        self._load_dns_servers(merged["dns_servers"])
        self._write_placeholders_env()
        self._write_dns_conf()

        ctx.log.info(
            f"Loaded {len(self.env)} env var(s), {len(self.secrets)} secret(s), "
            f"and {len(self.dns_servers)} custom DNS server(s); wrote {SANDCAT_ENV_PATH}"
        )

    def _on_settings_merged(self, merged: dict):
        """Hook: subclasses may inspect merged settings (e.g., feature flags)."""
        pass

    @staticmethod
    def _configure_op_token(token: str | None):
        """Set OP_SERVICE_ACCOUNT_TOKEN from settings if not already in the environment."""
        if "OP_SERVICE_ACCOUNT_TOKEN" in os.environ:
            ctx.log.info(
                "op_service_account_token: using existing OP_SERVICE_ACCOUNT_TOKEN "
                "from environment (settings value, if any, ignored)"
            )
        elif token:
            os.environ["OP_SERVICE_ACCOUNT_TOKEN"] = token
            ctx.log.info(
                f"op_service_account_token: applied from settings (len={len(token)})"
            )
        else:
            ctx.log.info("op_service_account_token: not configured")

    @staticmethod
    def _configure_proton_pass_token(token: str | None):
        """Set PROTON_PASS_PERSONAL_ACCESS_TOKEN from settings if not already in the environment.

        The value must be a Proton Pass Personal Access Token (PAT) created with
        ``pass-cli pat create``.  Full account credentials are rejected at login
        time by ``_verify_pat_auth_or_die``.
        """
        if "PROTON_PASS_PERSONAL_ACCESS_TOKEN" in os.environ:
            ctx.log.info(
                "proton_pass_token: using existing PROTON_PASS_PERSONAL_ACCESS_TOKEN "
                "from environment (settings value, if any, ignored)"
            )
        elif token:
            os.environ["PROTON_PASS_PERSONAL_ACCESS_TOKEN"] = token
            ctx.log.info(
                f"proton_pass_token: applied from settings (len={len(token)})"
            )
        else:
            ctx.log.info("proton_pass_token: not configured")

    def _pass_cli_login_if_needed(self, has_pass_secrets: bool) -> bool:
        """Attempt ``pass-cli login`` when at least one ``pass://`` secret is present.

        ``has_pass_secrets`` is computed once by the caller (``load``) from the
        merged secrets.  Returns ``True`` if login succeeded or there are no
        ``pass://`` secrets (login not needed).  Returns ``False`` if login
        failed for any reason — callers should treat all ``pass://`` secrets as
        unresolvable.
        """
        if not has_pass_secrets:
            return True  # no pass:// secrets — login not needed

        if not os.environ.get("PROTON_PASS_PERSONAL_ACCESS_TOKEN"):
            ctx.log.warn(
                "PROTON_PASS_PERSONAL_ACCESS_TOKEN not set; "
                "all pass:// secrets will be skipped"
            )
            return False

        try:
            result = subprocess.run(
                ["pass-cli", "login"],
                capture_output=True, text=True, timeout=30,
            )
        except FileNotFoundError:
            ctx.log.warn(
                "pass-cli not found in PATH; "
                "ensure the sandcat-mitmproxy-pass image is in use"
            )
            return False

        if result.returncode != 0:
            ctx.log.warn(
                f"pass-cli login failed (exit {result.returncode}); "
                "check PROTON_PASS_PERSONAL_ACCESS_TOKEN"
            )
            return False

        ctx.log.info("pass-cli login: succeeded")
        return True

    def _verify_pat_auth_or_die(self):
        """Confirm the active session is a PAT, not a full account credential.

        Runs ``pass-cli info`` and checks for a Personal Access Token session
        marker (case- and whitespace-insensitive).  Two distinct failure modes,
        both fail-closed (logout + raise, preventing mitmproxy from starting):

        - ``pass-cli info`` exits non-zero — the session could not be verified
          (auth failed / session expired).  Reported as an auth error.
        - the session is valid but shows no PAT marker — a full account
          credential.  Reported as a security error.

        This check is only called when at least one ``pass://`` secret exists,
        so op-only or value-only projects are unaffected.
        """
        try:
            info = subprocess.run(
                ["pass-cli", "info"],
                capture_output=True, text=True, timeout=10,
            )
        except FileNotFoundError:
            raise RuntimeError(
                "pass-cli not found while verifying PAT authentication"
            ) from None

        if info.returncode != 0:
            self._pass_cli_logout()
            msg = (
                f"pass-cli could not verify the Proton Pass session "
                f"(`pass-cli info` exited {info.returncode}). The token is "
                "invalid or the session expired; check "
                "PROTON_PASS_PERSONAL_ACCESS_TOKEN. This is an authentication "
                "failure, not necessarily a full-account credential."
            )
            ctx.log.error(msg)
            raise RuntimeError(msg)

        if not _pass_cli_session_is_pat(info.stdout):
            self._pass_cli_logout()
            msg = (
                "SECURITY: proton_pass_token does not authenticate as a Proton Pass "
                "Personal Access Token. Using a full account credential would give "
                "this mitmproxy container access to every vault on your account. "
                "Create a scoped PAT with `pass-cli pat create` and grant it "
                "read-only access to only the vaults/items this project needs with "
                "`pass-cli pat access grant --role viewer`. "
                "See https://protonpass.github.io/pass-cli/commands/personal-access-token/"
            )
            ctx.log.error(msg)
            raise RuntimeError(msg)

        ctx.log.info("pass-cli info: confirmed Personal Access Token (PAT) session")

    @staticmethod
    def _pass_cli_logout():
        """Wipe the active pass-cli session (best-effort)."""
        subprocess.run(
            ["pass-cli", "logout"],
            capture_output=True, text=True, timeout=10,
        )

    @staticmethod
    def _merge_settings(layers: list[dict]) -> dict:
        """Merge settings from multiple layers (lowest to highest precedence).

        - env: dict merge, higher precedence overwrites.
        - secrets: dict merge, higher precedence overwrites.
        - network: concatenated, highest precedence first (top-to-bottom matching).
        - op_service_account_token: highest precedence non-empty value wins.
        - dns_servers: highest-precedence layer that sets the key wins (last-wins).
        - proton_pass_token: highest precedence non-empty value wins.
          Must be a Proton Pass Personal Access Token (PAT); full account
          credentials are rejected at startup by ``_verify_pat_auth_or_die``.
        """
        env: dict[str, str] = {}
        secrets: dict[str, dict] = {}
        network: list[dict] = []
        op_token: str | None = None
        dns_servers = None
        proton_pass_token: str | None = None

        for layer in layers:
            env.update(layer.get("env", {}))
            secrets.update(layer.get("secrets", {}))
            layer_token = layer.get("op_service_account_token")
            if layer_token:
                op_token = layer_token
            if "dns_servers" in layer:
                dns_servers = layer["dns_servers"]
            layer_proton_pass_token = layer.get("proton_pass_token")
            if layer_proton_pass_token:
                proton_pass_token = layer_proton_pass_token

        # Network rules: highest-precedence layer's rules come first.
        for layer in reversed(layers):
            network.extend(layer.get("network", []))

        return {
            "env": env,
            "secrets": secrets,
            "network": network,
            "op_service_account_token": op_token,
            "dns_servers": dns_servers,
            "proton_pass_token": proton_pass_token,
        }

    # --------------------------------------------------------------- secrets

    def _load_secrets(self, raw_secrets: dict):
        for name, entry in raw_secrets.items():
            placeholder = f"SANDCAT_PLACEHOLDER_{name}"
            self._warn_if_value_looks_like_reference(name, entry)
            source = self._secret_source(entry)
            if "pass" in entry and not self._pass_cli_logged_in:
                msg = (
                    f"Secret {name!r}: pass-cli login did not succeed; "
                    "skipping pass:// resolution"
                )
                ctx.log.warn(msg)
                print(f"WARNING: {msg}", file=sys.stderr)
                value = ""
            else:
                try:
                    value = self._resolve_secret_value(name, entry)
                except (RuntimeError, ValueError) as e:
                    ctx.log.warn(str(e))
                    print(f"WARNING: {e}", file=sys.stderr)
                    value = ""
            normalized = self._normalize_secret_value(value)
            self.secrets[name] = {
                "value": normalized,
                "hosts": entry.get("hosts", []),
                "placeholder": placeholder,
            }
            ctx.log.info(
                f"Secret {name!r}: source={source} resolved_len={len(normalized)} "
                f"hosts={len(entry.get('hosts', []))}"
            )

    @staticmethod
    def _secret_source(entry: dict) -> str:
        """Return the secret entry's source key for logging (value/op/pass/invalid)."""
        keys = [k for k in ("value", "op", "pass") if k in entry]
        if len(keys) == 1:
            return keys[0]
        if not keys:
            return "invalid(missing)"
        return f"invalid(multiple:{'+'.join(keys)})"

    @staticmethod
    def _warn_if_value_looks_like_reference(name: str, entry: dict):
        """Detect the common misconfiguration of putting an ``op://`` or
        ``pass://`` reference under the literal ``value`` field.

        Without this check, the literal reference string is injected verbatim
        as the secret (e.g., ``Authorization: Bearer pass://Vault/Item/secret``)
        with no upstream lookup, which is almost never what the user intended.
        """
        raw = entry.get("value")
        if not isinstance(raw, str):
            return
        stripped = raw.strip()
        for scheme, correct_key in (("op://", "op"), ("pass://", "pass")):
            if stripped.startswith(scheme):
                msg = (
                    f"Secret {name!r}: 'value' field starts with {scheme!r}, "
                    f"which looks like a reference. To resolve it, move the "
                    f"reference under the {correct_key!r} key instead of "
                    f"'value' (e.g., \"{correct_key}\": \"{stripped}\"). "
                    f"As written, the literal string will be injected verbatim "
                    f"and no upstream lookup will happen."
                )
                ctx.log.warn(msg)
                print(f"WARNING: {msg}", file=sys.stderr)
                return

    @classmethod
    def _resolve_secret_value(cls, name: str, entry: dict) -> str:
        """Resolve a secret from a plain ``value``, 1Password ``op://``, or Proton Pass ``pass://`` reference."""
        has_value = "value" in entry
        has_op = "op" in entry
        has_pass = "pass" in entry

        provided = [has_value, has_op, has_pass]
        if sum(provided) != 1:
            raise ValueError(
                f"Secret {name!r}: specify exactly one of 'value', 'op', or 'pass'"
            )

        if has_value:
            return cls._normalize_secret_value(entry["value"])

        if has_op:
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

        pass_ref = entry["pass"]
        if not pass_ref.startswith("pass://"):
            raise ValueError(
                f"Secret {name!r}: 'pass' value must start with 'pass://', got {pass_ref!r}"
            )
        try:
            result = subprocess.run(
                ["pass-cli", "item", "view", pass_ref],
                capture_output=True, text=True, timeout=30,
            )
        except FileNotFoundError:
            raise RuntimeError(
                f"Secret {name!r}: 'pass-cli' not found. Install Proton Pass CLI to use pass:// references."
            ) from None
        if result.returncode != 0:
            raise RuntimeError(
                f"Secret {name!r}: 'pass-cli' read failed: {result.stderr.strip()}"
            )
        return cls._normalize_secret_value(result.stdout.strip())

    @staticmethod
    def _normalize_secret_value(value) -> str:
        """Default: coerce to string. Subclasses may strip whitespace / BOM."""
        return "" if value is None else str(value)

    # --------------------------------------------------------------- network

    def _load_network_rules(self, raw_rules: list):
        self.network_rules = raw_rules
        ctx.log.info(f"Loaded {len(self.network_rules)} network rule(s)")

    # ----------------------------------------------------------- DNS servers

    def _load_dns_servers(self, raw):
        """Validate the merged ``dns_servers`` value into a list of nameserver strings.

        Accepts a list of non-empty strings; anything else (None, non-list,
        non-string entries, blank strings) is dropped with a warning. The
        resulting list may be empty, in which case the wg-client falls back
        to its hardcoded defaults.
        """
        if raw is None:
            self.dns_servers = []
            return
        if not isinstance(raw, list):
            ctx.log.warn(
                f"dns_servers must be a list of strings, got {type(raw).__name__}; "
                "falling back to defaults"
            )
            self.dns_servers = []
            return
        cleaned: list[str] = []
        for entry in raw:
            if not isinstance(entry, str):
                ctx.log.warn(
                    f"dns_servers entry must be a string, got {type(entry).__name__}; skipping"
                )
                continue
            stripped = entry.strip()
            if not stripped:
                continue
            try:
                ipaddress.ip_address(stripped)
            except ValueError:
                ctx.log.warn(
                    f"dns_servers entry {stripped!r} is not a valid IP address; skipping "
                    "(resolv.conf nameserver requires IPv4/IPv6, not hostnames)"
                )
                continue
            cleaned.append(stripped)
        self.dns_servers = cleaned

    def _write_dns_conf(self):
        """Write nameservers for wg-client to consume.

        Always writes the file (one IP per line; empty when no overrides) so
        its presence is a load-order sentinel: the mitmproxy healthcheck
        gates wg-client startup on this file existing, eliminating the race
        where wg-client could otherwise read an absent dns.conf and silently
        fall back to defaults before the addon had a chance to write it.
        wg-client treats an empty file as "no overrides — use defaults".
        """
        body = "\n".join(self.dns_servers)
        if self.dns_servers:
            body += "\n"
        try:
            self._atomic_write_text(SANDCAT_DNS_CONF_PATH, body)
        except OSError as e:
            ctx.log.warn(
                f"Could not write {SANDCAT_DNS_CONF_PATH}: {e!r}; "
                "wg-client will continue with its previous DNS settings"
            )
            return
        if self.dns_servers:
            ctx.log.info(
                f"Wrote {len(self.dns_servers)} custom DNS server(s) to {SANDCAT_DNS_CONF_PATH}"
            )

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
        self._atomic_write_text(SANDCAT_ENV_PATH, "\n".join(lines) + "\n")

    @staticmethod
    def _atomic_write_text(path: str, body: str):
        """Write a sidecar file consumed by another container, atomically.

        Writes to a sibling ``.tmp`` and ``os.replace``s onto the final path,
        so a concurrent reader either sees the previous contents or the new
        ones — never a half-written or briefly-absent file.
        """
        tmp_path = path + ".tmp"
        with open(tmp_path, "w") as f:
            f.write(body)
        os.replace(tmp_path, path)

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
            msg = f"[sandcat-debug] {message}"
            ctx.log.info(msg)
            # Mirror warnings: ctx.log.info alone is often invisible in mitmweb
            # Docker logs (buffering / termlog routing to the web UI).
            print(msg, file=sys.stderr)

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
