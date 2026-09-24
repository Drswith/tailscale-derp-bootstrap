#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/bootstrap.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

SOURCE_DIR="$tmp/source"
mkdir -p "$SOURCE_DIR/docker"
PUBLIC_IPV4=1.1.1.1
ACME_EMAIL=operator@example.com
EXPECTED_TAILNET=example.com
TS_HOSTNAME=derp-901
TS_ADVERTISE_TAGS=tag:derp
DERP_PORT=52625
STUN_PORT=3478
REGION_ID=901
REGION_CODE=derp-901
REGION_NAME='DERP Region 901'

MODE=native
write_config "$tmp/native.env" headless
(
  source "$tmp/native.env"
  [[ $REGION_NAME == 'DERP Region 901' ]]
  [[ $TS_AUTH_KEY_FILE == /run/derp-bootstrap/auth.key ]]
  [[ $DERP_PORT == 52625 && $TS_ADVERTISE_TAGS == tag:derp ]]
)
MODE=docker
write_config "$tmp/docker.env" headless
(
  source "$tmp/docker.env"
  [[ $AUTH_MODE == authkey && $REGION_NAME == 'DERP Region 901' ]]
)
REGION_NAME='Name "quoted" $HOME'
if (write_config "$tmp/unsafe.env" headless) >/dev/null 2>&1; then
  echo 'Unsafe cross-parser config value was accepted.' >&2
  exit 1
fi
REGION_NAME='DERP Region 901'
for config in "$tmp/native.env" "$tmp/docker.env"; do
  mode=$(stat -c %a "$config" 2>/dev/null || stat -f %Lp "$config")
  [[ $mode == 600 ]] || { echo "Config is not mode 0600: $config" >&2; exit 1; }
done

cat > "$SOURCE_DIR/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CALL_LOG"
if [[ $1 == derpmap ]]; then printf '{"derpMap":{}}\n'; fi
EOF
cp "$SOURCE_DIR/install.sh" "$SOURCE_DIR/docker/deploy.sh"
printf 'TAILSCALE_VERSION=1.102.4\n' > "$SOURCE_DIR/versions.lock"
export CALL_LOG="$tmp/calls"
MODE=native
run_install "$tmp/native.env"
[[ $(cat "$CALL_LOG") == $'install\ncheck\nderpmap' ]]
python3 -m json.tool "$SOURCE_DIR/derp-map.json" >/dev/null

: > "$CALL_LOG"
MODE=docker
run_install "$tmp/docker.env"
[[ $(cat "$CALL_LOG") == $'install\ncheck\nderpmap' ]]

: > "$CALL_LOG"
write_config "$tmp/docker-interactive.env" interactive
docker() { printf 'Authenticate at https://login.tailscale.com/a/example\n'; }
prompt() { printf '\n'; }
run_install "$tmp/docker-interactive.env"
[[ $(cat "$CALL_LOG") == $'install\ncheck\nderpmap' ]]

if (parse_args --mode unsupported) >/dev/null 2>&1; then
  echo 'Unsupported bootstrap mode was accepted.' >&2
  exit 1
fi

if [[ $(id -u) == 0 ]]; then
  : > "$CALL_LOG"
  MODE=native
  write_config "$tmp/native-interactive.env" interactive
  bash "$ROOT_DIR/bootstrap.sh" --mode native --config "$tmp/native-interactive.env" \
    --source "$SOURCE_DIR" >/dev/null
  [[ $(cat "$CALL_LOG") == $'install\ncheck\nderpmap' ]]

  : > "$CALL_LOG"
  mkdir -p "$SOURCE_DIR/docker/secrets"
  printf 'test-credential' > "$SOURCE_DIR/docker/secrets/auth.key"
  chmod 0600 "$SOURCE_DIR/docker/secrets/auth.key"
  bash "$ROOT_DIR/bootstrap.sh" --mode docker --config "$tmp/docker.env" \
    --source "$SOURCE_DIR" >/dev/null
  [[ $(cat "$CALL_LOG") == $'install\ncheck\nderpmap' ]]
fi

echo 'Bootstrap config escaping, permissions and local-check orchestration passed.'
