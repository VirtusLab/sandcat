#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

# Compose's `include` copies resources into the model, it never merges them:
# a service declared in both compose-all.yml and an included file aborts the
# whole project with "conflicts with imported resource". These tests pin that
# invariant on the generated tree so it fails here rather than at `sandcat up`.

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/init
	source "$SCT_LIBEXECDIR/init/init"
	# shellcheck source=../../libexec/init/devcontainer
	source "$SCT_LIBEXECDIR/init/devcontainer"

	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/.sandcat"
	touch "$PROJECT_DIR/.sandcat/settings.json"

	SCT_HOME_DIR="$BATS_TEST_TMPDIR/config/sandcat"
	mkdir -p "$SCT_HOME_DIR"
	sct_home() { echo "$SCT_HOME_DIR"; }
	export -f sct_home

	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
}

teardown() {
	unstub_all
}

assert_no_include_conflicts() {
	local devcontainer_dir=$1

	local -a included=()
	local include_path service
	while read -r include_path
	do
		[[ -n "$include_path" ]] || continue
		while read -r service
		do
			included+=("$service")
		done < <(yq -r '.services // {} | keys | .[]' "$devcontainer_dir/$include_path")
	done < <(yq -r '.include[]?.path' "$devcontainer_dir/compose-all.yml")

	local imported
	while read -r service
	do
		[[ -n "$service" ]] || continue
		for imported in "${included[@]}"
		do
			if [[ "$service" == "$imported" ]]
			then
				fail "service '$service' is declared in compose-all.yml and in an included file"
			fi
		done
	done < <(yq -r '.services // {} | keys | .[]' "$devcontainer_dir/compose-all.yml")
}

@test "init keeps compose-all.yml services disjoint from its includes" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" \
		--stacks "" --proxy web --features "" --secret-provider none
	assert_success

	assert_no_include_conflicts "$PROJECT_DIR/.devcontainer"
}

@test "init keeps services disjoint with netbird, capability and proxy-peer enabled" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json cursor : :"

	run init --agent cursor --ide none --name cv-sandbox --path "$PROJECT_DIR" \
		--stacks python --proxy web --features tui --secret-provider protonpass \
		--netbird --netbird-server cloud --capability --proxy-peer
	assert_success

	assert_no_include_conflicts "$PROJECT_DIR/.devcontainer"
}

@test "init mounts project settings on the imported mitmproxy service" {
	stub settings "$PROJECT_DIR/.sandcat/settings.json claude vscode : :"

	run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" \
		--stacks "" --proxy web --features "" --secret-provider none
	assert_success

	# Two levels up, because relative paths in an included file resolve against
	# that file's own directory (.devcontainer/sandcat), not the project root.
	yq -e '.services.mitmproxy.volumes[] | select(. == "../../.sandcat:/config/project:ro")' \
		"$PROJECT_DIR/.devcontainer/sandcat/compose-proxy.yml"
}
