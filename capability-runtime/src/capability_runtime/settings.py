from __future__ import annotations

import json
import os
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


def load_netbird_credentials() -> NetBirdCredentials:
    token = os.environ.get("NB_API_TOKEN") or _read_setting("netbird_api_token")
    url = (
        os.environ.get("NB_MANAGEMENT_URL")
        or _read_setting("netbird_management_url")
        or None
    )
    if not token:
        raise MissingNetBirdCredentials("netbird_api_token is not set")
    return NetBirdCredentials(api_token=token, management_url=url)
