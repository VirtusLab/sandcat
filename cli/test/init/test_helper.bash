#!/bin/bash

bats_require_minimum_version 1.5.0

# Enable Bash 3.2 compat mode when running on Bash 4.4+
# On actual Bash 3.2 (macOS default), these options don't exist and aren't needed.
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

# Octal permission bits of a file. GNU and BSD stat disagree on the flag, so
# pick once by probing stat itself rather than per call — a per-call fallback
# would hide a missing file behind the other flavour's error.
if stat -c '%a' . >/dev/null 2>&1; then
	file_mode() { stat -c '%a' "$1"; }
else
	file_mode() { stat -f '%Lp' "$1"; }
fi

export SCT_ROOT
export SCT_LIBDIR="$SCT_ROOT/lib"
export SCT_TEMPLATEDIR="$SCT_ROOT/templates"
export SCT_LIBEXECDIR="$SCT_ROOT/libexec"
