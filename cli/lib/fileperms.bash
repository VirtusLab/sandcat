#!/usr/bin/env bash

# Restricts a file holding credentials to its owner.
#
# Best-effort on purpose: a file left behind by another user, or a filesystem
# that ignores modes, warns instead of aborting the caller — those setups
# worked before sandcat started tightening modes, and init has no reason to
# die over them.
#
# Args:
#   $1 - Path to the file
restrict_to_owner() {
	local file=$1
	local err

	if ! err=$(chmod 600 "$file" 2>&1); then
		echo "Could not restrict $file: ${err:-unknown error}" | warning
		echo "It may be readable by other users on this host — fix with: chmod 600 $file" | warning
	fi
}
