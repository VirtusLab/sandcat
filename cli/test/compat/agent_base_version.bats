#!/usr/bin/env bats
# Contract: cli/lib/constants.bash's SCT_AGENT_BASE_VERSION (the tag generated
# Dockerfile.app builds from) must stay equal to images/agent-base/agent-base.env's
# AGENT_BASE_VERSION (the tag the build workflow publishes).

setup() {
	load test_helper
	# shellcheck source=../../lib/constants.bash
	source "$SCT_LIBDIR/constants.bash"
}

@test "SCT_AGENT_BASE_VERSION matches AGENT_BASE_VERSION in images/agent-base/agent-base.env" {
	local env_version
	env_version="$(grep -m1 '^AGENT_BASE_VERSION=' "$SCT_ROOT/../images/agent-base/agent-base.env" | cut -d= -f2-)"

	assert_equal "$SCT_AGENT_BASE_VERSION" "$env_version"
}
