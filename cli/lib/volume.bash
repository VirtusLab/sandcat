#!/usr/bin/env bash

# shellcheck source=logging.bash
source "$SCT_LIBDIR/logging.bash"
# shellcheck source=require.bash
source "$SCT_LIBDIR/require.bash"

# Parse a Docker ISO-8601 timestamp to epoch seconds (GNU date or BSD date).
_volume_timestamp_epoch() {
	local timestamp=$1
	local no_frac epoch bsd

	no_frac=$(printf '%s' "$timestamp" | sed -E 's/\.[0-9]+//')

	if epoch=$(date -d "$timestamp" +%s 2>/dev/null); then
		printf '%s' "$epoch"
		return 0
	fi
	if epoch=$(date -d "$no_frac" +%s 2>/dev/null); then
		printf '%s' "$epoch"
		return 0
	fi
	if [[ "$no_frac" == *Z ]] && epoch=$(date -d "${no_frac%Z} UTC" +%s 2>/dev/null); then
		printf '%s' "$epoch"
		return 0
	fi

	bsd=$no_frac
	if [[ "$bsd" == *Z ]]; then
		bsd="${bsd%Z}+0000"
	elif [[ "$bsd" =~ ([+-][0-9]{2}):([0-9]{2})$ ]]; then
		bsd=$(printf '%s' "$bsd" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
	fi
	if epoch=$(date -ju -f '%Y-%m-%dT%H:%M:%S%z' "$bsd" +%s 2>/dev/null); then
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

# Prints host-scoped sandcat-cache-* names declared as top-level volume
# keys in a compose file (one name per line). Grep, not yq: Cursor's
# initializeCommand PATH often lacks Homebrew yq, and a silent no-op
# leaves `docker compose up` failing with "external volume not found".
#
# Matches YAML keys (`  sandcat-cache-coursier:`) and not service mounts
# (`- sandcat-cache-coursier:/home/vscode/.cache/coursier`).
#
# Args:
#   $1 - Path to a compose YAML file
_shared_cache_volume_names_from_file() {
	local file=$1
	[[ -f "$file" ]] || return 0
	grep -E '^[[:space:]]+sandcat-cache-[A-Za-z0-9_-]+:[[:space:]]*$' "$file" \
		| sed -E 's/^[[:space:]]+//; s/:[[:space:]]*$//' \
		|| true
}

# Prints Compose include paths from a compose file (one relative path per
# line). Avoids yq for the same PATH reason as volume-name scraping.
#
# Args:
#   $1 - Path to a compose YAML file
_compose_include_paths_from_file() {
	local file=$1
	[[ -f "$file" ]] || return 0
	grep -E '^[[:space:]]*-[[:space:]]+path:[[:space:]]+' "$file" \
		| sed -E 's/^[[:space:]]*-[[:space:]]+path:[[:space:]]+//; s/[[:space:]]*$//' \
		|| true
}

# Ensures every external volume referenced by the compose file exists on
# the host — otherwise `docker compose up` fails with "external volume
# not found". Docker's `volume create` is idempotent, so we can call it
# unconditionally on every sandcat run.
#
# Scoped to sandcat-cache-* names (the shared JVM dependency caches
# declared by add_shared_cache_volumes). We deliberately don't touch
# other external volumes users might add by hand.
#
# Follows Compose `include:` paths and always scans sandcat/compose-agent.yml
# when present. After the agent-service split, cache volumes live there,
# not in compose-all.yml — callers still pass compose-all.yml
# (find_compose_file).
#
# Args:
#   $1 - Path to the compose file
ensure_shared_cache_volumes() {
	local compose_file=$1

	command -v docker &>/dev/null || return 0
	[[ -f "$compose_file" ]] || return 0

	local compose_dir names include_path included
	compose_dir=$(dirname "$compose_file")
	names=$(_shared_cache_volume_names_from_file "$compose_file")
	while IFS= read -r include_path; do
		[[ -n "$include_path" ]] || continue
		names+=$'\n'
		names+=$(_shared_cache_volume_names_from_file "$compose_dir/$include_path")
	done < <(_compose_include_paths_from_file "$compose_file")

	included="$compose_dir/sandcat/compose-agent.yml"
	if [[ -f "$included" ]]; then
		names+=$'\n'
		names+=$(_shared_cache_volume_names_from_file "$included")
	fi

	[[ -n "$names" ]] || return 0

	local name seen=$'\n'
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		case "$seen" in
		*$'\n'"$name"$'\n'*) continue ;;
		esac
		seen+="$name"$'\n'
		docker volume create --label sandcat-shared-cache=true "$name" >/dev/null 2>&1 || true
	done <<< "$names"
}
