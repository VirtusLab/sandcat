#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../lib/stacks.bash
	source "$SCT_LIBDIR/stacks.bash"
}

teardown() {
	unstub_all
}

@test "stack_devbox_packages returns package specs for each stack" {
	run stack_devbox_packages node
	assert_output "nodejs@lts"

	run stack_devbox_packages python
	assert_output "python@latest"

	run stack_devbox_packages java
	assert_output "temurin-bin-25@latest"

	run stack_devbox_packages rust
	assert_output "rustc@latest cargo@latest"

	run stack_devbox_packages go
	assert_output "go@latest"

	run stack_devbox_packages scala
	assert_output "scala@latest sbt@latest scala-cli@latest"

	run stack_devbox_packages ruby
	assert_output "ruby@latest"

	run stack_devbox_packages dotnet
	assert_output "dotnet-sdk@latest"

	run stack_devbox_packages zig
	assert_output "zig@latest"
}

@test "stack_devbox_packages returns empty for unknown stack" {
	run stack_devbox_packages nosuchstack
	assert_output ""
}

@test "stack_devbox_packages omits openjdk from scala (java dep supplies it)" {
	# Verifies the merge-conflict trap explained in the stacks.bash doc:
	# both java and scala contributing openjdk would blow up when scala
	# is selected (which triggers java as a dep). We rely on stack_deps
	# to provide openjdk transitively.
	run stack_devbox_packages scala
	refute_output --partial "openjdk"
}

@test "stack_extension returns extension ID for stacks with extensions" {
	run stack_extension python
	assert_output "ms-python.python"

	run stack_extension java
	assert_output "redhat.java"

	run stack_extension rust
	assert_output "rust-lang.rust-analyzer"

	run stack_extension go
	assert_output "golang.go"

	run stack_extension scala
	assert_output "scalameta.metals"

	run stack_extension ruby
	assert_output "shopify.ruby-lsp"

	run stack_extension dotnet
	assert_output "ms-dotnettools.csdevkit"

	run stack_extension zig
	assert_output "ziglang.vscode-zig"
}

@test "stack_extension returns empty for node" {
	run stack_extension node
	assert_output ""
}

@test "stack_deps returns java for scala" {
	run stack_deps scala
	assert_output "java"
}

@test "stack_deps returns empty for non-dependent stacks" {
	run stack_deps node
	assert_output ""

	run stack_deps python
	assert_output ""
}

@test "resolve_stacks adds java before scala" {
	run resolve_stacks scala
	assert_output "java scala"
}

@test "resolve_stacks does not duplicate java when both selected" {
	run resolve_stacks java scala
	assert_output "java scala"
}

@test "resolve_stacks preserves order for independent stacks" {
	run resolve_stacks python node rust
	assert_output "python node rust"
}

@test "resolve_stacks handles single stack" {
	run resolve_stacks python
	assert_output "python"
}

@test "resolve_stacks handles empty input" {
	run resolve_stacks
	assert_output ""
}

@test "validate_stacks accepts valid stack names" {
	run validate_stacks node python java
	assert_success
}

@test "validate_stacks rejects invalid stack name" {
	run validate_stacks node invalid python
	assert_failure
	assert_output --partial "Invalid stack: invalid"
}

@test "validate_stacks lists available stacks on failure" {
	run validate_stacks invalid
	assert_failure
	assert_output --partial "expected:"
}
