#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/init
	source "$SCT_LIBEXECDIR/init/init"

	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME"
}

teardown() {
	unstub_all
}

@test "create_user_settings creates file when not present" {
	stub git \
		"config --global user.name : echo 'Test User'" \
		"config --global user.email : echo 'test@example.com'"

	create_user_settings

	[[ -f "$HOME/.config/sandcat/settings.json" ]]
}

@test "create_user_settings derives git identity" {
	stub git \
		"config --global user.name : echo 'Test User'" \
		"config --global user.email : echo 'test@example.com'"

	create_user_settings

	local settings="$HOME/.config/sandcat/settings.json"
	run yq -r '.env.GIT_USER_NAME' "$settings"
	assert_output "Test User"

	run yq -r '.env.GIT_USER_EMAIL' "$settings"
	assert_output "test@example.com"
}

@test "create_user_settings falls back to placeholders when git config missing" {
	stub git \
		"config --global user.name : exit 1" \
		"config --global user.email : exit 1"

	create_user_settings

	local settings="$HOME/.config/sandcat/settings.json"
	run yq -r '.env.GIT_USER_NAME' "$settings"
	assert_output "Your Name"

	run yq -r '.env.GIT_USER_EMAIL' "$settings"
	assert_output "you@example.com"
}

@test "create_user_settings includes ANTHROPIC_API_KEY secret" {
	stub git \
		"config --global user.name : echo ''" \
		"config --global user.email : echo ''"

	create_user_settings

	local settings="$HOME/.config/sandcat/settings.json"
	run yq -r '.secrets.ANTHROPIC_API_KEY.hosts[0]' "$settings"
	assert_output "api.anthropic.com"
}

@test "create_user_settings includes GITHUB_TOKEN secret" {
	stub git \
		"config --global user.name : echo ''" \
		"config --global user.email : echo ''"

	create_user_settings

	local settings="$HOME/.config/sandcat/settings.json"
	run yq -r '.secrets.GITHUB_TOKEN.hosts[0]' "$settings"
	assert_output "github.com"
}

@test "create_user_settings includes CURSOR_API_KEY secret" {
	stub git \
		"config --global user.name : echo ''" \
		"config --global user.email : echo ''"

	create_user_settings cursor

	local settings="$HOME/.config/sandcat/settings.json"
	run yq -r '.secrets.CURSOR_API_KEY.hosts[0]' "$settings"
	assert_output "api.cursor.sh"
}

@test "create_user_settings for cursor does not include ANTHROPIC_API_KEY" {
	stub git \
		"config --global user.name : echo ''" \
		"config --global user.email : echo ''"

	create_user_settings cursor

	local settings="$HOME/.config/sandcat/settings.json"
	yq -e '.secrets | has("ANTHROPIC_API_KEY") | not' "$settings"
}

@test "create_user_settings includes network rules" {
	stub git \
		"config --global user.name : echo ''" \
		"config --global user.email : echo ''"

	create_user_settings

	local settings="$HOME/.config/sandcat/settings.json"
	yq -e '.network[] | select(.host == "*.github.com")' "$settings"
	yq -e '.network[] | select(.host == "*.anthropic.com")' "$settings"
	yq -e '.network[] | select(.host == "*.claude.com")' "$settings"
}

@test "create_user_settings for cursor includes cursor network rules" {
	stub git \
		"config --global user.name : echo ''" \
		"config --global user.email : echo ''"

	create_user_settings cursor

	local settings="$HOME/.config/sandcat/settings.json"
	yq -e '.network[] | select(.host == "*.cursor.sh")' "$settings"
	yq -e '.network[] | select(.host == "*.cursor.com")' "$settings"
	yq -e '.cursor.cli.network.useHttp1ForAgent == true' "$settings"
	yq -e '.cursor.cli.version == 1' "$settings"
}

@test "create_user_settings creates files readable only by their owner" {
	stub git \
		"config --global user.name : echo ''" \
		"config --global user.email : echo ''"

	create_user_settings

	run file_mode "$HOME/.config/sandcat/settings.json"
	assert_output "600"

	run file_mode "$HOME/.config/sandcat"
	assert_output "700"
}

@test "create_user_settings warns instead of failing when the mode cannot be changed" {
	mkdir -p "$HOME/.config/sandcat"
	echo '{}' > "$HOME/.config/sandcat/settings.json"
	stub chmod "600 $HOME/.config/sandcat/settings.json : exit 1"

	run create_user_settings

	assert_success
	assert_output --partial "Could not restrict"
}

@test "create_user_settings tightens an existing world-readable settings file" {
	mkdir -p "$HOME/.config/sandcat"
	echo '{"secrets":{"ANTHROPIC_API_KEY":{"value":"real"}}}' > "$HOME/.config/sandcat/settings.json"
	chmod 644 "$HOME/.config/sandcat/settings.json"

	create_user_settings

	run file_mode "$HOME/.config/sandcat/settings.json"
	assert_output "600"
}

@test "create_user_settings skips when file already exists" {
	mkdir -p "$HOME/.config/sandcat"
	echo '{"existing": true}' > "$HOME/.config/sandcat/settings.json"

	create_user_settings

	run yq '.existing' "$HOME/.config/sandcat/settings.json"
	assert_output "true"
}

@test "ensure_cursor_user_settings_defaults backfills missing cursor hosts" {
	mkdir -p "$HOME/.config/sandcat"
	cat > "$HOME/.config/sandcat/settings.json" <<'EOF'
{
  "env": {
    "GIT_USER_NAME": "Test"
  },
  "secrets": {
    "CURSOR_API_KEY": {
      "value": "existing-key",
      "hosts": ["api.cursor.sh"]
    }
  }
}
EOF

	ensure_cursor_user_settings_defaults

	local settings="$HOME/.config/sandcat/settings.json"
	run yq -r '.secrets.CURSOR_API_KEY.value' "$settings"
	assert_output "existing-key"
	yq -e '.secrets.CURSOR_API_KEY.hosts[] | select(. == "api.cursor.sh")' "$settings"
	yq -e '.secrets.CURSOR_API_KEY.hosts[] | select(. == "api2.cursor.sh")' "$settings"
	yq -e '.secrets.CURSOR_API_KEY.hosts[] | select(. == "*.cursor.sh")' "$settings"
	yq -e '.secrets.CURSOR_API_KEY.hosts[] | select(. == "*.cursor.com")' "$settings"
	yq -e '.cursor.cli.network.useHttp1ForAgent == true' "$settings"
}

@test "ensure_cursor_user_settings_defaults preserves explicit cursor.cli overrides" {
	mkdir -p "$HOME/.config/sandcat"
	cat > "$HOME/.config/sandcat/settings.json" <<'EOF'
{
  "cursor": {
    "cli": {
      "network": {
        "useHttp1ForAgent": false
      }
    }
  }
}
EOF

	ensure_cursor_user_settings_defaults

	local settings="$HOME/.config/sandcat/settings.json"
	yq -e '.cursor.cli.network.useHttp1ForAgent == false' "$settings"
}
