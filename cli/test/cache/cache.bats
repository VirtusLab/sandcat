#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/cache.bash
	source "$SCT_LIBDIR/cache.bash"
}

teardown() {
	unstub_all 2>/dev/null || true
}

# --- helpers -----------------------------------------------------------------

@test "sct_cache_format_bytes formats bytes/KB/MB/GB" {
	run sct_cache_format_bytes 0
	assert_output "0 B"
	run sct_cache_format_bytes 512
	assert_output "512 B"
	run sct_cache_format_bytes 2048
	assert_output "2.0 KB"
	run sct_cache_format_bytes $((5 * 1024 * 1024))
	assert_output "5.0 MB"
	run sct_cache_format_bytes $((2 * 1024 * 1024 * 1024))
	assert_output "2.0 GB"
}

@test "sct_cache_volume_names filters by shared-cache label" {
	stub docker \
		"volume ls -q --filter label=sandcat-shared-cache=true : printf 'sandcat-cache-maven\nsandcat-cache-coursier\n'"

	run sct_cache_volume_names
	assert_success
	assert_line --index 0 "sandcat-cache-coursier"
	assert_line --index 1 "sandcat-cache-maven"
}

# --- cache list --------------------------------------------------------------

@test "cache list — empty state prints the lazy-create hint" {
	stub docker \
		"volume ls -q --filter label=sandcat-shared-cache=true : :"

	run "$SCT_LIBEXECDIR/cache/list"
	assert_success
	assert_output --partial "No sandcat shared-cache volumes"
	assert_output --partial "lazily on the first"
}

@test "cache list — prints one row per volume with size + files + user" {
	# One volume, one running container using it, ~2.5 KB, 5 files.
	stub docker \
		"volume ls -q --filter label=sandcat-shared-cache=true : echo sandcat-cache-maven" \
		"run --rm -v sandcat-cache-maven:/mnt alpine du -sb /mnt : printf '2560\t/mnt\n'" \
		"run --rm -v sandcat-cache-maven:/mnt alpine sh -c 'find /mnt -type f 2>/dev/null | wc -l' : echo '     5'" \
		"ps -a --filter volume=sandcat-cache-maven --format {{.Names}} : echo agent-A"

	run "$SCT_LIBEXECDIR/cache/list"
	assert_success
	assert_output --partial "VOLUME"
	assert_output --partial "sandcat-cache-maven"
	assert_output --partial "2.5 KB"
	assert_output --partial "agent-A"
	assert_output --partial "2.5 KB total"
}

@test "cache list — no user column shows em-dash" {
	stub docker \
		"volume ls -q --filter label=sandcat-shared-cache=true : echo sandcat-cache-ivy" \
		"run --rm -v sandcat-cache-ivy:/mnt alpine du -sb /mnt : printf '0\t/mnt\n'" \
		"run --rm -v sandcat-cache-ivy:/mnt alpine sh -c 'find /mnt -type f 2>/dev/null | wc -l' : echo '0'" \
		"ps -a --filter volume=sandcat-cache-ivy --format {{.Names}} : :"

	run "$SCT_LIBEXECDIR/cache/list"
	assert_success
	assert_output --partial "—"
}

# --- cache size --------------------------------------------------------------

@test "cache size — 0 B when no volumes" {
	stub docker \
		"volume ls -q --filter label=sandcat-shared-cache=true : :"

	run "$SCT_LIBEXECDIR/cache/size"
	assert_success
	assert_output --partial "0 B (no shared-cache volumes"
}

@test "cache size — sums bytes across all volumes" {
	# Two volumes, ~1 MB + ~2 MB = ~3 MB.
	stub docker \
		"volume ls -q --filter label=sandcat-shared-cache=true : printf 'sandcat-cache-maven\nsandcat-cache-coursier\n'" \
		"run --rm -v sandcat-cache-coursier:/mnt alpine du -sb /mnt : printf '1048576\t/mnt\n'" \
		"run --rm -v sandcat-cache-maven:/mnt alpine du -sb /mnt : printf '2097152\t/mnt\n'"

	run "$SCT_LIBEXECDIR/cache/size"
	assert_success
	assert_output --partial "3.0 MB across 2 volume(s)"
}

# --- cache rm ----------------------------------------------------------------

@test "cache rm — refuses when volume in use unless --force" {
	# ps returns a container name → in-use → abort before any docker rm.
	stub docker \
		"ps -a --filter volume=sandcat-cache-maven --format {{.Names}} : echo running-agent-1"

	run "$SCT_LIBEXECDIR/cache/rm" --yes sandcat-cache-maven
	assert_failure
	assert_output --partial "in use by: running-agent-1"
	assert_output --partial "--force"
}

@test "cache rm — deletes the named volume when free" {
	stub docker \
		"ps -a --filter volume=sandcat-cache-maven --format {{.Names}} : :" \
		"volume rm sandcat-cache-maven : echo sandcat-cache-maven"

	run "$SCT_LIBEXECDIR/cache/rm" --yes sandcat-cache-maven
	assert_success
	assert_output --partial "sandcat-cache-maven"
}

@test "cache rm --all — deletes every discovered volume" {
	stub docker \
		"volume ls -q --filter label=sandcat-shared-cache=true : printf 'sandcat-cache-maven\nsandcat-cache-coursier\n'" \
		"ps -a --filter volume=sandcat-cache-coursier --format {{.Names}} : :" \
		"ps -a --filter volume=sandcat-cache-maven --format {{.Names}} : :" \
		"volume rm sandcat-cache-coursier sandcat-cache-maven : printf 'sandcat-cache-coursier\nsandcat-cache-maven\n'"

	run "$SCT_LIBEXECDIR/cache/rm" --all --yes
	assert_success
	assert_output --partial "sandcat-cache-coursier"
	assert_output --partial "sandcat-cache-maven"
}

@test "cache rm --force skips in-use check" {
	# No ps call because --force bypasses; docker volume rm --force runs.
	stub docker \
		"volume rm --force sandcat-cache-maven : echo sandcat-cache-maven"

	run "$SCT_LIBEXECDIR/cache/rm" --force --yes sandcat-cache-maven
	assert_success
}

@test "cache rm — rejects mixing --all with a volume name" {
	run "$SCT_LIBEXECDIR/cache/rm" --all sandcat-cache-maven
	assert_failure
	assert_output --partial "Use --all OR a volume name"
}

@test "cache rm — no args prints usage" {
	run "$SCT_LIBEXECDIR/cache/rm"
	assert_failure
	assert_output --partial "Usage:"
}
