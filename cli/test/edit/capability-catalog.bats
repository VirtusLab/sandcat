#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/edit/capability-catalog
	source "$SCT_LIBEXECDIR/edit/capability-catalog"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer/sandcat"
	CATALOG_FILE="$BATS_TEST_TMPDIR/.devcontainer/sandcat/capability-catalog.json"
	touch "$CATALOG_FILE"
	touch "$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
}

teardown() {
	unstub_all
}

@test "capability-catalog opens project catalog in editor" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_success
}

@test "capability-catalog fails when file missing" {
	rm "$CATALOG_FILE"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_failure
	assert_output --partial "No capability catalog found"
	assert_output --partial "sandcat init --capability"
}

@test "capability-catalog rejects unknown options" {
	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --no-restart
	assert_failure
	assert_output --partial "Unknown option"
}

@test "capability-catalog does not restart by default when file modified" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_success
	refute_output --partial "Restarting capability-runtime"
}

@test "capability-catalog --restart restarts only capability-runtime when modified and running" {
	cat >"$BATS_TEST_TMPDIR/.devcontainer/sandcat/compose-capability.yml" <<'EOF'
services:
  capability-runtime:
    volumes:
      - ./capability-catalog.json:/etc/sandcat/capability-catalog.json:ro
EOF

	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet capability-runtime : echo cid" \
		"compose -f $COMPOSE_FILE restart capability-runtime : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "Catalog was modified. Restarting capability-runtime..."
}

@test "capability-catalog --restart does not restart when file unchanged" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "No changes detected."
}

@test "capability-catalog --restart warns when sidecar is not running" {
	cat >"$BATS_TEST_TMPDIR/.devcontainer/sandcat/compose-capability.yml" <<'EOF'
services:
  capability-runtime:
    volumes:
      - ./capability-catalog.json:/etc/sandcat/capability-catalog.json:ro
EOF

	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet capability-runtime : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "capability-runtime is not running; catalog was saved but not reloaded."
	refute_output --partial "Restarting capability-runtime"
}

@test "capability-catalog warns when catalog bind-mount is missing" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_success
	assert_output --partial "Project catalog is not bind-mounted into capability-runtime"
	assert_output --partial "./capability-catalog.json:/etc/sandcat/capability-catalog.json:ro"
}

@test "capability-catalog --restart skips restart when bind-mount is missing" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "Project catalog is not bind-mounted into capability-runtime"
	refute_output --partial "Restarting capability-runtime"
}

@test "capability-catalog does not rewrite compose-capability.yml" {
	local cap_compose="$BATS_TEST_TMPDIR/.devcontainer/sandcat/compose-capability.yml"
	printf '%s\n' 'services: {}' >"$cap_compose"
	cp "$cap_compose" "$BATS_TEST_TMPDIR/compose-capability.before"

	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_success
	cmp "$BATS_TEST_TMPDIR/compose-capability.before" "$cap_compose"
}

@test "capability-catalog --restart restarts when bind-mount is present" {
	cat >"$BATS_TEST_TMPDIR/.devcontainer/sandcat/compose-capability.yml" <<'EOF'
services:
  capability-runtime:
    volumes:
      - ./capability-catalog.json:/etc/sandcat/capability-catalog.json:ro
EOF

	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet capability-runtime : echo cid" \
		"compose -f $COMPOSE_FILE restart capability-runtime : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "Restarting capability-runtime"
	refute_output --partial "not bind-mounted"
}
