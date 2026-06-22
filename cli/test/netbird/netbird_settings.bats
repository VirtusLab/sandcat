#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/netbird.bash"

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/sandcat"
    PROJECT_DIR="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT_DIR/.sandcat"
    cd "$PROJECT_DIR" || return 1
}

teardown() {
    unstub_all
}

@test "netbird_read_setting returns empty when no settings exist" {
    run netbird_read_setting netbird_api_token
    assert_success
    assert_output ""
}

@test "netbird_read_setting reads netbird_api_token from user settings" {
    echo '{"netbird_api_token": "user-token"}' > "$HOME/.config/sandcat/settings.json"

    run netbird_read_setting netbird_api_token
    assert_output "user-token"
}

@test "netbird_read_setting prefers project settings over user settings" {
    echo '{"netbird_api_token": "user-token"}' > "$HOME/.config/sandcat/settings.json"
    echo '{"netbird_api_token": "project-token"}' > "$PROJECT_DIR/.sandcat/settings.json"

    run netbird_read_setting netbird_api_token
    assert_output "project-token"
}

@test "netbird_read_setting prefers local project settings over project settings" {
    echo '{"netbird_api_token": "user-token"}' > "$HOME/.config/sandcat/settings.json"
    echo '{"netbird_api_token": "project-token"}' > "$PROJECT_DIR/.sandcat/settings.json"
    echo '{"netbird_api_token": "local-token"}' > "$PROJECT_DIR/.sandcat/settings.local.json"

    run netbird_read_setting netbird_api_token
    assert_output "local-token"
}

@test "export_netbird_compose_env exports enrollment key from user settings" {
    echo '{"netbird_enrollment_key": "setup-key-123"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_SETUP_KEY

    export_netbird_compose_env

    [[ "$NB_SETUP_KEY" == "setup-key-123" ]]
}

@test "export_netbird_compose_env does not override existing NB_SETUP_KEY" {
    echo '{"netbird_enrollment_key": "from-settings"}' > "$HOME/.config/sandcat/settings.json"
    export NB_SETUP_KEY="from-env"

    export_netbird_compose_env

    [[ "$NB_SETUP_KEY" == "from-env" ]]
}

@test "export_netbird_management_url exports management URL from user settings" {
    echo '{"netbird_management_url": "https://management.example.com"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_MANAGEMENT_URL

    export_netbird_management_url

    [[ "$NB_MANAGEMENT_URL" == "https://management.example.com" ]]
}

@test "export_netbird_management_url does not override existing NB_MANAGEMENT_URL" {
    echo '{"netbird_management_url": "https://from-settings.example.com"}' > "$HOME/.config/sandcat/settings.json"
    export NB_MANAGEMENT_URL="https://from-env.example.com"

    export_netbird_management_url

    [[ "$NB_MANAGEMENT_URL" == "https://from-env.example.com" ]]
}

@test "netbird_enrollment_management_url_from returns empty for localhost without explicit enrollment URL" {
    run netbird_enrollment_management_url_from "http://localhost:33073"
    assert_output ""
}

@test "netbird_enrollment_management_url_from returns empty for 127.0.0.1 without explicit enrollment URL" {
    run netbird_enrollment_management_url_from "http://127.0.0.1:33073"
    assert_output ""
}

@test "netbird_enrollment_management_url_from leaves remote URLs unchanged" {
    run netbird_enrollment_management_url_from "https://netbird.example.com"
    assert_output "https://netbird.example.com"
}

@test "netbird_enrollment_management_url_from prefers netbird_enrollment_management_url setting" {
    echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"

    run netbird_enrollment_management_url_from "http://localhost:33073"
    assert_output "http://192.168.5.2:33073"
}

@test "netbird_enrollment_url_uses_host_bypass for literal IPv4 enrollment URL" {
    run netbird_enrollment_url_uses_host_bypass "http://192.168.5.2:33073"
    assert_success
}

@test "netbird_enrollment_url_uses_host_bypass is false for hostname enrollment URL" {
    run netbird_enrollment_url_uses_host_bypass "https://netbird.example.com"
    assert_failure
}

@test "netbird_sync_local_server_exposed_address updates config.yaml from enrollment URL" {
    echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"
    mkdir -p "$HOME/.config/sandcat/netbird-server"
    echo 'server: { exposedAddress: "http://localhost:33073" }' > "$HOME/.config/sandcat/netbird-server/config.yaml"

    netbird_sync_local_server_exposed_address

    run yq -r '.server.exposedAddress' "$HOME/.config/sandcat/netbird-server/config.yaml"
    assert_output "http://192.168.5.2:33073"
}

@test "netbird_sync_local_server_exposed_address is a no-op when already aligned" {
    echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"
    mkdir -p "$HOME/.config/sandcat/netbird-server"
    echo 'server: { exposedAddress: "http://192.168.5.2:33073" }' > "$HOME/.config/sandcat/netbird-server/config.yaml"

    run netbird_sync_local_server_exposed_address
    assert_success
    refute_output --partial "Updated netbird-server exposedAddress"
}

@test "provision_netbird_server_template copies template and skips when already provisioned" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR/netbird-server"
    echo "services: {}" > "$SCT_TEMPLATEDIR/netbird-server/docker-compose.yml"
    echo "NETBIRD_SERVER_VERSION=0.1.0" > "$SCT_TEMPLATEDIR/netbird-server/netbird-server.env"
    echo "server: { store: { encryptionKey: \"\" } }" > "$SCT_TEMPLATEDIR/netbird-server/config.yaml"
    echo "NETBIRD_MGMT_API_ENDPOINT=http://localhost:33073" > "$SCT_TEMPLATEDIR/netbird-server/dashboard.env"
    echo "# template" > "$SCT_TEMPLATEDIR/netbird-server/README.md"

    provision_netbird_server_template
    [[ -d "$HOME/.config/sandcat/netbird-server" ]]
    [[ -f "$HOME/.config/sandcat/netbird-server/docker-compose.yml" ]]
    [[ "$(cat "$HOME/.config/sandcat/netbird-server/docker-compose.yml")" == "services: {}" ]]
    [[ -n "$(yq -r '.server.store.encryptionKey // ""' "$HOME/.config/sandcat/netbird-server/config.yaml")" ]]

    run provision_netbird_server_template
    assert_success
    assert_output --partial "skipping"
}

@test "provision_netbird_server_template generates secrets in env and config.yaml" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR/netbird-server"
    echo "services: {}" > "$SCT_TEMPLATEDIR/netbird-server/docker-compose.yml"
    printf '%s\n' \
        "NETBIRD_SERVER_VERSION=0.1.0" \
        "NETBIRD_ENCRYPTION_KEY=" \
        "NETBIRD_RELAY_AUTH_SECRET=" \
        "NETBIRD_MGMT_API_PORT=33073" \
        "NETBIRD_DASHBOARD_HTTP_PORT=8080" \
        > "$SCT_TEMPLATEDIR/netbird-server/netbird-server.env"
    echo "server: { authSecret: \"\", store: { encryptionKey: \"\" }, auth: { issuer: \"\" } }" > "$SCT_TEMPLATEDIR/netbird-server/config.yaml"
    echo "NETBIRD_MGMT_API_ENDPOINT=http://localhost:33073" > "$SCT_TEMPLATEDIR/netbird-server/dashboard.env"
    echo "# template" > "$SCT_TEMPLATEDIR/netbird-server/README.md"
    unset NETBIRD_ENCRYPTION_KEY NETBIRD_RELAY_AUTH_SECRET

    provision_netbird_server_template

    local env_key config_key
    env_key=$(grep '^NETBIRD_ENCRYPTION_KEY=' "$HOME/.config/sandcat/netbird-server/netbird-server.env" | cut -d= -f2-)
    config_key=$(yq -r '.server.store.encryptionKey' "$HOME/.config/sandcat/netbird-server/config.yaml")
    [[ -n "$env_key" ]]
    [[ "$env_key" == "$config_key" ]]
    [[ "$(yq -r '.server.auth.issuer' "$HOME/.config/sandcat/netbird-server/config.yaml")" == "http://localhost:33073/oauth2" ]]
    [[ "$(yq -r '.server.auth.dashboardRedirectURIs[0]' "$HOME/.config/sandcat/netbird-server/config.yaml")" == "http://localhost:8080/nb-auth" ]]
}

@test "provision_netbird_server_template uses NETBIRD_ENCRYPTION_KEY from environment" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR/netbird-server"
    echo "services: {}" > "$SCT_TEMPLATEDIR/netbird-server/docker-compose.yml"
    printf '%s\n' "NETBIRD_SERVER_VERSION=0.1.0" "NETBIRD_ENCRYPTION_KEY=" > "$SCT_TEMPLATEDIR/netbird-server/netbird-server.env"
    echo "server: { store: { encryptionKey: \"\" } }" > "$SCT_TEMPLATEDIR/netbird-server/config.yaml"
    echo "NETBIRD_MGMT_API_ENDPOINT=http://localhost:33073" > "$SCT_TEMPLATEDIR/netbird-server/dashboard.env"
    echo "# template" > "$SCT_TEMPLATEDIR/netbird-server/README.md"
    export NETBIRD_ENCRYPTION_KEY="user-provided-key-base64=="

    provision_netbird_server_template

    grep -q '^NETBIRD_ENCRYPTION_KEY=user-provided-key-base64==' "$HOME/.config/sandcat/netbird-server/netbird-server.env"
    [[ "$(yq -r '.server.store.encryptionKey' "$HOME/.config/sandcat/netbird-server/config.yaml")" == "user-provided-key-base64==" ]]
}

@test "provision_netbird_server_template skips when destination exists as file" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR/netbird-server"
    echo "services: {}" > "$SCT_TEMPLATEDIR/netbird-server/docker-compose.yml"
    echo "NETBIRD_SERVER_VERSION=0.1.0" > "$SCT_TEMPLATEDIR/netbird-server/netbird-server.env"
    echo "server: {}" > "$SCT_TEMPLATEDIR/netbird-server/config.yaml"
    echo "NETBIRD_MGMT_API_ENDPOINT=http://localhost:33073" > "$SCT_TEMPLATEDIR/netbird-server/dashboard.env"
    echo "# template" > "$SCT_TEMPLATEDIR/netbird-server/README.md"
    mkdir -p "$HOME/.config/sandcat"
    echo "existing-file" > "$HOME/.config/sandcat/netbird-server"

    run provision_netbird_server_template
    assert_success
    assert_output --partial "skipping"
    [[ "$(cat "$HOME/.config/sandcat/netbird-server")" == "existing-file" ]]
}

@test "provision_netbird_server_template fails when template directory is missing" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR"

    run provision_netbird_server_template
    assert_failure
    assert_output --partial "Missing NetBird server template directory"
}

@test "provision_netbird_server_template fails when required companion is missing" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR/netbird-server"
    echo "services: {}" > "$SCT_TEMPLATEDIR/netbird-server/docker-compose.yml"
    echo "NETBIRD_SERVER_VERSION=0.1.0" > "$SCT_TEMPLATEDIR/netbird-server/netbird-server.env"
    echo "NETBIRD_MGMT_API_ENDPOINT=http://localhost:33073" > "$SCT_TEMPLATEDIR/netbird-server/dashboard.env"
    echo "# template" > "$SCT_TEMPLATEDIR/netbird-server/README.md"

    run provision_netbird_server_template
    assert_failure
    assert_output --partial "missing config.yaml"
}

@test "netbird_api reads netbird_api_token from user settings" {
    echo '{"netbird_api_token": "settings-token"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_API_TOKEN
    export NB_MANAGEMENT_URL="https://api.netbird.io"

    stub curl \
        "-sS -X GET -H 'Authorization: Token settings-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n200' '[]'"

    run netbird_api "GET" "/api/peers"
    assert_success
}

@test "netbird_api uses settings netbird_management_url when env is unset" {
    echo '{"netbird_api_token": "settings-token", "netbird_management_url": "https://management.settings.example.com"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_API_TOKEN
    unset NB_MANAGEMENT_URL

    stub curl \
        "-sS -X GET -H 'Authorization: Token settings-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://management.settings.example.com/api/peers : printf '%s\n200' '[]'"

    run netbird_api "GET" "/api/peers"
    assert_success
}

@test "netbird_api prefers NB_API_TOKEN env over settings" {
    echo '{"netbird_api_token": "settings-token"}' > "$HOME/.config/sandcat/settings.json"
    export NB_API_TOKEN="env-token"
    export NB_MANAGEMENT_URL="https://api.netbird.io"

    stub curl \
        "-sS -X GET -H 'Authorization: Token env-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n200' '[]'"

    run netbird_api "GET" "/api/peers"
    assert_success
}

@test "netbird_api does not export token read from settings" {
    echo '{"netbird_api_token": "settings-token"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_API_TOKEN
    export NB_MANAGEMENT_URL="https://api.netbird.io"

    stub curl \
        "-sS -X GET -H 'Authorization: Token settings-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n200' '[]'"

    netbird_api "GET" "/api/peers"
    [[ -z "${NB_API_TOKEN:-}" ]]
}
