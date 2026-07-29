#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/devcontainer
	source "$SCT_LIBEXECDIR/init/devcontainer"

	DEVCONTAINER_DIR="$BATS_TEST_TMPDIR/devcontainer"
	mkdir -p "$DEVCONTAINER_DIR"
	cp "$SCT_TEMPLATEDIR/devcontainer/Dockerfile.app" "$DEVCONTAINER_DIR/Dockerfile.app"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/$SCT_PROJECT_DIR"

	SETTINGS_FILE="$SCT_PROJECT_DIR/settings.json"
	touch "$PROJECT_DIR/$SETTINGS_FILE"
}

teardown() {
	unstub_all
}

@test "Dockerfile.app template contains __DEVBOX_INSTALL__ placeholder" {
	run grep '# __DEVBOX_INSTALL__' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "customize_devbox expands the install block" {
	customize_devbox "$DEVCONTAINER_DIR"

	run grep 'get.jetify.com/devbox' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep 'devbox global install' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep '/etc/profile.d/sandcat-devbox.sh' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "customize_devbox splits stack and tools installs into two layers" {
	customize_devbox "$DEVCONTAINER_DIR"

	# Match the executable RUN clauses only, not comments that also mention
	# "devbox global install". Both Layer A and Layer B end their multi-line
	# RUN with "&& devbox global install".
	run grep -cE '^ *&& devbox global install' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_output "2"
}

@test "customize_devbox mounts the Nix HTTP cache in install layers" {
	customize_devbox "$DEVCONTAINER_DIR"

	# BuildKit cache mount on ~/.cache/nix so .nar downloads persist across
	# builds on the same host. One mount per install layer.
	run grep -c -- '--mount=type=cache,target=/home/vscode/.cache/nix' \
		"$DEVCONTAINER_DIR/Dockerfile.app"
	assert_output "2"
}

@test "customize_devbox leaves no __DEVBOX_INSTALL__ placeholder residue" {
	customize_devbox "$DEVCONTAINER_DIR"

	run grep -c '__DEVBOX_INSTALL__' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_output "0"
}

@test "Dockerfile.app template installs rsync (needed by home snapshot sync)" {
	# app-init.sh uses rsync to refresh the image-side /home/vscode
	# snapshot into the agent-home volume; without it the sync silently
	# fails and users need `down -v` after every rebuild.
	run grep -E 'apt-get install .* rsync' \
		"$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "Dockerfile.app template snapshots /home/vscode into /opt/sandcat" {
	# Snapshot lives outside the agent-home volume mount so app-init.sh
	# can see fresh image content after a rebuild and rsync it back into
	# the volume — otherwise the volume masks image updates.
	run grep 'mkdir -p /opt/sandcat/snapshots' \
		"$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep 'cp -a /home/vscode/.local/share/devbox /opt/sandcat/snapshots/devbox' \
		"$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep 'cp /home/vscode/.bashrc /opt/sandcat/snapshots/bashrc' \
		"$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "Dockerfile.app template writes a snapshot content hash" {
	# The hash gates the runtime rsync so unchanged rebuilds skip it.
	run grep '/opt/sandcat/snapshots/hash' \
		"$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}

@test "app-init.sh syncs the image snapshot into the volume" {
	APP_INIT="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/app-init.sh"
	run grep 'SNAPSHOT_DIR="/opt/sandcat/snapshots"' "$APP_INIT"
	assert_success
	# --delete on devbox so removed packages don't leave dangling symlinks.
	run grep -E 'rsync -a --delete .*SNAPSHOT_DIR/devbox/' "$APP_INIT"
	assert_success
	# No --delete on sandcat so app-user-init's runtime cacerts survive.
	run grep -E 'rsync -a "\$SNAPSHOT_DIR/sandcat/"' "$APP_INIT"
	assert_success
	run grep 'VOLUME_HASH_FILE="/home/vscode/.sandcat-snapshot-hash"' "$APP_INIT"
	assert_success
}

@test "customize_devbox writes devbox.stack.json with the baseline shell tools" {
	customize_devbox "$DEVCONTAINER_DIR"

	# Baseline packages defined in SCT_DEVBOX_BASELINE_PACKAGES.
	run jq -r '.packages | length' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_output "7"
	for pkg in fd fzf gh jq ripgrep tmux vim; do
		run jq -r ".packages | map(select(startswith(\"${pkg}@\"))) | length" "$DEVCONTAINER_DIR/devbox.stack.json"
		assert_output "1"
	done
}

@test "customize_devbox adds stack packages to devbox.stack.json" {
	customize_devbox "$DEVCONTAINER_DIR" java

	run jq -r '.packages | length' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_output "8"  # 7 baseline + openjdk
	run jq -e '.packages | any(. == "temurin-bin-25@latest")' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_success
}

@test "customize_devbox handles multiple stacks with dependencies" {
	# Simulating what libexec/init/devcontainer would pass after
	# resolve_stacks — dependencies come before dependents.
	customize_devbox "$DEVCONTAINER_DIR" java scala

	# baseline (7) + java (openjdk) + scala (scala, sbt, scala-cli) = 11
	run jq -r '.packages | length' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_output "11"
	run jq -e '.packages | any(. == "temurin-bin-25@latest")' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_success
	run jq -e '.packages | any(. == "scala@latest")' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_success
	run jq -e '.packages | any(. == "sbt@latest")' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_success
}

@test "customize_devbox regenerates devbox.stack.json on re-init (not guarded)" {
	# First init with java → stack.json has openjdk.
	customize_devbox "$DEVCONTAINER_DIR" java
	run jq -e '.packages | any(. == "temurin-bin-25@latest")' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_success

	# Second init with no stacks → openjdk goes away, baseline stays.
	customize_devbox "$DEVCONTAINER_DIR"
	run jq -e '.packages | any(. == "temurin-bin-25@latest")' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_failure
	run jq -r '.packages | length' "$DEVCONTAINER_DIR/devbox.stack.json"
	assert_output "7"
}

@test "customize_devbox creates devbox.tools.json with empty packages list" {
	customize_devbox "$DEVCONTAINER_DIR"

	run jq -e '.packages | length == 0' "$DEVCONTAINER_DIR/devbox.tools.json"
	assert_success
}

@test "customize_devbox preserves user edits in devbox.tools.json across re-init" {
	# First init writes the starter.
	customize_devbox "$DEVCONTAINER_DIR"

	# User adds a package.
	echo '{"packages": ["hyperfine@latest"]}' > "$DEVCONTAINER_DIR/devbox.tools.json"

	# Re-init with different stacks — tools.json must survive untouched.
	customize_devbox "$DEVCONTAINER_DIR" python

	run jq -e '.packages[0] == "hyperfine@latest"' "$DEVCONTAINER_DIR/devbox.tools.json"
	assert_success
}

@test "devcontainer command generates both devbox files" {
	devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent claude \
		--ide vscode

	run test -f "$PROJECT_DIR/.devcontainer/devbox.stack.json"
	assert_success
	run test -f "$PROJECT_DIR/.devcontainer/devbox.tools.json"
	assert_success
	# Baseline present.
	run jq -r '.packages | length' "$PROJECT_DIR/.devcontainer/devbox.stack.json"
	assert_output "7"
}

@test "devcontainer command flows --stacks into devbox.stack.json" {
	# devcontainer expects already-resolved stacks (upper-level init handles
	# resolve_stacks). Pass "java scala" to mirror the resolved form.
	devcontainer \
		--settings-file "$SETTINGS_FILE" \
		--project-path "$PROJECT_DIR" \
		--agent claude \
		--ide vscode \
		--stacks "java scala"

	# baseline (7) + openjdk + scala + sbt + scala-cli = 11
	run jq -r '.packages | length' "$PROJECT_DIR/.devcontainer/devbox.stack.json"
	assert_output "11"
	run jq -e '.packages | any(. == "temurin-bin-25@latest")' "$PROJECT_DIR/.devcontainer/devbox.stack.json"
	assert_success
}

# ------------------------------------------------------------------
# jq merge program (_devbox_merge_jq) exercised via direct piping.
# ------------------------------------------------------------------

merge_jq() {
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"
	local merge
	merge=$(_devbox_merge_jq)
	local stack_json=$1
	local tools_json=$2
	jq -s "$merge" <(echo "$stack_json") <(echo "$tools_json")
}

@test "merge unions disjoint packages" {
	local out
	out=$(merge_jq \
		'{"packages":["jq@latest","fd@latest"]}' \
		'{"packages":["hyperfine@latest"]}' \
		| jq -r '.packages | length')
	assert_equal "$out" "3"
}

@test "merge deduplicates identical package specs" {
	local out
	out=$(merge_jq '{"packages":["jq@latest","fd@latest"]}' '{"packages":["jq@latest"]}' | jq -r '.packages | length')
	assert_equal "$out" "2"
}

@test "merge lets tools override stack on same package name" {
	# When both files list a package with the same name (part before '@')
	# but different versions, the tools entry wins. This is the primary
	# way for users to pin a version different from the stack default.
	local out
	out=$(merge_jq \
		'{"packages":["python@3.12"]}' \
		'{"packages":["python@3.10"]}')
	run bash -c "echo '$out' | jq -r '.packages[]'"
	assert_output "python@3.10"
}

@test "merge keeps both packages for cross-family collision" {
	# tools' openjdk17 and stack's temurin-bin-25 both provide bin/java
	# but have different package names — merge keeps both. The Dockerfile
	# then uses `nix profile add --priority 3` on tools entries so they
	# win the Nix profile collision at materialization time.
	local out
	out=$(merge_jq \
		'{"packages":["temurin-bin-25@latest"]}' \
		'{"packages":["openjdk17@latest"]}')
	run bash -c "echo '$out' | jq -r '.packages | length'"
	assert_output "2"
}

@test "merge override does not touch unrelated stack packages" {
	local out
	out=$(merge_jq \
		'{"packages":["python@3.12","jq@latest","fd@latest"]}' \
		'{"packages":["python@3.10","hyperfine@latest"]}')
	# python overridden, jq/fd untouched, hyperfine added
	run bash -c "echo '$out' | jq -r '.packages | length'"
	assert_output "4"
	run bash -c "echo '$out' | jq -r '.packages | map(select(startswith(\"python\"))) | .[]'"
	assert_output "python@3.10"
}

@test "merge handles empty tools.json" {
	local out
	out=$(merge_jq '{"packages":["jq@latest"]}' '{"packages":[]}' | jq -r '.packages | length')
	assert_equal "$out" "1"
}

@test "Dockerfile.app template bumps priority of tools entries via nix profile add" {
	# Cross-family collisions between stack and tools packages (e.g. two
	# JDKs both providing bin/java) are resolved by re-adding each tools
	# entry to the Nix profile with --priority 3. The Dockerfile has to
	# diff manifest.json before/after devbox install to identify which
	# entries came from tools, then bump each.
	customize_devbox "$DEVCONTAINER_DIR"
	# Before/after storepath snapshots let the priority bump find tools
	# entries by set difference — schema-agnostic across manifest versions.
	run grep -F "/tmp/paths.before.txt" "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep -F "/tmp/paths.after.txt" "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
	run grep -F 'profile add --priority 3' "$DEVCONTAINER_DIR/Dockerfile.app"
	assert_success
}
