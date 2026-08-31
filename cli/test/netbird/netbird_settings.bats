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

@test "export_netbird_compose_env exports API token from user settings" {
    echo '{"netbird_api_token": "api-token-456"}' > "$HOME/.config/sandcat/settings.json"
    unset NB_API_TOKEN

    export_netbird_compose_env

    [[ "$NB_API_TOKEN" == "api-token-456" ]]
}

@test "export_netbird_compose_env does not override existing NB_API_TOKEN" {
    echo '{"netbird_api_token": "from-settings"}' > "$HOME/.config/sandcat/settings.json"
    export NB_API_TOKEN="from-env"

    export_netbird_compose_env

    [[ "$NB_API_TOKEN" == "from-env" ]]
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

@test "netbird_detect_docker_host_ip extracts the host LAN address on Linux" {
    stub uname "-s : echo Linux"
    stub ip "-4 route get 1.1.1.1 : echo '1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.50 uid 1000'"

    run netbird_detect_docker_host_ip
    assert_success
    assert_output "192.168.1.50"
}

@test "netbird_detect_docker_host_ip prints nothing when no IPv4 is found" {
    stub uname "-s : echo Linux"
    stub ip "-4 route get 1.1.1.1 : echo ''"

    run netbird_detect_docker_host_ip
    assert_success
    assert_output ""
}

@test "netbird_enrollment_url_uses_host_bypass for literal IPv4 enrollment URL" {
    run netbird_enrollment_url_uses_host_bypass "http://192.168.5.2:33073"
    assert_success
}

@test "netbird_enrollment_url_uses_host_bypass is false for hostname enrollment URL" {
    run netbird_enrollment_url_uses_host_bypass "https://netbird.example.com"
    assert_failure
}
