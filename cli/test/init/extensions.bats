#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/devcontainer.bash
	source "$SCT_LIBDIR/devcontainer.bash"
	# shellcheck source=../../lib/composefile.bash
	source "$SCT_LIBDIR/composefile.bash"

	DEVCONTAINER_JSON="$BATS_TEST_TMPDIR/devcontainer.json"
	cp "$SCT_TEMPLATEDIR/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
	mkdir -p "$BATS_TEST_TMPDIR/sandcat/scripts"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	touch "$BATS_TEST_TMPDIR/compose-all.yml"
	touch "$BATS_TEST_TMPDIR/Dockerfile.app"
	touch "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
}

teardown() {
	unstub_all
}

@test "customize_devcontainer_extensions adds extension for python" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python

	run grep '"ms-python.python"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions adds multiple extensions" {
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python java go

	run grep '"ms-python.python"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"redhat.java"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"golang.go"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions preserves existing extensions" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"

	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python

	run grep '"anthropic.claude-code"' "$DEVCONTAINER_JSON"
	assert_success

	run grep '"github.vscode-pull-request-github"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_devcontainer_extensions removes __STACK_EXTENSIONS__ placeholder" {
	# The placeholder line must always be consumed, regardless of whether
	# the selected stacks contribute any extension. Bats has no parametric
	# tests, so we cover both branches in a single test:
	#   - "node"   — no extension contribution
	#   - "python" — contributes an extension
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" node
	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure

	# Re-run with an extension-contributing stack on a fresh fixture.
	cp "$SCT_TEMPLATEDIR/devcontainer/devcontainer.json" "$DEVCONTAINER_JSON"
	customize_devcontainer_extensions "$DEVCONTAINER_JSON" python
	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure
}

@test "customize_devcontainer_extensions is a no-op for empty stacks" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"

	customize_devcontainer_extensions "$DEVCONTAINER_JSON"

	run grep "__STACK_EXTENSIONS__" "$DEVCONTAINER_JSON"
	assert_failure

	run grep '"anthropic.claude-code"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_agent_templates sets cursor extension baseline" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "cursor"

	run grep '"anysphere.cursor"' "$DEVCONTAINER_JSON"
	assert_success
}

@test "customize_agent_templates sets claude mitmproxy defaults" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"

	run grep 'http2=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '/scripts/mitmproxy_addon_claude.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	# Streaming-related flags are Cursor-only; including them on the Claude
	# path would weaken the body-content placeholder leak check in
	# _substitute_secrets (mitmproxy buffers <1MB bodies by default).
	run grep 'stream_large_bodies=1m' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'connection_strategy=lazy' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'anticomp=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'timeout_read=300' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	# Placeholder must be fully resolved.
	run grep '__AGENT_MITM_STREAMING_FLAGS__' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure
}

@test "customize_agent_templates adds cursor bootstrap settings" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "cursor"

	run grep 'cursor-cli-config.json' "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"
	assert_success

	run grep 'http2=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '/scripts/mitmproxy_addon_cursor.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'stream_large_bodies=1m' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'connection_strategy=lazy' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'anticomp=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep 'timeout_read=300' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '__AGENT_MITM_STREAMING_FLAGS__' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure
}

@test "customize_agent_templates sets codex mitmproxy defaults" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "codex"

	run grep 'http2=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '/scripts/mitmproxy_addon_codex.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	# Streaming-related flags are Cursor-only; including them on the Codex
	# path would weaken the body-content placeholder leak check in
	# _substitute_secrets (mitmproxy buffers <1MB bodies by default).
	run grep 'stream_large_bodies=1m' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'connection_strategy=lazy' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'anticomp=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'timeout_read=300' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	# Placeholder must be fully resolved.
	run grep '__AGENT_MITM_STREAMING_FLAGS__' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure
}

@test "customize_agent_templates sets copilot mitmproxy defaults" {
	{
		echo 'include: []'
		echo 'services: {agent: {environment: []}}'
	} > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "copilot"

	run grep 'http2=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	run grep '/scripts/mitmproxy_addon_copilot.py' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_success

	# Streaming-related flags are Cursor-only; including them on the Copilot
	# path would weaken the body-content placeholder leak check in
	# _substitute_secrets (mitmproxy buffers <1MB bodies by default).
	run grep 'stream_large_bodies=1m' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'connection_strategy=lazy' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'anticomp=true' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	run grep 'timeout_read=300' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure

	# Placeholder must be fully resolved.
	run grep '__AGENT_MITM_STREAMING_FLAGS__' "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	assert_failure
}

# --------------------------------------------------- stack environment

@test "customize_compose_stack_environment adds python's uv TLS env vars" {
	echo 'services: {agent: {}}' > "$BATS_TEST_TMPDIR/compose-all.yml"

	customize_compose_stack_environment "$BATS_TEST_TMPDIR/compose-all.yml" python

	yq -e '.services.agent.environment[] | select(. == "UV_SYSTEM_CERTS=1")' \
		"$BATS_TEST_TMPDIR/compose-all.yml"
}

@test "customize_compose_stack_environment is a no-op for stacks without env contributions" {
	echo 'services: {agent: {}}' > "$BATS_TEST_TMPDIR/compose-all.yml"

	customize_compose_stack_environment "$BATS_TEST_TMPDIR/compose-all.yml" node java

	# compose rejects `environment: {}` — the key must be entirely absent,
	# not present-but-empty.
	run yq -e '.services.agent | has("environment")' "$BATS_TEST_TMPDIR/compose-all.yml"
	assert_failure
}

@test "customize_compose_stack_environment and customize_agent_templates environment entries coexist regardless of call order" {
	# Real init flow calls the stack merge before the agent merge; this test
	# guards against a regression where either merge overwrites the other's
	# entries instead of appending (the bug the append-based
	# merge_compose_agent_environment helper exists to prevent).
	echo 'services: {agent: {}}' > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_compose_stack_environment "$BATS_TEST_TMPDIR/compose-all.yml" python
	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"

	yq -e '.services.agent.environment[] | select(. == "UV_SYSTEM_CERTS=1")' \
		"$BATS_TEST_TMPDIR/compose-all.yml"
	yq -e '.services.agent.environment[] | select(. == "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")' \
		"$BATS_TEST_TMPDIR/compose-all.yml"
}

@test "customize_agent_templates and customize_compose_stack_environment environment entries coexist in reverse call order" {
	echo 'services: {agent: {}}' > "$BATS_TEST_TMPDIR/compose-all.yml"
	echo "__AGENT_DOCKER_INSTALL__" > "$BATS_TEST_TMPDIR/Dockerfile.app"
	echo "__AGENT_USER_INIT__" > "$BATS_TEST_TMPDIR/sandcat/scripts/app-user-init.sh"

	customize_agent_templates "$BATS_TEST_TMPDIR" "claude"
	customize_compose_stack_environment "$BATS_TEST_TMPDIR/compose-all.yml" python

	yq -e '.services.agent.environment[] | select(. == "UV_SYSTEM_CERTS=1")' \
		"$BATS_TEST_TMPDIR/compose-all.yml"
	yq -e '.services.agent.environment[] | select(. == "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")' \
		"$BATS_TEST_TMPDIR/compose-all.yml"
}

@test "compose-proxy.yml declares mitmproxy-public volume" {
	yq -e '.volumes | has("mitmproxy-public")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
}

@test "compose-proxy.yml mounts mitmproxy-public writable in mitmproxy" {
	yq -e '.services.mitmproxy.volumes[] | select(. == "mitmproxy-public:/mitmproxy-public")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
}

@test "compose-proxy.yml healthcheck gates on public CA cert" {
	local check
	check=$(yq -r '.services.mitmproxy.healthcheck.test | join(" ")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml")
	[[ "$check" == *"/mitmproxy-public/mitmproxy-ca-cert.pem"* ]]
}

@test "compose-agent.yml mounts agent from mitmproxy-public (not mitmproxy-config)" {
	# The agent's constant volumes live in sandcat/compose-agent.yml since the
	# #22 split; compose-all.yml only carries user-editable overrides.
	yq -e '.services.agent.volumes[] | select(. == "mitmproxy-public:/mitmproxy-config:ro")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-agent.yml"

	# Regression guard: the old private mount MUST NOT exist on agent.
	run yq -e '.services.agent.volumes[] | select(. == "mitmproxy-config:/mitmproxy-config:ro")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-agent.yml"
	[ "$status" -ne 0 ]
}

# --------------------------------------------------- upstream CA bundles

@test "apply_upstream_ca_bundles is a no-op with no settings" {
	local before
	before=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")

	HOME="$BATS_TEST_TMPDIR/home" run apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"
	assert_success

	local after
	after=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")
	[ "$before" = "$after" ]
}

@test "apply_upstream_ca_bundles adds mounts for configured bundles" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	local ca="$BATS_TEST_TMPDIR/company-ca.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----\n' > "$ca"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<EOF
{ "upstream_ca_bundles": ["$ca"] }
EOF

	HOME="$BATS_TEST_TMPDIR/home" apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"

	yq -e ".services.mitmproxy.volumes[] | select(. == \"${ca}:/upstream-ca/000-company-ca.crt:ro\")" \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
}

@test "apply_upstream_ca_bundles numbers multiple bundles" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	local a="$BATS_TEST_TMPDIR/a.pem" b="$BATS_TEST_TMPDIR/b.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nA\n-----END CERTIFICATE-----\n' > "$a"
	printf -- '-----BEGIN CERTIFICATE-----\nB\n-----END CERTIFICATE-----\n' > "$b"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<EOF
{ "upstream_ca_bundles": ["$a", "$b"] }
EOF

	HOME="$BATS_TEST_TMPDIR/home" apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"

	yq -e ".services.mitmproxy.volumes[] | select(. == \"${a}:/upstream-ca/000-a.crt:ro\")" \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
	yq -e ".services.mitmproxy.volumes[] | select(. == \"${b}:/upstream-ca/001-b.crt:ro\")" \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml"
}

@test "apply_upstream_ca_bundles rewrites entrypoint to install CAs" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	local ca="$BATS_TEST_TMPDIR/ca.pem"
	printf -- '-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n' > "$ca"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<EOF
{ "upstream_ca_bundles": ["$ca"] }
EOF

	HOME="$BATS_TEST_TMPDIR/home" apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"

	# The rewritten entrypoint must reference the install step and still run
	# the original dns.conf cleanup + docker-entrypoint.sh chain.
	local ep
	ep=$(yq -r '.services.mitmproxy.entrypoint | join(" ")' \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")
	[[ "$ep" == *"update-ca-certificates"* ]]
	[[ "$ep" == *"/upstream-ca"* ]]
	[[ "$ep" == *"rm -f /home/mitmproxy/.mitmproxy/dns.conf"* ]]
	[[ "$ep" == *"exec docker-entrypoint.sh"* ]]
	# Regression guard (#25): the template's entrypoint also publishes the CA
	# cert onto the agent-facing mitmproxy-public volume, and the healthcheck
	# gates on that file. Substituting a fixed entrypoint here would drop it
	# and the stack would never become healthy.
	[[ "$ep" == *"mitmproxy-public"* ]]
	# The install must run BEFORE the template's backgrounded waiter, not
	# inside it — `&` binds looser than `&&`, so joining with `&&` would
	# background the install and race mitmproxy's start.
	[[ "$ep" == *"|| exit 1;"* ]]
	[[ "${ep%%|| exit 1;*}" == *"update-ca-certificates"* ]]
	# Fail-loud: no conditional guard around the CA install.
	[[ "$ep" != *"if [ -d"* ]]
	# certifi bundle patch: mitmproxy uses certifi.where() for upstream
	# trust store, not the OS store, so update-ca-certificates alone is
	# insufficient. E2E verified.
	[[ "$ep" == *"certifi.where()"* ]]
}

@test "apply_upstream_ca_bundles fails and does not modify compose on invalid path" {
	mkdir -p "$BATS_TEST_TMPDIR/home/.config/sandcat"
	cat > "$BATS_TEST_TMPDIR/home/.config/sandcat/settings.json" <<'EOF'
{ "upstream_ca_bundles": ["/nonexistent/ca.pem"] }
EOF

	local before
	before=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")

	HOME="$BATS_TEST_TMPDIR/home" run apply_upstream_ca_bundles \
		"$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml" "$BATS_TEST_TMPDIR/proj"
	assert_failure
	assert_output --partial "file not found"
	assert_output --partial "/nonexistent/ca.pem"

	local after
	after=$(cat "$BATS_TEST_TMPDIR/sandcat/compose-proxy.yml")
	[ "$before" = "$after" ]
}
