from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path


class MissingNetBirdCredentials(Exception):
    pass


@dataclass(frozen=True)
class NetBirdCredentials:
    api_token: str
    management_url: str | None


def _read_setting(key: str) -> str | None:
    value: str | None = None
    for env_var in ("SANDCAT_SETTINGS_USER", "SANDCAT_SETTINGS_PROJECT"):
        path_str = os.environ.get(env_var)
        if not path_str:
            continue
        path = Path(path_str)
        if not path.is_file():
            continue
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
        layer_value = data.get(key)
        if layer_value:
            value = str(layer_value)
    return value


_LOOPBACK_MANAGEMENT_URL = re.compile(
    r"^https?://(localhost|127\.0\.0\.1)([:/]|$)",
    re.IGNORECASE,
)


def _management_url_is_loopback(url: str) -> bool:
    return _LOOPBACK_MANAGEMENT_URL.match(url) is not None


def _resolve_management_url(url: str | None) -> str | None:
    """Use enrollment URL when management URL targets host loopback (container-safe).

    Matches sandcat CLI ``netbird_enrollment_management_url_from``: wg-client and
    capability-runtime run in Docker and cannot reach the host via localhost.
    """
    if url is None or not _management_url_is_loopback(url):
        return url
    enrollment = _read_setting("netbird_enrollment_management_url")
    return enrollment if enrollment else url


def load_netbird_route_groups() -> list[str] | None:
    """Distribution group IDs for new routes (NB_ROUTE_GROUPS or netbird_route_groups)."""
    raw = os.environ.get("NB_ROUTE_GROUPS")
    if raw:
        groups = [part.strip() for part in raw.split(",") if part.strip()]
        return groups or None

    for env_var in ("SANDCAT_SETTINGS_USER", "SANDCAT_SETTINGS_PROJECT"):
        path_str = os.environ.get(env_var)
        if not path_str:
            continue
        path = Path(path_str)
        if not path.is_file():
            continue
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
        value = data.get("netbird_route_groups")
        if not value:
            continue
        if isinstance(value, list):
            groups = [str(item).strip() for item in value if str(item).strip()]
            if groups:
                return groups
        setting = str(value)
        if setting.startswith("["):
            parsed = json.loads(setting)
            groups = [str(item).strip() for item in parsed if str(item).strip()]
            if groups:
                return groups
        groups = [part.strip() for part in setting.split(",") if part.strip()]
        if groups:
            return groups
    return None


def load_netbird_credentials() -> NetBirdCredentials:
    token = os.environ.get("NB_API_TOKEN") or _read_setting("netbird_api_token")
    url = _resolve_management_url(
        os.environ.get("NB_MANAGEMENT_URL")
        or _read_setting("netbird_management_url")
        or None
    )
    if not token:
        raise MissingNetBirdCredentials("netbird_api_token is not set")
    return NetBirdCredentials(api_token=token, management_url=url)
