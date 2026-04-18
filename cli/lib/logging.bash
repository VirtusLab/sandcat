#!/usr/bin/env bash

# Logging helpers
# Example usage:
# `echo 'Terrible error' | error`

if ! tput sgr0 &>/dev/null
then
	tput() { :; }
fi

_log() {
	local color=$1 label=$2
	local ts line
	# shellcheck disable=SC2312
	ts=$(date +%T)
	while IFS= read -r line; do
		echo -n "$ts "
		tput setaf "$color"
		tput bold
		echo -n "$label "
		tput sgr0
		echo "$line"
	done
} >&2

info()    { _log 4 '[INFO]'; }
warning() { _log 3 '[WARN]'; }
error()   { _log 1 '[ERROR]'; }
