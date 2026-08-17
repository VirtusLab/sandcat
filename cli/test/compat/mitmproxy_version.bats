#!/usr/bin/env bats
# Contract: cli/lib/constants.bash's SCT_MITMPROXY_VERSION (used by the CLI to
# render pinned image refs) must stay equal to images/mitmproxy.env's
# MITMPROXY_VERSION (used by the build workflows to publish those refs).
# Also guards both Dockerfiles against a stray re-hardcode of the base image
# tag once it's parameterized.

setup() {
	load test_helper
	# shellcheck source=../../lib/constants.bash
	source "$SCT_LIBDIR/constants.bash"

	REPO_ROOT="$SCT_ROOT/.."
	ENV_FILE="$REPO_ROOT/images/mitmproxy.env"
}

@test "images/mitmproxy.env exists" {
	[ -f "$ENV_FILE" ]
}

@test "SCT_MITMPROXY_VERSION matches MITMPROXY_VERSION in images/mitmproxy.env" {
	local env_version
	env_version="$(grep -m1 '^MITMPROXY_VERSION=' "$ENV_FILE" | cut -d= -f2-)"

	assert_equal "$SCT_MITMPROXY_VERSION" "$env_version"
}

@test "images/mitmproxy/Dockerfile takes MITMPROXY_VERSION as a build arg with no default" {
	run grep -xF 'ARG MITMPROXY_VERSION' "$REPO_ROOT/images/mitmproxy/Dockerfile"
	assert_success
}

@test "images/mitmproxy/Dockerfile FROM is parameterized on MITMPROXY_VERSION" {
	run grep -xF 'FROM mitmproxy/mitmproxy:${MITMPROXY_VERSION}' "$REPO_ROOT/images/mitmproxy/Dockerfile"
	assert_success
}

@test "images/mitmproxy-pass/Dockerfile takes MITMPROXY_VERSION as a build arg with no default" {
	run grep -xF 'ARG MITMPROXY_VERSION' "$REPO_ROOT/images/mitmproxy-pass/Dockerfile"
	assert_success
}

@test "images/mitmproxy-pass/Dockerfile FROM is parameterized on MITMPROXY_VERSION" {
	run grep -xF 'FROM mitmproxy/mitmproxy:${MITMPROXY_VERSION}' "$REPO_ROOT/images/mitmproxy-pass/Dockerfile"
	assert_success
}
