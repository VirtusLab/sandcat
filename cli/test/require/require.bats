#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper

	# Not BATS_MOCK_BINDIR ($BATS_TEST_TMPDIR/bin): unstub_all treats every
	# file there as a bats-mock stub.
	YQ_BIN="$BATS_TEST_TMPDIR/yq-bin"
	mkdir -p "$YQ_BIN"
	export YQ_LOG="$BATS_TEST_TMPDIR/yq.log"
	: >"$YQ_LOG"
	# Prepend so type -P yq finds the fixture, not a host binary.
	export PATH="$YQ_BIN:$PATH"
}

teardown() {
	unstub_all
}

write_yq() {
	local body=$1
	# Fixture inherits exported nounset; never assume "$1" is set.
	printf '%s\n' '#!/bin/bash' "$body" >"$YQ_BIN/yq"
	chmod +x "$YQ_BIN/yq"
}

@test "require yq probes PATH yq --version, not the shell wrapper" {
	write_yq '
echo "called $*" >> "${YQ_LOG:?}"
if [[ "${1-}" == "--version" ]]; then
	echo "yq (https://github.com/mikefarah/yq/) version v4.44.3"
	exit 0
fi
exit 1
'
	# shellcheck source=../../lib/require.bash
	source "$SCT_LIBDIR/require.bash"

	# The retry wrapper would report this as the version string and fail
	# the mikefarah check. require must call `command yq`.
	yq() { echo "python yq 3.0.0"; }

	require yq
}

@test "require yq checks mikefarah version only once" {
	write_yq '
echo "called $*" >> "${YQ_LOG:?}"
if [[ "${1-}" == "--version" ]]; then
	echo "yq (https://github.com/mikefarah/yq/) version v4.44.3"
	exit 0
fi
exit 1
'
	# shellcheck source=../../lib/require.bash
	source "$SCT_LIBDIR/require.bash"

	require yq
	require yq
	require yq

	run grep -c . "$YQ_LOG"
	assert_output "1"
	run cat "$YQ_LOG"
	assert_output "called --version"
}

@test "require yq cache survives re-sourcing require.bash" {
	write_yq '
echo "called $*" >> "${YQ_LOG:?}"
if [[ "${1-}" == "--version" ]]; then
	echo "yq (https://github.com/mikefarah/yq/) version v4.44.3"
	exit 0
fi
exit 1
'
	# shellcheck source=../../lib/require.bash
	source "$SCT_LIBDIR/require.bash"
	require yq
	# shellcheck source=../../lib/require.bash
	source "$SCT_LIBDIR/require.bash"
	require yq

	run grep -c . "$YQ_LOG"
	assert_output "1"
}

@test "require yq does not cache a failed mikefarah check" {
	write_yq '
echo "called $*" >> "${YQ_LOG:?}"
echo "yq 3.0.0"
'
	# shellcheck source=../../lib/require.bash
	source "$SCT_LIBDIR/require.bash"

	status1=0
	require yq || status1=$?
	status2=0
	require yq || status2=$?
	assert_equal "$status1" "$exitcode_expectation_failed"
	assert_equal "$status2" "$exitcode_expectation_failed"

	run grep -c . "$YQ_LOG"
	assert_output "2"
}

@test "require yq fails when no binary is on PATH" {
	# shellcheck source=../../lib/require.bash
	source "$SCT_LIBDIR/require.bash"
	PATH="/usr/bin:/bin"

	run require yq
	assert_failure
	assert_equal "$status" "$exitcode_expectation_failed"
	assert_output --partial "yq required"
}
