#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/require.bash"

	# A fake yq on PATH lets each test script the exit status and output of the
	# underlying binary that the wrapper calls via `command yq`.
	FAKE_BIN="$BATS_TEST_TMPDIR/bin"
	COUNTER="$BATS_TEST_TMPDIR/calls"
	mkdir -p "$FAKE_BIN"
	: >"$COUNTER"
	PATH="$FAKE_BIN:$PATH"
}

# Number of times the fake yq was invoked. Uses awk rather than `wc -l`, whose
# BSD build pads the count with leading spaces and breaks string comparison.
call_count() {
	awk 'END { print NR }' "$COUNTER"
}

# Writes a fake yq that fails the first $1 calls with $2, then succeeds.
fake_yq() {
	local failures=$1
	local signal=$2
	cat >"$FAKE_BIN/yq" <<EOF
#!/usr/bin/env bash
echo call >>"$COUNTER"
calls=\$(awk 'END { print NR }' "$COUNTER")
if [[ "\$calls" -le $failures ]]; then
	kill -$signal \$\$
fi
echo "yq-output"
EOF
	chmod +x "$FAKE_BIN/yq"
}

@test "yq returns output unchanged when the binary succeeds" {
	fake_yq 0 SEGV

	run yq '.a' file.yml
	assert_success
	assert_output "yq-output"
}

@test "yq retries a segfault and returns the successful output once" {
	fake_yq 1 SEGV

	# --separate-stderr keeps the shell's own "Segmentation fault" job message
	# out of $output.
	run --separate-stderr yq '.a' file.yml
	assert_success
	# A crashed attempt must not leave its partial output concatenated with the
	# retry's output.
	assert_output "yq-output"
	assert_equal "$(call_count)" "2"
}

@test "yq gives up after three segfaults" {
	fake_yq 5 SEGV

	run yq '.a' file.yml
	assert_failure 139
	assert_equal "$(call_count)" "3"
}

@test "yq does not retry a genuine yq error" {
	cat >"$FAKE_BIN/yq" <<EOF
#!/usr/bin/env bash
echo call >>"$COUNTER"
echo "bad expression" >&2
exit 1
EOF
	chmod +x "$FAKE_BIN/yq"

	run yq '.a' file.yml
	assert_failure 1
	assert_equal "$(call_count)" "1"
}

@test "require yq reports a missing binary rather than a wrong variant" {
	# The wrapper is a shell function, so command -v alone would find it.
	mkdir -p "$BATS_TEST_TMPDIR/empty"
	PATH="$BATS_TEST_TMPDIR/empty:/usr/bin:/bin"

	run require yq
	assert_failure
	assert_output --partial "yq required"
}
