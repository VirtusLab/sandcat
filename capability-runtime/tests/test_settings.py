import json

from capability_runtime.settings import load_netbird_credentials


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
