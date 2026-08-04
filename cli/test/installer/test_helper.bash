#!/bin/bash

bats_require_minimum_version 1.5.0

if shopt -s compat32 2>/dev/null; then
	export BASH_COMPAT=3.2
fi
set -uo pipefail
export SHELLOPTS

SCT_ROOT="$BATS_TEST_DIRNAME/../.."
BATS_LIB_PATH="$SCT_ROOT/support":${BATS_LIB_PATH-}

bats_load_library bats-ext
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-mock-ext

# Path to install.sh under test (relative to cli/test/installer/)
INSTALL_SH="$SCT_ROOT/../install.sh"

export SCT_ROOT INSTALL_SH
