#!/usr/bin/env bats

setup() {
	load test_helper
	EXAMPLE="$SCT_ROOT/../docs/examples/netbird-server"
	WORKDIR="$BATS_TEST_TMPDIR/netbird-server"
	mkdir -p "$WORKDIR"
	cp "$EXAMPLE/start.sh" "$EXAMPLE/config.yaml" "$EXAMPLE/netbird-server.env" "$WORKDIR/"
	# Tracked env may be dirty on a developer machine; tests need empty keys.
	sed -i.bak \
		-e 's/^NETBIRD_RELAY_AUTH_SECRET=.*/NETBIRD_RELAY_AUTH_SECRET=/' \
		-e 's/^NETBIRD_ENCRYPTION_KEY=.*/NETBIRD_ENCRYPTION_KEY=/' \
		"$WORKDIR/netbird-server.env"
}

@test "start.sh --prepare-only generates secrets into config.local.yaml not env" {
	run bash "$WORKDIR/start.sh" --prepare-only
	assert_success
	assert_output --partial "generated:"
	[[ -f "$WORKDIR/config.local.yaml" ]]

	run grep -E '^NETBIRD_RELAY_AUTH_SECRET=.+' "$WORKDIR/netbird-server.env"
	assert_failure
	run grep -E '^NETBIRD_ENCRYPTION_KEY=.+' "$WORKDIR/netbird-server.env"
	assert_failure

	run grep -E '^  authSecret: ".+"' "$WORKDIR/config.local.yaml"
	assert_success
	run grep -E '^    encryptionKey: ".+"' "$WORKDIR/config.local.yaml"
	assert_success
	run grep -F 'authSecret: ""' "$WORKDIR/config.local.yaml"
	assert_failure
	local mode
	mode=$(stat -c '%a' "$WORKDIR/config.local.yaml" 2>/dev/null \
		|| stat -f '%OLp' "$WORKDIR/config.local.yaml")
	assert_equal "$mode" "600"
}

@test "start.sh --prepare-only reuses existing env secrets" {
	sed -i.bak \
		-e 's/^NETBIRD_RELAY_AUTH_SECRET=.*/NETBIRD_RELAY_AUTH_SECRET=relay-test-secret/' \
		-e 's/^NETBIRD_ENCRYPTION_KEY=.*/NETBIRD_ENCRYPTION_KEY=encrypt-test-secret/' \
		"$WORKDIR/netbird-server.env"

	run bash "$WORKDIR/start.sh" --prepare-only
	assert_success
	assert_output --partial "reusing secrets"

	run grep -F 'NETBIRD_RELAY_AUTH_SECRET=relay-test-secret' "$WORKDIR/netbird-server.env"
	assert_success
	run grep -F 'authSecret: "relay-test-secret"' "$WORKDIR/config.local.yaml"
	assert_success
	run grep -F 'encryptionKey: "encrypt-test-secret"' "$WORKDIR/config.local.yaml"
	assert_success
}

@test "start.sh --secrets-from injects YAML keys without writing env" {
	cat >"$WORKDIR/existing.yaml" <<'YAML'
server:
  authSecret: "from-existing-relay"
  store:
    encryptionKey: "from-existing-store"
YAML

	run bash "$WORKDIR/start.sh" --prepare-only --secrets-from "$WORKDIR/existing.yaml"
	assert_success
	assert_output --partial "not written to netbird-server.env"

	run grep -F 'authSecret: "from-existing-relay"' "$WORKDIR/config.local.yaml"
	assert_success
	run grep -F 'encryptionKey: "from-existing-store"' "$WORKDIR/config.local.yaml"
	assert_success

	run grep -F 'from-existing-relay' "$WORKDIR/netbird-server.env"
	assert_failure
	run grep -E '^NETBIRD_RELAY_AUTH_SECRET=$' "$WORKDIR/netbird-server.env"
	assert_success
}

@test "compose mounts config.local.yaml not tracked config.yaml placeholders" {
	run grep -F './config.local.yaml:/etc/netbird/config.yaml' "$EXAMPLE/docker-compose.yml"
	assert_success
	run grep -F './config.yaml:/etc/netbird/config.yaml' "$EXAMPLE/docker-compose.yml"
	assert_failure
}

@test "example gitignores config.local.yaml" {
	run grep -F 'docs/examples/netbird-server/config.local.yaml' "$SCT_ROOT/../.gitignore"
	assert_success
}

@test "start.sh expands empty COMPOSE_ARGS without set -u failure" {
	run grep -F 'COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"' "$EXAMPLE/start.sh"
	assert_success
}
