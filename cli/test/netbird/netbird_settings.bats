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

@test "provision_netbird_server_template copies template and skips when already provisioned" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR/netbird-server"
    echo "services: {}" > "$SCT_TEMPLATEDIR/netbird-server/docker-compose.yml"
    echo "NETBIRD_SERVER_VERSION=0.1.0" > "$SCT_TEMPLATEDIR/netbird-server/netbird-server.env"
    echo "{}" > "$SCT_TEMPLATEDIR/netbird-server/management.json"
    echo "listening-port=3478" > "$SCT_TEMPLATEDIR/netbird-server/turnserver.conf"
    echo "# template" > "$SCT_TEMPLATEDIR/netbird-server/README.md"

    provision_netbird_server_template
    [[ -d "$HOME/.config/sandcat/netbird-server" ]]
    [[ -f "$HOME/.config/sandcat/netbird-server/docker-compose.yml" ]]
    [[ "$(cat "$HOME/.config/sandcat/netbird-server/docker-compose.yml")" == "services: {}" ]]

    run provision_netbird_server_template
    assert_success
    assert_output --partial "skipping"
}

@test "provision_netbird_server_template skips when destination exists as file" {
    export SCT_TEMPLATEDIR="$BATS_TEST_TMPDIR/templates"
    mkdir -p "$SCT_TEMPLATEDIR/netbird-server"
    echo "services: {}" > "$SCT_TEMPLATEDIR/netbird-server/docker-compose.yml"
    echo "NETBIRD_SERVER_VERSION=0.1.0" > "$SCT_TEMPLATEDIR/netbird-server/netbird-server.env"
    echo "{}" > "$SCT_TEMPLATEDIR/netbird-server/management.json"
    echo "listening-port=3478" > "$SCT_TEMPLATEDIR/netbird-server/turnserver.conf"
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
    echo "{}" > "$SCT_TEMPLATEDIR/netbird-server/management.json"
    echo "# template" > "$SCT_TEMPLATEDIR/netbird-server/README.md"

    run provision_netbird_server_template
    assert_failure
    assert_output --partial "missing turnserver.conf"
}

@test "netbird_api reads netbird_api_token from user settings" {
    echo '{"netbird_api_token": "settings-token"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_API_TOKEN
    export NB_MANAGEMENT_URL="https://api.netbird.io"

    stub curl \
        "-sS -f -X GET -H 'Authorization: Token settings-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[]'"

    run netbird_api "GET" "/api/peers"
    assert_success
}

@test "netbird_api uses settings netbird_management_url when env is unset" {
    echo '{"netbird_api_token": "settings-token", "netbird_management_url": "https://management.settings.example.com"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_API_TOKEN
    unset NB_MANAGEMENT_URL

    stub curl \
        "-sS -f -X GET -H 'Authorization: Token settings-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://management.settings.example.com/api/peers : echo '[]'"

    run netbird_api "GET" "/api/peers"
    assert_success
}

@test "netbird_api prefers NB_API_TOKEN env over settings" {
    echo '{"netbird_api_token": "settings-token"}' > "$HOME/.config/sandcat/settings.json"
    export NB_API_TOKEN="env-token"
    export NB_MANAGEMENT_URL="https://api.netbird.io"

    stub curl \
        "-sS -f -X GET -H 'Authorization: Token env-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[]'"

    run netbird_api "GET" "/api/peers"
    assert_success
}
