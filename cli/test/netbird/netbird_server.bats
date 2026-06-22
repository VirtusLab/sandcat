#!/usr/bin/env bats

setup() {
	load test_helper

	NETBIRD_CMD="$SCT_LIBEXECDIR/netbird/netbird"
	export HOME="$BATS_TEST_TMPDIR/home"
	SCT_HOME_DIR="$HOME/.config/sandcat"
	mkdir -p "$SCT_HOME_DIR/netbird-server"
	touch "$SCT_HOME_DIR/netbird-server/docker-compose.yml"
	touch "$SCT_HOME_DIR/netbird-server/netbird-server.env"
}

teardown() {
	unstub_all
}

@test "netbird server start runs docker compose up -d" {
	stub docker \
		"compose -f $SCT_HOME_DIR/netbird-server/docker-compose.yml --env-file $SCT_HOME_DIR/netbird-server/netbird-server.env up -d : :"

	run bash "$NETBIRD_CMD" server start
	assert_success
}

@test "netbird server start forwards extra compose args" {
	stub docker \
		"compose -f $SCT_HOME_DIR/netbird-server/docker-compose.yml --env-file $SCT_HOME_DIR/netbird-server/netbird-server.env up -d --force-recreate netbird-server : :"

	run bash "$NETBIRD_CMD" server start --force-recreate netbird-server
	assert_success
}

@test "netbird server stop runs docker compose down" {
	stub docker \
		"compose -f $SCT_HOME_DIR/netbird-server/docker-compose.yml --env-file $SCT_HOME_DIR/netbird-server/netbird-server.env down : :"

	run bash "$NETBIRD_CMD" server stop
	assert_success
}

@test "netbird server status runs docker compose ps" {
	stub docker \
		"compose -f $SCT_HOME_DIR/netbird-server/docker-compose.yml --env-file $SCT_HOME_DIR/netbird-server/netbird-server.env ps : echo 'NAME STATUS'"

	run bash "$NETBIRD_CMD" server status
	assert_success
	assert_output --partial "NAME STATUS"
}

@test "netbird server start fails when template is not provisioned" {
	rm -rf "$SCT_HOME_DIR/netbird-server"

	run bash "$NETBIRD_CMD" server start
	assert_failure
	assert_output --partial "not provisioned"
	assert_output --partial "sandcat init --netbird --netbird-server new"
}

@test "netbird server with unknown subcommand prints usage" {
	run bash "$NETBIRD_CMD" server bogus
	assert_failure
	assert_output --partial "Unknown server subcommand"
	assert_output --partial "Usage"
}

@test "sandcat netbird server start routes through module dispatcher" {
	printf 'test\n' > "$SCT_ROOT/.version"
	stub docker \
		"compose -f $SCT_HOME_DIR/netbird-server/docker-compose.yml --env-file $SCT_HOME_DIR/netbird-server/netbird-server.env up -d : :"

	run bash "$SCT_ROOT/bin/sandcat" netbird server start
	assert_success
}
