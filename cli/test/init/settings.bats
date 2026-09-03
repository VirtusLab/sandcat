#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/settings
	source "$SCT_LIBEXECDIR/init/settings"
}

teardown() {
	unstub_all
}

@test "settings creates settings file from template" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"

	run settings "$settings_file" "github"
	assert_success

	# File should exist
	[[ -f "$settings_file" ]]

	assert_output --partial "Settings file created at"
}

@test "settings creates parent directories" {
	local settings_file="$BATS_TEST_TMPDIR/nested/deep/settings.json"

	run settings "$settings_file" "github"
	assert_success

	[[ -f "$settings_file" ]]
}

@test "settings default keeps the template wildcard rule" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"

	run settings "$settings_file" "github"
	assert_success

	yq -e '.network[0].action == "allow" and .network[0].host == "*" and .network[0].method == "GET"' \
		"$settings_file"
}

@test "settings --strict-network seeds stack presets instead of the wildcard" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"

	run settings --strict-network --stacks "python java" "$settings_file" "github"
	assert_success

	yq -e '.network | length == 2' "$settings_file"
	yq -e '.network[0].preset == "python"' "$settings_file"
	yq -e '.network[1].preset == "java"' "$settings_file"
	# The wildcard must be gone — that is the whole point of strict mode.
	run yq -e '.network[] | select(.host == "*")' "$settings_file"
	[ "$status" -ne 0 ]
}

@test "settings --strict-network with no stacks leaves an empty network list" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"

	run settings --strict-network --stacks "" "$settings_file" "github"
	assert_success

	yq -e '.network | length == 0' "$settings_file"
}

@test "settings rejects unknown option" {
	run settings --no-such-flag "$BATS_TEST_TMPDIR/settings.json"
	assert_failure
	assert_output --partial "unknown option"
}

@test "settings creates empty settings.local.json scaffold when absent" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"
	local local_settings="$BATS_TEST_TMPDIR/settings.local.json"

	run settings "$settings_file" "github"
	assert_success

	[[ -f "$local_settings" ]]
	run cat "$local_settings"
	assert_output "{}"
}

@test "settings preserves an existing settings.local.json" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"
	local local_settings="$BATS_TEST_TMPDIR/settings.local.json"

	# Simulate a user who already put real credentials in the local file.
	printf '{"secrets":{"MY_TOKEN":{"value":"real"}}}' > "$local_settings"

	run settings "$settings_file" "github"
	assert_success

	run cat "$local_settings"
	assert_output --partial '"real"'
}

@test "read_upstream_ca_bundles returns empty when no settings configured" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_output ""
}

@test "read_upstream_ca_bundles reads user settings" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<'EOF'
{ "upstream_ca_bundles": ["/etc/ssl/company.pem", "/opt/ca/gitlab.crt"] }
EOF
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_line --index 0 "/etc/ssl/company.pem"
	assert_line --index 1 "/opt/ca/gitlab.crt"
}

@test "read_upstream_ca_bundles reads project settings.local.json" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	mkdir -p "$BATS_TEST_TMPDIR/proj/.sandcat"
	cat > "$BATS_TEST_TMPDIR/proj/.sandcat/settings.local.json" <<'EOF'
{ "upstream_ca_bundles": ["/etc/ssl/proj.pem"] }
EOF
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_output "/etc/ssl/proj.pem"
}

@test "read_upstream_ca_bundles concatenates user then project" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	mkdir -p "$BATS_TEST_TMPDIR/proj/.sandcat"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<'EOF'
{ "upstream_ca_bundles": ["/a.pem"] }
EOF
	cat > "$BATS_TEST_TMPDIR/proj/.sandcat/settings.local.json" <<'EOF'
{ "upstream_ca_bundles": ["/b.pem"] }
EOF
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_line --index 0 "/a.pem"
	assert_line --index 1 "/b.pem"
}

@test "read_upstream_ca_bundles ignores missing key gracefully" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	echo '{ "network": [] }' > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json"
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_output ""
}

@test "read_upstream_ca_bundles handles empty array as no-op" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	echo '{ "upstream_ca_bundles": [] }' > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json"
	HOME="$BATS_TEST_TMPDIR/home" run read_upstream_ca_bundles "$BATS_TEST_TMPDIR/proj"
	assert_success
	assert_output ""
}

@test "validate_upstream_ca_bundle accepts absolute path with PEM" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	local f="$BATS_TEST_TMPDIR/ca.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----\n' > "$f"
	run validate_upstream_ca_bundle "$f"
	assert_success
	assert_output ""
}

@test "validate_upstream_ca_bundle rejects relative path" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	run validate_upstream_ca_bundle "relative/path.pem"
	assert_failure
	assert_output --partial "expected absolute path"
	assert_output --partial "relative/path.pem"
}

@test "validate_upstream_ca_bundle rejects missing file" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	run validate_upstream_ca_bundle "/nonexistent/ca.pem"
	assert_failure
	assert_output --partial "file not found"
	assert_output --partial "/nonexistent/ca.pem"
}

@test "validate_upstream_ca_bundle rejects unreadable file" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	local f="$BATS_TEST_TMPDIR/unreadable.pem"
	printf -- '-----BEGIN CERTIFICATE-----\n' > "$f"
	chmod 000 "$f"
	run validate_upstream_ca_bundle "$f"
	assert_failure
	assert_output --partial "not readable"
	chmod 644 "$f"
}

@test "validate_upstream_ca_bundle rejects non-PEM content" {
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"
	local f="$BATS_TEST_TMPDIR/notpem.crt"
	printf 'this is not a certificate\n' > "$f"
	run validate_upstream_ca_bundle "$f"
	assert_failure
	assert_output --partial "no PEM certificate block"
}
