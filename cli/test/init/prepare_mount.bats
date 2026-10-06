#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper

	HOME="$BATS_TEST_TMPDIR/home"
	export HOME
	mkdir -p "$HOME/.local/bin" "$HOME/.config/sandcat"

	PROJECT="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT/.devcontainer/sandcat/scripts" "$PROJECT/.sandcat"
	printf '%s\n' '{}' >"$PROJECT/.sandcat/settings.json"
	cat >"$PROJECT/.devcontainer/compose-all.yml" <<'YAML'
include:
  - path: sandcat/compose-agent.yml
YAML
	mkdir -p "$PROJECT/.devcontainer/sandcat"
	cat >"$PROJECT/.devcontainer/sandcat/compose-agent.yml" <<'YAML'
volumes:
  sandcat-cache-coursier:
    external: true
    name: sandcat-cache-coursier
YAML
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/prepare-agent-sandcat-mount.sh" \
		"$PROJECT/.devcontainer/sandcat/scripts/"

	STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
	mkdir -p "$STUB_BIN"
	cat >"$STUB_BIN/yq" <<'EOF'
#!/bin/bash
if [[ "${1-}" == "--version" ]]; then
	echo "yq (https://github.com/mikefarah/yq/) version v4.44.3"
	exit 0
fi
exit 0
EOF
	chmod +x "$STUB_BIN/yq"
	cat >"$STUB_BIN/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
exit 0
EOF
	chmod +x "$STUB_BIN/docker"
	DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
	export DOCKER_LOG
	: >"$DOCKER_LOG"
}

teardown() {
	unstub_all 2>/dev/null || true
}

@test "prepare-agent-sandcat-mount follows the installer launcher symlink" {
	mkdir -p "$HOME/.local/share/sandcat"
	ln -s "$SCT_ROOT" "$HOME/.local/share/sandcat/cli"
	ln -s "$HOME/.local/share/sandcat/cli/bin/sandcat" "$HOME/.local/bin/sandcat"

	unset SCT_LIBDIR SCT_ROOT SCT_LIBEXECDIR SCT_TEMPLATEDIR
	cd "$PROJECT"
	PATH="$HOME/.local/bin:$STUB_BIN:/usr/bin:/bin" \
		run bash .devcontainer/sandcat/scripts/prepare-agent-sandcat-mount.sh
	assert_success
	assert_output --partial "using SCT_LIBDIR="
	assert_output --partial "refreshed filtered .sandcat copy"
	run cat "$DOCKER_LOG"
	assert_output --partial "volume create --label sandcat-shared-cache=true sandcat-cache-coursier"
}

@test "prepare-agent-sandcat-mount succeeds without sandcat on PATH" {
	unset SCT_LIBDIR
	cd "$PROJECT"
	PATH="$STUB_BIN:/usr/bin:/bin" \
		run bash .devcontainer/sandcat/scripts/prepare-agent-sandcat-mount.sh
	assert_success
	assert_output --partial "sandcat CLI not found"
	run cat "$DOCKER_LOG"
	assert_output --partial "volume create --label sandcat-shared-cache=true sandcat-cache-coursier"
	[[ -f "$PROJECT/.devcontainer/.env" ]]
	run grep '^SANDCAT_AGENT_SANDCAT=' "$PROJECT/.devcontainer/.env"
	assert_success
}
