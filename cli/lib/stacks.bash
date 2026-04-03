#!/usr/bin/env bash
# Development stack definitions for sandcat init.
# Uses case functions instead of associative arrays for Bash 3.2 compatibility.

STACK_NAMES=(node python java rust go scala ruby dotnet)

# Returns the mise install command for a stack.
stack_mise_cmd() {
	case $1 in
		node)   echo "mise use -g node@lts" ;;
		python) echo "mise use -g python@3" ;;
		java)   echo "mise use -g java@lts" ;;
		rust)   echo "mise use -g rust@latest" ;;
		go)     echo "mise use -g go@latest" ;;
		scala)  echo "mise use -g scala@latest && mise use -g sbt@latest && mise use -g scala-cli@latest" ;;
		ruby)   echo "mise use -g ruby@latest" ;;
		dotnet) echo "mise use -g dotnet@latest" ;;
		zig)    echo "mise use -g zig@latest" ;;
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
		dotnet) echo "ziglang.vscode-zig" ;;
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
