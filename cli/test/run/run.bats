#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../lib/volume.bash
	source "$SCT_LIBDIR/volume.bash"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	cat > "$COMPOSE_FILE" <<-'EOF'
		name: myproject-sandbox
		services:
		  agent:
		    build:
		      context: .
		      dockerfile: Dockerfile.app
	EOF
}

teardown() {
	unstub_all
}

# --- warn_stale_home_volume ---

@test "no warning when volume does not exist (first run)" {
	stub docker \
		"volume inspect myproject-sandbox_agent-home : exit 1"

	run warn_stale_home_volume "$COMPOSE_FILE"
	assert_success
	refute_output --partial "volume"
}

@test "warning when image is much newer than volume" {
	stub docker \
		"volume inspect myproject-sandbox_agent-home : :" \
		"volume inspect --format {{.CreatedAt}} myproject-sandbox_agent-home : echo '2024-01-15T10:00:00Z'" \
		"image inspect --format {{.Created}} myproject-sandbox-agent : echo '2024-06-20T14:30:00.123456789Z'"

	run --separate-stderr warn_stale_home_volume "$COMPOSE_FILE"
	assert_success
	assert_stderr --partial "agent image was rebuilt"
	assert_stderr --partial "sandcat compose down && docker volume rm myproject-sandbox_agent-home"
}

@test "no warning when image is newer than volume within tolerance" {
	# Compose creates named volumes before building images, so on first
	# install the image is naturally ~20s newer than the volume.
	stub docker \
		"volume inspect myproject-sandbox_agent-home : :" \
		"volume inspect --format {{.CreatedAt}} myproject-sandbox_agent-home : echo '2024-01-15T10:00:00Z'" \
		"image inspect --format {{.Created}} myproject-sandbox-agent : echo '2024-01-15T10:00:30Z'"

	run warn_stale_home_volume "$COMPOSE_FILE"
	assert_success
	refute_output --partial "rebuilt"
}

@test "no warning when volume is newer than image" {
	stub docker \
		"volume inspect myproject-sandbox_agent-home : :" \
		"volume inspect --format {{.CreatedAt}} myproject-sandbox_agent-home : echo '2024-06-20T14:30:00Z'" \
		"image inspect --format {{.Created}} myproject-sandbox-agent : echo '2024-01-15T10:00:00.123456789Z'"

	run warn_stale_home_volume "$COMPOSE_FILE"
	assert_success
	refute_output --partial "rebuilt"
}

@test "no warning when image does not exist" {
	stub docker \
		"volume inspect myproject-sandbox_agent-home : :" \
		"volume inspect --format {{.CreatedAt}} myproject-sandbox_agent-home : echo '2024-01-15T10:00:00Z'" \
		"image inspect --format {{.Created}} myproject-sandbox-agent : exit 1"

	run warn_stale_home_volume "$COMPOSE_FILE"
	assert_success
	refute_output --partial "rebuilt"
}

@test "no warning when volume inspect for timestamp fails" {
	stub docker \
		"volume inspect myproject-sandbox_agent-home : :" \
		"volume inspect --format {{.CreatedAt}} myproject-sandbox_agent-home : exit 1"

	run warn_stale_home_volume "$COMPOSE_FILE"
	assert_success
	refute_output --partial "rebuilt"
}

@test "no warning when compose file has no project name" {
	cat > "$COMPOSE_FILE" <<-'EOF'
		services:
		  agent:
		    build:
		      context: .
	EOF

	run warn_stale_home_volume "$COMPOSE_FILE"
	assert_success
	refute_output --partial "volume"
}
