#!/usr/bin/env bash
# Select wrappers, can be replaced with more advanced alternatives, e.g. whiplash

# Prompts the user for a yes/no answer.
# Args:
#   $1 - The prompt text to display
# Outputs:
#   "true" if the user answered "yes", "false" otherwise
select_yes_no() {
	local prompt="$1"
	local answer

	read -rp "$prompt [y/N]: " answer >&2
	if [[ $answer =~ ^[Yy]$ ]]
	then
		echo "true"
	else
		echo "false"
	fi
}

# Prompts the user to select one option from a list.
# Args:
#   $1 - The prompt text to display
#   $@ - The options to present (remaining arguments)
# Outputs:
#   The selected option to stdout
select_option() {
	local prompt="$1"
	shift
	local options=("$@")
	local default="${options[0]}"
	local i

	printf '%s\n' "$prompt [$default]" >&2
	for i in "${!options[@]}"; do
		echo "  $((i+1))) ${options[$i]}" >&2
	done

	local reply
	while true; do
		read -rp "> " reply >&2
		if [[ -z $reply ]]; then
			printf '%s\n' "$default"
			return
		fi
		if [[ $reply =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#options[@]} )); then
			printf '%s\n' "${options[$((reply-1))]}"
			return
		fi
		echo "Invalid selection, try again." >&2
	done
}

# Prompts the user to select zero or more options from a list.
# Shows a numbered list; user types comma-separated numbers (e.g. "1,3,5").
# Empty input selects nothing (or selects defaults if provided).
# Args:
#   $1 - The prompt text to display
#   $@ - The options to present, optionally followed by -- and default selections
# Example:
#   select_multiple "Pick features:" tui 1password -- 1password
# Outputs:
#   Space-separated list of selected options to stdout (empty if none selected)
select_multiple() {
	local prompt="$1"
	shift

	# Split args on -- into options and defaults
	local options=()
	local defaults=()
	local seen_separator=false
	for arg in "$@"; do
		if [[ "$arg" == "--" ]]; then
			seen_separator=true
			continue
		fi
		if [[ "$seen_separator" == "true" ]]; then
			defaults+=("$arg")
		else
			options+=("$arg")
		fi
	done

	printf '%s\n' "$prompt" >&2
	local i
	for i in "${!options[@]}"; do
		local marker=""
		local d
		for d in ${defaults[@]+"${defaults[@]}"}; do
			if [[ "$d" == "${options[$i]}" ]]; then
				marker=" (default)"
				break
			fi
		done
		echo "  $((i+1))) ${options[$i]}$marker" >&2
	done

	local reply
	while true; do
		read -rp "> " reply >&2
		if [[ -z $reply ]]; then
			# Return defaults on empty input
			echo "${defaults[*]+${defaults[*]}}"
			return
		fi

		local result=""
		local valid=true
		local num
		local -a nums
		IFS=',' read -ra nums <<< "$reply"
		for num in "${nums[@]}"; do
			num=$(echo "$num" | tr -d ' ')
			if [[ $num =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#options[@]} )); then
				if [[ -n "$result" ]]; then
					result="$result ${options[$((num-1))]}"
				else
					result="${options[$((num-1))]}"
				fi
			else
				echo "Invalid selection: $num" >&2
				valid=false
				break
			fi
		done

		if [[ "$valid" == "true" ]]; then
			echo "$result"
			return
		fi
	done
}

# Prompts the user to enter a single line of text.
# Args:
#   $1 - The prompt text to display
# Outputs:
#   The entered text to stdout
read_line() {
	local prompt="$1"
	local input

	read -rp "$prompt " input >&2
	printf '%s\n' "$input"
}

# Opens a file in the user's preferred editor.
# Args:
#   $1 - The file path to open
# Environment:
#   EDITOR - Preferred editor command (fallback: open, vi)
#   VISUAL - Visual editor command (takes precedence over EDITOR)
open_editor() {
	local file="$1"

	local editor="${VISUAL:-${EDITOR:-$(command -v open || echo vi)}}"

	if ! command -v "${editor%% *}" &>/dev/null
	then
		echo "$0: editor '$editor' not found. Set EDITOR or VISUAL environment variable." >&2
		return 1
	fi

	local -a editor_cmd
	read -ra editor_cmd <<<"$editor"

	if [[ ${editor_cmd[0]} == */open ]]
	then
		"${editor_cmd[@]}" --new --wait-apps "$file" </dev/tty >/dev/tty
	else
		"${editor_cmd[@]}" "$file" </dev/tty >/dev/tty
	fi

}
