#!/usr/bin/env bash
# Helpers for the `sandcat cache` command family — inspection and removal
# of the host-scoped shared dependency-cache volumes declared by
# add_shared_cache_volumes() in composefile.bash and lazily created by
# ensure_shared_cache_volumes() in volume.bash.

# Prints the names of all Docker volumes matching the sandcat shared-cache
# label (sandcat-shared-cache=true), one per line. Empty output means no
# shared caches exist yet on this host.
sct_cache_volume_names() {
	docker volume ls -q --filter label=sandcat-shared-cache=true 2>/dev/null | sort
}

# Prints the size of one volume in bytes. Uses a throwaway alpine
# container to du(1) the mount point — Docker Desktop's VM makes host-side
# introspection unreliable, so we go through a container instead.
sct_cache_volume_size_bytes() {
	local name=$1
	docker run --rm -v "$name":/mnt alpine du -sb /mnt 2>/dev/null | awk '{print $1}'
}

# Formats a byte count into a human-readable string (e.g. "12.4 GB").
sct_cache_format_bytes() {
	local bytes=${1:-0}
	awk -v b="$bytes" 'BEGIN {
		split("B KB MB GB TB", units, " ");
		i = 1;
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		if (i == 1) { printf "%d %s", b, units[i] }
		else { printf "%.1f %s", b, units[i] }
	}'
}

# Prints the number of file entries in a volume (recursive). Same
# rationale as sct_cache_volume_size_bytes for going through a container.
sct_cache_volume_file_count() {
	local name=$1
	docker run --rm -v "$name":/mnt alpine sh -c 'find /mnt -type f 2>/dev/null | wc -l' | awk '{print $1}'
}

# Prints the names of all containers currently mounting the given volume.
# Empty output means the volume is free to remove.
sct_cache_volume_containers() {
	local name=$1
	docker ps -a --filter volume="$name" --format '{{.Names}}' 2>/dev/null
}
