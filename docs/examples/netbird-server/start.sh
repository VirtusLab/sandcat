#!/usr/bin/env bash
# Prepare secrets (if missing) and start the example NetBird stack.
#
# Combined netbird-server 0.72 requires a non-empty server.authSecret for the
# embedded relay. store.encryptionKey should stay stable across recreates or
# encrypted setup keys / PATs in the volume become unreadable.
#
# Usage:
#   ./start.sh
#       Generate secrets into netbird-server.env if empty, write
#       config.local.yaml, compose up -d.
#   ./start.sh --secrets-from ~/.config/sandcat/netbird-server/config.yaml
#       Copy authSecret + encryptionKey from that YAML into config.local.yaml
#       only (does not write them to netbird-server.env).
#   ./start.sh --force-recreate netbird-server
#   ./start.sh --prepare-only
#       Secrets + config.local.yaml only (no docker).
set -euo pipefail

cd "$(dirname "$0")"

PREPARE_ONLY=0
SECRETS_FROM="${NETBIRD_SECRETS_CONFIG:-}"
COMPOSE_ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--prepare-only)
		PREPARE_ONLY=1
		shift
		;;
	--secrets-from)
		SECRETS_FROM="${2:?--secrets-from requires a path}"
		shift 2
		;;
	--secrets-from=*)
		SECRETS_FROM="${1#*=}"
		shift
		;;
	*)
		COMPOSE_ARGS+=("$1")
		shift
		;;
	esac
done
export NETBIRD_SECRETS_CONFIG="${SECRETS_FROM}"

python3 - <<'PY'
import os, pathlib, re, secrets, base64, sys

root = pathlib.Path(".")
env_path = root / "netbird-server.env"
cfg_path = root / "config.yaml"
local_path = root / "config.local.yaml"
secrets_from = os.environ.get("NETBIRD_SECRETS_CONFIG", "").strip()

env_text = env_path.read_text()
cfg_text = cfg_path.read_text()


def env_value(text: str, key: str) -> str:
    m = re.search(rf"^{re.escape(key)}=(.*)$", text, flags=re.M)
    if not m:
        return ""
    return m.group(1).strip()


def yaml_scalar(text: str, key: str) -> str:
    m = re.search(rf"^[ \t]*{re.escape(key)}:[ \t]*(.*)$", text, flags=re.M)
    if not m:
        return ""
    raw = m.group(1).strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1].strip()
    return raw


def set_env(text: str, key: str, value: str) -> str:
    if re.search(rf"^{re.escape(key)}=", text, flags=re.M):
        return re.sub(rf"^{re.escape(key)}=.*$", f"{key}={value}", text, flags=re.M)
    if not text.endswith("\n"):
        text += "\n"
    return text + f"{key}={value}\n"


def new_secret() -> str:
    return base64.b64encode(secrets.token_bytes(32)).decode()


mapping = (
    ("NETBIRD_RELAY_AUTH_SECRET", "authSecret"),
    ("NETBIRD_ENCRYPTION_KEY", "encryptionKey"),
)

values = {}
persist_env = True
if secrets_from:
    src = pathlib.Path(secrets_from).expanduser()
    if not src.is_file():
        print(f"start.sh: --secrets-from file not found: {src}", file=sys.stderr)
        sys.exit(1)
    src_text = src.read_text()
    persist_env = False
    for env_key, yaml_key in mapping:
        value = yaml_scalar(src_text, yaml_key)
        if not value:
            print(f"start.sh: {yaml_key} missing in {src}", file=sys.stderr)
            sys.exit(1)
        values[env_key] = value
    print(f"loaded secrets from {src} (not written to netbird-server.env)")
else:
    generated = []
    for env_key, yaml_key in mapping:
        value = env_value(env_text, env_key) or yaml_scalar(cfg_text, yaml_key)
        if not value:
            value = new_secret()
            generated.append(env_key)
        values[env_key] = value
        env_text = set_env(env_text, env_key, value)
    if generated:
        print("generated: " + ", ".join(generated) + " (kept in netbird-server.env)")
    else:
        print("reusing secrets from netbird-server.env")

if persist_env:
    env_path.write_text(env_text)

local = cfg_text
for env_key, yaml_key in mapping:
    local = re.sub(
        rf"^([ \t]*{re.escape(yaml_key)}:[ \t]*).*$",
        rf'\1"{values[env_key]}"',
        local,
        count=1,
        flags=re.M,
    )
local_path.write_text(local)
print(f"wrote {local_path}")
PY

if [[ "$PREPARE_ONLY" -eq 1 ]]; then
	exit 0
fi

if [[ ! -f config.local.yaml ]]; then
	echo "start.sh: config.local.yaml was not written" >&2
	exit 1
fi

exec docker compose --env-file netbird-server.env up -d "${COMPOSE_ARGS[@]}"
