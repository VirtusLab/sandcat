#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"

	COMPOSE_FILE="$BATS_TEST_TMPDIR/compose-all.yml"

	cat >"$COMPOSE_FILE" <<'YAML'
services:
  proxy:
    image: placeholder
  agent:
    image: placeholder
YAML
}

teardown() {
	unstub_all
}

@test "set_project_name inserts name key at top of compose file" {
	set_project_name "$COMPOSE_FILE" "my-project-sandbox"

	run yq '.name' "$COMPOSE_FILE"
	assert_output "my-project-sandbox"

	# Verify name appears before services in the file
	local name_line services_line
	name_line=$(grep -n '^name:' "$COMPOSE_FILE" | head -1 | cut -d: -f1)
	services_line=$(grep -n '^services:' "$COMPOSE_FILE" | head -1 | cut -d: -f1)
	(( name_line < services_line ))
}

@test "set_project_name preserves existing services" {
	set_project_name "$COMPOSE_FILE" "test-sandbox"

	run yq '.services.proxy.image' "$COMPOSE_FILE"
	assert_output "placeholder"

	run yq '.services.agent.image' "$COMPOSE_FILE"
	assert_output "placeholder"
}
