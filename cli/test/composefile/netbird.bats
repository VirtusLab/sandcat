#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/composefile.bash"
	# shellcheck source=netbird.bash
	source "$SCT_LIBDIR/netbird.bash"

	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/sandcat"

	COMPOSE_FILE="$BATS_TEST_TMPDIR/compose-proxy.yml"
    cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/netbird.env" "$BATS_TEST_TMPDIR/netbird.env"
    # Minimal template that mirrors the real compose-proxy.yml: mitmproxy uses
    # image: initially; enable_netbird() switches it to build:.
    cat >"$COMPOSE_FILE" <<'YAML'
services:
  wg-client:
    build:
      context: .
      dockerfile: Dockerfile.wg-client
    cap_add:
      - NET_ADMIN
    # Real compose-proxy.yml also sets this on wg-client; enable_netbird must
    # still add it to mitmproxy (file-wide grep would false-positive here).
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
  mitmproxy:
    image: mitmproxy/mitmproxy:latest
    entrypoint: ["sh", "-c", "rm -f dns.conf && exec docker-entrypoint.sh \"$@\"", "sh"]
    command: mitmweb --mode wireguard
YAML
}

teardown() {
    unstub_all
}

@test "enable_netbird adds NB_SETUP_KEY to mitmproxy environment" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    yq -e '.services.mitmproxy.environment[] | select(. == "NB_SETUP_KEY")' "$COMPOSE_FILE"
}

@test "enable_netbird keeps secret-provider token when adding NB_SETUP_KEY" {
    apply_secret_provider "$COMPOSE_FILE" "protonpass"
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    yq -e '.services.mitmproxy.environment[] | select(. == "NB_SETUP_KEY")' "$COMPOSE_FILE"
    yq -e '.services.mitmproxy.environment[] | select(. == "PROTON_PASS_PERSONAL_ACCESS_TOKEN")' "$COMPOSE_FILE"
    run yq -r '.services.mitmproxy.build.dockerfile' "$COMPOSE_FILE"
    assert_output "Dockerfile.mitmproxy"
}

@test "enable_netbird keeps the secret-provider image as the build base" {
    # init order: apply_secret_provider pins image:, then enable_netbird
    # converts to build:. Dropping the image here would silently remove
    # pass-cli from the NetBird-enabled proxy.
    apply_secret_provider "$COMPOSE_FILE" "protonpass"
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq -r '.services.mitmproxy.build.args.BASE_IMAGE' "$COMPOSE_FILE"
    assert_output "ghcr.io/virtuslab/sandcat-mitmproxy-pass:latest"
}

@test "enable_netbird keeps NetBird build args alongside BASE_IMAGE" {
    apply_secret_provider "$COMPOSE_FILE" "1password"
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq -r '.services.mitmproxy.build.args.BASE_IMAGE' "$COMPOSE_FILE"
    assert_output "ghcr.io/virtuslab/sandcat-mitmproxy-op:latest"
    yq -e '.services.mitmproxy.build.args | has("NETBIRD_VERSION")' "$COMPOSE_FILE"
}

@test "enable_netbird carries the stock image as BASE_IMAGE without a provider" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq -r '.services.mitmproxy.build.args.BASE_IMAGE' "$COMPOSE_FILE"
    assert_output "mitmproxy/mitmproxy:latest"
}

@test "enable_netbird removes stale NB_SETUP_KEY from wg-client" {
    yq -i '
      .services."wg-client".environment = [
        "NB_SETUP_KEY",
        "NB_MANAGEMENT_URL=http://192.168.5.2:33073",
        "NB_USE_LEGACY_ROUTING=true"
      ]
    ' "$COMPOSE_FILE"

    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '[.services."wg-client".environment[]? | select(. == "NB_SETUP_KEY" or test("^NB_MANAGEMENT_URL=") or test("^NB_USE_LEGACY_ROUTING="))] | length' "$COMPOSE_FILE"
    assert_output "0"
    yq -e '.services.mitmproxy.environment[] | select(. == "NB_SETUP_KEY")' "$COMPOSE_FILE"
}

@test "enable_netbird is idempotent" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '[.services.mitmproxy.environment[] | select(. == "NB_SETUP_KEY")] | length' "$COMPOSE_FILE"
    assert_output "1"
    run yq '[.services.mitmproxy.extra_hosts[] | select(. == "host.docker.internal:172.17.0.1")] | length' "$COMPOSE_FILE"
    assert_output "1"
}

@test "enable_netbird replaces host-gateway extra_hosts with docker0" {
    yq -i '.services.mitmproxy.extra_hosts = ["host.docker.internal:host-gateway"]' "$COMPOSE_FILE"
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '[.services.mitmproxy.extra_hosts[] | select(. == "host.docker.internal:host-gateway")] | length' "$COMPOSE_FILE"
    assert_output "0"
    run yq '[.services.mitmproxy.extra_hosts[] | select(. == "host.docker.internal:172.17.0.1")] | length' "$COMPOSE_FILE"
    assert_output "1"
}

@test "enable_netbird switches mitmproxy from image to build" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq -r '.services.mitmproxy.build.dockerfile' "$COMPOSE_FILE"
    assert_output "Dockerfile.mitmproxy"

    run yq '(.services.mitmproxy.image // "null")' "$COMPOSE_FILE"
    assert_output "null"
}

@test "enable_netbird removes mitmproxy entrypoint override" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '(.services.mitmproxy.entrypoint // "null")' "$COMPOSE_FILE"
    assert_output "null"
}

@test "enable_netbird adds NET_ADMIN to mitmproxy" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    yq -e '.services.mitmproxy.cap_add[] | select(. == "NET_ADMIN")' "$COMPOSE_FILE"
}

@test "enable_netbird adds src_valid_mark sysctl to mitmproxy" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    yq -e '.services.mitmproxy.sysctls[] | select(. == "net.ipv4.conf.all.src_valid_mark=1")' "$COMPOSE_FILE"
}

@test "enable_netbird adds src_valid_mark even when wg-client already has it" {
    # setup() already puts src_valid_mark on wg-client; this asserts the
    # regression that a file-wide grep would skip mitmproxy.
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '[.services.mitmproxy.sysctls[] | select(test("src_valid_mark"))] | length' "$COMPOSE_FILE"
    assert_output "1"
}

@test "enable_netbird does not modify wg-client" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '(.services."wg-client".environment // "null")' "$COMPOSE_FILE"
    assert_output "null"
}

@test "enable_netbird adds NB_MANAGEMENT_URL when provided" {
    local management_url="https://netbird.internal"
    enable_netbird "$COMPOSE_FILE" "$management_url" "test-proxy"

    run yq -r '.services.mitmproxy.environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=$management_url"
}

@test "enable_netbird with management URL is idempotent" {
    local management_url="https://netbird.internal"
    enable_netbird "$COMPOSE_FILE" "$management_url" "test-proxy"
    enable_netbird "$COMPOSE_FILE" "$management_url" "test-proxy"

    run yq '[.services.mitmproxy.environment[] | select(. == "NB_SETUP_KEY")] | length' "$COMPOSE_FILE"
    assert_output "1"

    run yq '[.services.mitmproxy.environment[] | select(test("^NB_MANAGEMENT_URL="))] | length' "$COMPOSE_FILE"
    assert_output "1"
}

@test "enable_netbird updates existing NB_MANAGEMENT_URL when provided" {
    enable_netbird "$COMPOSE_FILE" "https://old.example.com" "test-proxy"
    enable_netbird "$COMPOSE_FILE" "https://new.example.com" "test-proxy"

    run yq -r '.services.mitmproxy.environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=https://new.example.com"
}

@test "enable_netbird with empty management URL does not add NB_MANAGEMENT_URL" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '[.services.mitmproxy.environment[] | select(test("^NB_MANAGEMENT_URL="))] | length' "$COMPOSE_FILE"
    assert_output "0"
}

@test "enable_netbird warns when localhost has no container-reachable enrollment URL" {
    run enable_netbird "$COMPOSE_FILE" "http://localhost:33073" "test-proxy"

    assert_success
    assert_output --partial "no NB_MANAGEMENT_URL"
    assert_output --partial "netbird_enrollment_management_url"
}

@test "enable_netbird omits NB_MANAGEMENT_URL for localhost without enrollment URL" {
    enable_netbird "$COMPOSE_FILE" "http://localhost:33073" "test-proxy"

    run yq '[.services.mitmproxy.environment[] | select(test("^NB_MANAGEMENT_URL="))] | length' "$COMPOSE_FILE"
    assert_output "0"
}

@test "enable_netbird uses explicit enrollment URL for local self-hosted" {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/sandcat"
    echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"

    enable_netbird "$COMPOSE_FILE" "http://localhost:33073" "test-proxy"

    run yq -r '.services.mitmproxy.environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=http://192.168.5.2:33073"
}

@test "enable_netbird sets NB_USE_LEGACY_ROUTING for host IP enrollment URL" {
    export HOME="$BATS_TEST_TMPDIR/home-enrollment"
    mkdir -p "$HOME/.config/sandcat"
    echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"

    enable_netbird "$COMPOSE_FILE" "http://localhost:33073" "test-proxy"

    run yq -r '.services.mitmproxy.environment[] | select(. == "NB_USE_LEGACY_ROUTING=true")' "$COMPOSE_FILE"
    assert_output "NB_USE_LEGACY_ROUTING=true"
}

@test "enable_netbird does not rewrite remote management URL" {
    enable_netbird "$COMPOSE_FILE" "https://netbird.example.com" "test-proxy"

    run yq -r '.services.mitmproxy.environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=https://netbird.example.com"

    run yq '[.services.mitmproxy.environment[] | select(. == "NB_USE_LEGACY_ROUTING=true")] | length' "$COMPOSE_FILE"
    assert_output "0"
}

@test "enable_netbird injects NetBird build args into mitmproxy" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    # shellcheck disable=SC1091
    source "$BATS_TEST_TMPDIR/netbird.env"
    run yq -r '.services.mitmproxy.build.args.NETBIRD_VERSION' "$COMPOSE_FILE"
    assert_output "$NETBIRD_VERSION"
    run yq -r '.services.mitmproxy.build.args.NETBIRD_SHA256_AMD64' "$COMPOSE_FILE"
    assert_output "$NETBIRD_SHA256_AMD64"
}

@test "enable_netbird adds NETBIRD_DNS_DOMAIN to mitmproxy environment" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    yq -e '.services.mitmproxy.environment[] | select(test("^NETBIRD_DNS_DOMAIN="))' "$COMPOSE_FILE"
}

@test "enable_netbird NETBIRD_DNS_DOMAIN defaults to netbird.selfhosted" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq -r '.services.mitmproxy.environment[] | select(test("^NETBIRD_DNS_DOMAIN="))' "$COMPOSE_FILE"
    assert_output "NETBIRD_DNS_DOMAIN=netbird.selfhosted"
}

@test "enable_netbird NETBIRD_DNS_DOMAIN is idempotent" {
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"
    enable_netbird "$COMPOSE_FILE" "" "test-proxy"

    run yq '[.services.mitmproxy.environment[] | select(test("^NETBIRD_DNS_DOMAIN="))] | length' "$COMPOSE_FILE"
    assert_output "1"
}

@test "enable_netbird sets NB_PEER_NAME on mitmproxy from argument" {
	enable_netbird "$COMPOSE_FILE" "" "myapp-sandbox-proxy"

	run yq -r '.services.mitmproxy.environment[] | select(test("^NB_PEER_NAME="))' "$COMPOSE_FILE"
	assert_output "NB_PEER_NAME=myapp-sandbox-proxy"
}

@test "enable_netbird adds NB_API_TOKEN passthrough to mitmproxy" {
	enable_netbird "$COMPOSE_FILE" "" "myapp-sandbox-proxy"

	yq -e '.services.mitmproxy.environment[] | select(. == "NB_API_TOKEN")' "$COMPOSE_FILE"
}

@test "enable_netbird mounts named volume on /var/lib/netbird" {
	enable_netbird "$COMPOSE_FILE" "" "myapp-sandbox-proxy"

	yq -e '.services.mitmproxy.volumes[] | select(. == "netbird-mitmproxy-state:/var/lib/netbird")' "$COMPOSE_FILE"
	yq -e '.volumes | has("netbird-mitmproxy-state")' "$COMPOSE_FILE"
}

@test "enable_netbird copies the peer lifecycle script into the build context" {
	mkdir -p "$BATS_TEST_TMPDIR/scripts"

	enable_netbird "$COMPOSE_FILE" "" "myapp-sandbox-proxy"

	run cmp \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/netbird-peer-lifecycle.sh" \
		"$BATS_TEST_TMPDIR/scripts/netbird-peer-lifecycle.sh"
	assert_success
}

@test "enable_netbird fails when peer name argument is empty" {
	run enable_netbird "$COMPOSE_FILE" "" ""
	assert_failure
	assert_output --partial "peer name"
}

@test "apply_netbird_build_args injects version and checksum build args" {
    apply_netbird_build_args "$COMPOSE_FILE"

    # shellcheck disable=SC1091
    source "$BATS_TEST_TMPDIR/netbird.env"
    run yq -r '.services."wg-client".build.args.NETBIRD_VERSION' "$COMPOSE_FILE"
    assert_output "$NETBIRD_VERSION"
    run yq -r '.services."wg-client".build.args.NETBIRD_SHA256_AMD64' "$COMPOSE_FILE"
    assert_output "$NETBIRD_SHA256_AMD64"
    run yq -r '.services."wg-client".build.args.NETBIRD_SHA256_ARM64' "$COMPOSE_FILE"
    assert_output "$NETBIRD_SHA256_ARM64"
}

@test "apply_netbird_build_args is idempotent" {
    apply_netbird_build_args "$COMPOSE_FILE"
    apply_netbird_build_args "$COMPOSE_FILE"

    run yq '.services."wg-client".build.args | length' "$COMPOSE_FILE"
    assert_output "3"
}
