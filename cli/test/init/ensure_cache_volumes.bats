#!/usr/bin/env bats

setup() {
	load test_helper
	SCRIPT="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/ensure-cache-volumes.sh"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/compose-all.yml"
	cat > "$COMPOSE_FILE" <<'YAML'
services:
  agent:
    volumes:
      - sandcat-cache-maven:/home/vscode/.m2/repository
      - sandcat-cache-gradle:/home/vscode/.gradle/caches
volumes:
  sandcat-cache-maven:
    external: true
    name: sandcat-cache-maven
  sandcat-cache-gradle:
    external: true
    name: sandcat-cache-gradle
  other-shared:
    external: true
    name: user-added-volume
YAML
}

teardown() {
	unstub_all
}

@test "creates each sandcat-cache-* external volume with the shared-cache label" {
	stub docker \
		"volume create --label sandcat-shared-cache=true sandcat-cache-maven : :" \
		"volume create --label sandcat-shared-cache=true sandcat-cache-gradle : :"

	run bash "$SCRIPT" "$COMPOSE_FILE"
	assert_success
	assert_output ""
}

@test "does nothing when the compose file declares no cache volumes" {
	echo "services: {}" > "$COMPOSE_FILE"
	stub docker

	run bash "$SCRIPT" "$COMPOSE_FILE"
	assert_success
}

@test "exits 0 when the compose file is missing" {
	run bash "$SCRIPT" "$BATS_TEST_TMPDIR/missing.yml"
	assert_success
}

@test "defaults to compose-all.yml two levels above the script" {
	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer/sandcat/scripts"
	cp "$SCRIPT" "$BATS_TEST_TMPDIR/.devcontainer/sandcat/scripts/"
	cp "$COMPOSE_FILE" "$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	stub docker \
		"volume create --label sandcat-shared-cache=true sandcat-cache-maven : :" \
		"volume create --label sandcat-shared-cache=true sandcat-cache-gradle : :"

	run bash "$BATS_TEST_TMPDIR/.devcontainer/sandcat/scripts/ensure-cache-volumes.sh"
	assert_success
}
