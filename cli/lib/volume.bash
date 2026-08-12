#!/usr/bin/env bash

# shellcheck source=logging.bash
source "$SCT_LIBDIR/logging.bash"
# shellcheck source=require.bash
source "$SCT_LIBDIR/require.bash"

# Parse a Docker ISO-8601 timestamp to epoch seconds (GNU date or BSD date).
_volume_timestamp_epoch() {
	local timestamp=$1
	local normalized epoch

	normalized=$(printf '%s' "$timestamp" | sed -E 's/\.[0-9]+Z$/Z/; s/Z$//')

	if epoch=$(date -d "${normalized} UTC" +%s 2>/dev/null); then
		printf '%s' "$epoch"
		return 0
	fi

	if epoch=$(date -ju -f '%Y-%m-%dT%H:%M:%S' "$normalized" +%s 2>/dev/null); then
		printf '%s' "$epoch"
		return 0
	fi

	return 1
}

# Warns if the agent-home volume is meaningfully older than the agent
# image — i.e. the image has been rebuilt since the volume was populated,
# so packages installed during the build are hidden by the stale volume
# overlay at /home/vscode.
#
# A tolerance is applied because Docker Compose creates named volumes
# before building images on fresh installs, which leaves the image
# naturally a few seconds newer than the volume even when nothing is
# stale. A genuine post-install rebuild produces a much larger gap.
#
# Args:
#   $1 - Path to the compose file
warn_stale_home_volume() {
	local compose_file=$1
	local tolerance_seconds=60

	command -v yq &>/dev/null || return 0

	local project_name
	project_name=$(yq -r '.name // ""' "$compose_file" 2>/dev/null) || return 0
	[[ -n "$project_name" ]] || return 0

	local volume_name="${project_name}_agent-home"
	local image_name="${project_name}-agent"

	# No volume yet (first run) — nothing to warn about.
	docker volume inspect "$volume_name" &>/dev/null || return 0

	local volume_time image_time
	volume_time=$(docker volume inspect --format '{{.CreatedAt}}' "$volume_name" 2>/dev/null) || return 0
	image_time=$(docker image inspect --format '{{.Created}}' "$image_name" 2>/dev/null) || return 0

	# Convert to epoch seconds. Requires GNU date; skip the check
	# silently if unavailable (e.g. BSD date on macOS without coreutils)
	# rather than risk false positives from lexicographic comparison.
	local vol_epoch img_epoch
	vol_epoch=$(_volume_timestamp_epoch "$volume_time") || return 0
	img_epoch=$(_volume_timestamp_epoch "$image_time") || return 0

	(( img_epoch - vol_epoch > tolerance_seconds )) || return 0

	echo "The agent image was rebuilt since the agent-home volume was created." | warning
	echo "Packages installed during the build may not be visible." | warning
	echo "To fix, stop containers and remove the volume:" | warning
	echo "  sandcat compose down && docker volume rm $volume_name" | warning
}
