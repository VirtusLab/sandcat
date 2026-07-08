import json

from capability_runtime.settings import load_netbird_credentials, load_netbird_route_groups


def test_load_credentials_project_over_user(tmp_path, monkeypatch):
    user = tmp_path / "user" / "settings.json"
    project = tmp_path / "project" / ".sandcat" / "settings.json"
    user.parent.mkdir(parents=True)
    project.parent.mkdir(parents=True)
    user.write_text(json.dumps({"netbird_api_token": "user-tok"}))
    project.write_text(
        json.dumps(
            {
                "netbird_api_token": "proj-tok",
                "netbird_management_url": "https://mgmt.example.com",
            }
        )
    )
    monkeypatch.setenv("SANDCAT_SETTINGS_USER", str(user))
    monkeypatch.setenv("SANDCAT_SETTINGS_PROJECT", str(project))
    creds = load_netbird_credentials()
    assert creds.api_token == "proj-tok"
    assert creds.management_url == "https://mgmt.example.com"


def test_load_credentials_uses_enrollment_url_when_management_is_localhost(
    tmp_path, monkeypatch
):
    settings = tmp_path / "settings.json"
    settings.write_text(
        json.dumps(
            {
                "netbird_api_token": "tok",
                "netbird_management_url": "http://localhost:33073",
                "netbird_enrollment_management_url": "http://192.168.5.2:33073",
            }
        )
    )
    monkeypatch.setenv("SANDCAT_SETTINGS_USER", str(settings))
    monkeypatch.delenv("SANDCAT_SETTINGS_PROJECT", raising=False)
    monkeypatch.delenv("NB_MANAGEMENT_URL", raising=False)

    creds = load_netbird_credentials()
    assert creds.management_url == "http://192.168.5.2:33073"


def test_load_credentials_keeps_remote_management_url(tmp_path, monkeypatch):
    settings = tmp_path / "settings.json"
    settings.write_text(
        json.dumps(
            {
                "netbird_api_token": "tok",
                "netbird_management_url": "https://netbird.example.com",
                "netbird_enrollment_management_url": "http://192.168.5.2:33073",
            }
        )
    )
    monkeypatch.setenv("SANDCAT_SETTINGS_USER", str(settings))

    creds = load_netbird_credentials()
    assert creds.management_url == "https://netbird.example.com"


def test_load_credentials_loopback_management_without_enrollment_unchanged(
    tmp_path, monkeypatch
):
    settings = tmp_path / "settings.json"
    settings.write_text(
        json.dumps(
            {
                "netbird_api_token": "tok",
                "netbird_management_url": "http://127.0.0.1:33073",
            }
        )
    )
    monkeypatch.setenv("SANDCAT_SETTINGS_USER", str(settings))

    creds = load_netbird_credentials()
    assert creds.management_url == "http://127.0.0.1:33073"


def test_load_route_groups_from_env(monkeypatch):
    monkeypatch.setenv("NB_ROUTE_GROUPS", "grp-a, grp-b")
    assert load_netbird_route_groups() == ["grp-a", "grp-b"]


def test_load_route_groups_from_settings_json_array(tmp_path, monkeypatch):
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({"netbird_route_groups": ["grp-x", "grp-y"]}))
    monkeypatch.setenv("SANDCAT_SETTINGS_USER", str(settings))
    monkeypatch.delenv("NB_ROUTE_GROUPS", raising=False)
    assert load_netbird_route_groups() == ["grp-x", "grp-y"]
