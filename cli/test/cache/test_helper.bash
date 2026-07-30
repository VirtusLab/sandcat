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

export SCT_ROOT
export SCT_LIBDIR="$SCT_ROOT/lib"
export SCT_LIBEXECDIR="$SCT_ROOT/libexec"
