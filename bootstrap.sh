#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ARCHIVE=https://github.com/Drswith/tailscale-derp-bootstrap/archive/refs/heads/main.tar.gz
SOURCE_DIR=/opt/derp-bootstrap/source
SOURCE_OVERRIDE=false
MODE=
CONFIG_INPUT=
TEMP_DIR=
CREATED_AUTH_FILE=

log() { printf '[derp-bootstrap] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

usage() {
  cat <<'EOF'
Usage: sudo bash bootstrap.sh [--mode native|docker] [--config /path/to/config.env] [--source /path/to/checkout]

Without --config, the script asks for deployment settings on the terminal.
--config uses an operator-owned Bash config file; --mode is required with it.
--source uses an existing complete checkout instead of downloading main.
EOF
}

cleanup() {
  if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  if [[ -n $CREATED_AUTH_FILE && -f $CREATED_AUTH_FILE ]]; then
    rm -f -- "$CREATED_AUTH_FILE"
  fi
}

parse_args() {
  while (($#)); do
    case $1 in
      --mode|--config|--source)
        (($# >= 2)) || die "Missing value for $1"
        case $1 in
          --mode) MODE=$2 ;;
          --config) CONFIG_INPUT=$2 ;;
          --source) SOURCE_DIR=$2; SOURCE_OVERRIDE=true ;;
        esac
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Unknown argument: $1" ;;
    esac
  done
  [[ -z $MODE || $MODE == native || $MODE == docker ]] || die "--mode must be native or docker."
  [[ -z $CONFIG_INPUT || -n $MODE ]] || die "--config requires --mode."
  [[ -z $CONFIG_INPUT || -f $CONFIG_INPUT ]] || die "Configuration file not found: $CONFIG_INPUT"
  [[ $SOURCE_DIR == /* ]] || die "--source must be an absolute path."
}

prompt() {
  local label=$1 default=${2:-} answer
  [[ -r /dev/tty ]] || die "A terminal is required for prompts; pass --mode and --config for automation."
  if [[ -n $default ]]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  IFS= read -r answer </dev/tty || die "Input cancelled."
  printf '%s' "${answer:-$default}"
}

choose_mode() {
  if [[ -z $MODE ]]; then
    MODE=$(prompt '部署模式 native 或 docker' native)
  fi
  [[ $MODE == native || $MODE == docker ]] || die "Deployment mode must be native or docker."
}

ensure_tar() {
  command -v tar >/dev/null 2>&1 && return 0
  [[ -r /etc/os-release ]] || die "Cannot identify the host to install tar."
  local ID=
  # shellcheck disable=SC1091
  source /etc/os-release
  case $ID in
    ubuntu|debian)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y tar ;;
    centos) dnf install -y tar ;;
    *) die "Install tar before running on this host." ;;
  esac
}

fetch_source() {
  if [[ -d $SOURCE_DIR ]]; then
    [[ -f $SOURCE_DIR/install.sh && -f $SOURCE_DIR/docker/deploy.sh && -f $SOURCE_DIR/versions.lock ]] \
      || die "Existing source directory is incomplete: $SOURCE_DIR"
    log "Using existing project at $SOURCE_DIR."
    return
  fi
  [[ $SOURCE_OVERRIDE == false ]] || die "--source must name an existing complete checkout: $SOURCE_DIR"
  need curl
  ensure_tar
  TEMP_DIR=$(mktemp -d)
  install -d -m 0700 "$(dirname -- "$SOURCE_DIR")"
  log "Downloading the complete project from GitHub main."
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 10 \
    "$REPOSITORY_ARCHIVE" -o "$TEMP_DIR/source.tar.gz" \
    || die "Cannot download the project; inspect direct/proxy paths and NO_PROXY."
  install -d -m 0700 "$TEMP_DIR/source"
  tar -xzf "$TEMP_DIR/source.tar.gz" -C "$TEMP_DIR/source" --strip-components=1
  [[ -f $TEMP_DIR/source/install.sh && -f $TEMP_DIR/source/docker/deploy.sh && \
     -f $TEMP_DIR/source/versions.lock ]] || die "Downloaded project archive is incomplete."
  mv -- "$TEMP_DIR/source" "$SOURCE_DIR"
  log "Project saved at $SOURCE_DIR."
}

config_path() {
  if [[ $MODE == native ]]; then
    printf '%s/config.env\n' "$SOURCE_DIR"
  else
    printf '%s/docker/config.env\n' "$SOURCE_DIR"
  fi
}

write_config() {
  local path=$1 auth=$2 name region_name_pattern='^[[:alnum:] ._-]+$'
  local -a fields=(PUBLIC_IPV4 ACME_EMAIL EXPECTED_TAILNET TS_HOSTNAME \
    TS_ADVERTISE_TAGS DERP_PORT STUN_PORT REGION_ID REGION_CODE REGION_NAME)
  # The generated file is read by both Bash and Docker Compose. Restrict prompt
  # values to characters that have identical meaning in their quoted env syntax.
  [[ $PUBLIC_IPV4 =~ ^[0-9.]+$ ]] || die "Public IPv4 contains invalid characters."
  [[ $ACME_EMAIL =~ ^[A-Za-z0-9._+%-]+@[A-Za-z0-9.-]+$ ]] || die "Certificate email contains invalid characters."
  [[ $EXPECTED_TAILNET =~ ^[A-Za-z0-9.-]+$ ]] || die "Tailnet name contains invalid characters."
  [[ $TS_HOSTNAME =~ ^[A-Za-z0-9-]+$ ]] || die "Tailscale hostname contains invalid characters."
  [[ $TS_ADVERTISE_TAGS =~ ^[A-Za-z0-9:,_-]*$ ]] || die "Advertised tags contain invalid characters."
  [[ $DERP_PORT =~ ^[0-9]+$ && $STUN_PORT =~ ^[0-9]+$ && $REGION_ID =~ ^[0-9]+$ ]] \
    || die "Ports and region ID must be numeric."
  [[ $REGION_CODE =~ ^[A-Za-z0-9-]+$ ]] || die "Region code contains invalid characters."
  [[ $REGION_NAME =~ $region_name_pattern ]] || die "Region name allows only letters, numbers, spaces, dots, underscores and hyphens."
  {
    for name in "${fields[@]}"; do
      printf '%s="%s"\n' "$name" "${!name}"
    done
    if [[ $MODE == native ]]; then
      if [[ $auth == headless ]]; then
        printf 'TS_AUTH_KEY_FILE="/run/derp-bootstrap/auth.key"\n'
      else
        printf 'TS_AUTH_KEY_FILE=""\n'
      fi
    else
      if [[ $auth == headless ]]; then
        printf 'AUTH_MODE="authkey"\n'
      else
        printf 'AUTH_MODE="interactive"\n'
      fi
    fi
  } > "$path"
  chmod 0600 "$path"
}

prepare_config() {
  local path=$1 auth
  if [[ -n $CONFIG_INPUT ]]; then
    if [[ -e $path && ! $CONFIG_INPUT -ef $path ]]; then
      die "Refusing to replace existing config: $path"
    fi
    if [[ ! $CONFIG_INPUT -ef $path ]]; then
      install -m 0600 "$CONFIG_INPUT" "$path"
    else
      chmod 0600 "$path"
    fi
    log "Using supplied configuration at $path."
    return
  fi
  if [[ -f $path ]]; then
    log "Reusing existing configuration at $path."
    return
  fi
  PUBLIC_IPV4=$(prompt 'VPS 公网 IPv4')
  ACME_EMAIL=$(prompt '证书通知邮箱')
  EXPECTED_TAILNET=$(prompt 'Tailnet 名称')
  REGION_ID=$(prompt '未占用的 DERP Region ID（900–999）' 900)
  TS_HOSTNAME=$(prompt 'Tailscale 设备名' "derp-$REGION_ID")
  REGION_CODE=$(prompt 'DERP Region Code' "derp-$REGION_ID")
  REGION_NAME=$(prompt 'DERP Region Name' "DERP $REGION_ID")
  DERP_PORT=52625
  STUN_PORT=3478
  auth=$(prompt '入网方式 interactive 或 headless' interactive)
  [[ $auth == interactive || $auth == headless ]] || die "Login mode must be interactive or headless."
  TS_ADVERTISE_TAGS=
  if [[ $auth == headless ]]; then
    TS_ADVERTISE_TAGS=$(prompt '节点 tag（OAuth 客户端需填写，例如 tag:derp）' '')
  fi
  write_config "$path" "$auth"
  log "Configuration saved with mode 0600 at $path."
}

prepare_credential() {
  local config=$1 path= secret
  # Config files are operator-owned Bash files, just like the underlying installers expect.
  # shellcheck disable=SC1090
  source "$config"
  if [[ $MODE == native ]]; then
    path=${TS_AUTH_KEY_FILE:-}
    [[ -n $path ]] || return 0
  else
    [[ ${AUTH_MODE:-} == authkey ]] || return 0
    path="$SOURCE_DIR/docker/secrets/auth.key"
  fi
  [[ -f $path ]] && return
  [[ $path == /run/derp-bootstrap/auth.key || $path == "$SOURCE_DIR/docker/secrets/auth.key" ]] \
    || die "Create the custom auth key file at $path with mode 0600 before running."
  [[ -r /dev/tty ]] || die "Headless enrollment needs a credential file at $path."
  printf '输入 Auth key 或受限 OAuth 客户端 secret（不会回显）: ' >&2
  IFS= read -r -s secret </dev/tty || die "Credential input cancelled."
  printf '\n' >&2
  [[ -n $secret ]] || die "Credential cannot be empty."
  if [[ $secret == tskey-client-* && -z ${TS_ADVERTISE_TAGS:-} ]]; then
    unset secret
    die "OAuth credentials require TS_ADVERTISE_TAGS in the configuration."
  fi
  install -d -m 0700 "$(dirname -- "$path")"
  printf '%s' "$secret" > "$path"
  chmod 0600 "$path"
  unset secret
  CREATED_AUTH_FILE=$path
}

show_docker_login() {
  local config=$1 output= i
  for ((i=0; i<30; i++)); do
    output=$(docker compose --project-directory "$SOURCE_DIR/docker" \
      --env-file "$SOURCE_DIR/versions.lock" --env-file "$config" \
      -f "$SOURCE_DIR/docker/compose.yaml" logs --no-color --tail 100 derp 2>&1 || true)
    if [[ $output == *https://login.tailscale.com/* ]]; then
      printf '%s\n' "$output" >&2
      return
    fi
    sleep 2
  done
  printf '%s\n' "$output" >&2
  die "Login URL did not appear in container logs; inspect docker/deploy.sh logs."
}

run_install() {
  local config=$1 output= i
  if [[ $MODE == native ]]; then
    bash "$SOURCE_DIR/install.sh" install "$config"
    bash "$SOURCE_DIR/install.sh" check "$config"
  else
    bash "$SOURCE_DIR/docker/deploy.sh" install "$config"
    # shellcheck disable=SC1090
    source "$config"
    if [[ $AUTH_MODE == interactive ]]; then
      show_docker_login "$config"
      prompt '完成网页登录与设备批准后按回车继续' '' >/dev/null
      for ((i=0; i<60; i++)); do
        if output=$(bash "$SOURCE_DIR/docker/deploy.sh" check "$config" 2>&1); then
          printf '%s\n' "$output" >&2
          break
        fi
        sleep 5
      done
      ((i < 60)) || die "Container did not become healthy: $output"
    else
      bash "$SOURCE_DIR/docker/deploy.sh" check "$config"
    fi
  fi
  if [[ $MODE == native ]]; then
    bash "$SOURCE_DIR/install.sh" derpmap "$config" > "$SOURCE_DIR/derp-map.json"
  else
    bash "$SOURCE_DIR/docker/deploy.sh" derpmap "$config" > "$SOURCE_DIR/derp-map.json"
  fi
  chmod 0600 "$SOURCE_DIR/derp-map.json"
  log "Server installation and local checks passed. DERP map fragment: $SOURCE_DIR/derp-map.json"
  log "Next: merge that fragment into the tailnet policy, verify cloud ingress, and test a real client relay."
}

main() {
  parse_args "$@"
  [[ $(id -u) == 0 ]] || die "Run with sudo or as root."
  umask 077
  trap cleanup EXIT
  choose_mode
  fetch_source
  local config
  config=$(config_path)
  prepare_config "$config"
  prepare_credential "$config"
  run_install "$config"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
