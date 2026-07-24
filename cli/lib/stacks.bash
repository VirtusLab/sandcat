#!/usr/bin/env bash
# Development stack definitions for sandcat init.
# Uses case functions instead of associative arrays for Bash 3.2 compatibility.

STACK_NAMES=(node python java rust go scala ruby dotnet zig)

# Returns space-separated devbox package specs for a stack.
# Format: "<name>@<version>" pairs, where name matches a nixpkgs derivation
# (browse names on https://www.nixhub.io/) and version follows devbox
# resolution rules ("latest", "lts", "3", "3.12", exact versions, etc.).
#
# Dependency packages (e.g. java/openjdk for scala) are NOT listed here —
# stack_deps() handles the transitive resolution and each dep contributes
# its own packages once. This keeps the merge in devbox.stack.json free
# from duplicated entries that would otherwise trigger version-conflict
# detection against the same package name.
stack_devbox_packages() {
	case $1 in
		node)   echo "nodejs@lts" ;;
		python) echo "python@latest" ;;
		java)   echo "temurin-bin-25@latest" ;;
		rust)   echo "rustc@latest cargo@latest" ;;
		go)     echo "go@latest" ;;
		scala)  echo "scala@latest sbt@latest scala-cli@latest" ;;
		ruby)   echo "ruby@latest" ;;
		dotnet) echo "dotnet-sdk@latest" ;;
		zig)    echo "zig@latest" ;;
		*)      echo "" ;;
	esac
}

# Returns the VS Code extension ID for a stack (empty if none).
stack_extension() {
	case $1 in
		python) echo "ms-python.python" ;;
		java)   echo "redhat.java" ;;
		rust)   echo "rust-lang.rust-analyzer" ;;
		go)     echo "golang.go" ;;
		scala)  echo "scalameta.metals" ;;
		ruby)   echo "shopify.ruby-lsp" ;;
		dotnet) echo "ms-dotnettools.csdevkit" ;;
		zig)    echo "ziglang.vscode-zig" ;;
		*)      echo "" ;;
	esac
}

# Returns space-separated dependency stack names (empty if none).
stack_deps() {
	case $1 in
		scala) echo "java" ;;
		*)     echo "" ;;
	esac
}

# Resolves dependencies and deduplicates. Dependencies come before dependents.
# Args: stack names
# Output: space-separated resolved stack list
resolve_stacks() {
	local result=""
	local stack dep
	for stack in "$@"; do
		dep=$(stack_deps "$stack")
		if [[ -n "$dep" ]] && [[ ! " $result " =~ [[:space:]]${dep}[[:space:]] ]]; then
			result="$result $dep"
		fi
		if [[ ! " $result " =~ [[:space:]]${stack}[[:space:]] ]]; then
			result="$result $stack"
		fi
	done
	echo "${result# }"
}

# Validates that all given stack names are known.
# Args: stack names
# Returns: 0 if all valid, 1 with error message if any invalid
validate_stacks() {
	local stack
	for stack in "$@"; do
		local found=false
		local name
		for name in "${STACK_NAMES[@]}"; do
			if [[ "$name" == "$stack" ]]; then
				found=true
				break
			fi
		done
		if [[ "$found" != "true" ]]; then
			local IFS=','
			echo "Invalid stack: $stack (expected: ${STACK_NAMES[*]})"
			return 1
		fi
	done
}
