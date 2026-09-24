#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/platform.sh"
source "$ROOT_DIR/versions.lock"

usage() {
  cat <<'EOF'
Usage: sudo bash docker/deploy.sh {preflight|install|check|renew|derpmap|logs} [docker/config.env]

preflight  Validate config and inspect Docker/ports; read-only.
install    Install Docker/Compose if missing, then start the prebuilt image or build it.
check      Check container health, certificate and tailnet identity.
renew      Run the scheduled renewal path now (without forcing CA issuance).
derpmap    Print the node's policy fragment; merge it into the existing policy.
logs       Follow container logs (including the interactive login URL).

Optional IMAGE_ARCHIVE=/path/to/image.tar loads a prebuilt image before install.
EOF
}

compose() {
  docker compose --project-directory "$ROOT_DIR/docker" \
    --env-file "$ROOT_DIR/versions.lock" --env-file "$CONFIG_FILE" \
    -f "$ROOT_DIR/docker/compose.yaml" "$@"
}

docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

docker_plugin_package() {
  local plugin=$1
  if [[ $DOCKER_AUTO_INSTALL == ubuntu ]] && \
     ! dpkg-query -W -f='${Status}' docker-ce-cli 2>/dev/null | grep -qx 'install ok installed'; then
    if [[ $plugin == compose ]]; then
      printf 'docker-compose-v2\n'
    else
      printf 'docker-buildx\n'
    fi
  else
    printf 'docker-%s-plugin\n' "$plugin"
  fi
}

setup_docker_debian_repo() {
  need apt-get
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL https://download.docker.com/linux/debian/gpg -o "$tmp/docker.asc"
  cat > "$tmp/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $PKG_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  if [[ -e /etc/apt/sources.list.d/docker.sources ]] && \
     ! cmp -s "$tmp/docker.sources" /etc/apt/sources.list.d/docker.sources; then
    rm -rf "$tmp"
    die "Existing Docker apt source differs; inspect it before replacing."
  fi
  install -D -m 0644 "$tmp/docker.asc" /etc/apt/keyrings/docker.asc
  install -D -m 0644 "$tmp/docker.sources" /etc/apt/sources.list.d/docker.sources
  rm -rf "$tmp"
  apt-get update
}

setup_docker_rpm_repo() {
  need dnf
  dnf install -y ca-certificates curl
  local tmp
  tmp=$(mktemp)
  curl -fsSL "https://download.docker.com/linux/$DOCKER_AUTO_INSTALL/docker-ce.repo" -o "$tmp"
  grep -qx '\[docker-ce-stable\]' "$tmp" || die "Unexpected Docker RPM repository definition."
  if [[ -e /etc/yum.repos.d/docker-ce.repo ]] && \
     ! cmp -s "$tmp" /etc/yum.repos.d/docker-ce.repo; then
    rm -f "$tmp"
    die "Existing Docker RPM source differs; inspect it before replacing."
  fi
  install -D -m 0644 "$tmp" /etc/yum.repos.d/docker-ce.repo
  rm -f "$tmp"
}

install_docker_engine() {
  case "$DOCKER_AUTO_INSTALL" in
    ubuntu)
      need apt-get
      log "Installing Ubuntu's docker.io and docker-compose-v2 packages."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y docker.io docker-compose-v2
      ;;
    debian)
      log "Installing Docker Engine and Compose from Docker's Debian repository."
      setup_docker_debian_repo
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    fedora|rhel)
      log "Installing Docker Engine and Compose from Docker's $DOCKER_AUTO_INSTALL repository."
      setup_docker_rpm_repo
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    *) die "Install Docker Engine and Compose v2 for $PLATFORM_ID $PLATFORM_VERSION, then rerun." ;;
  esac
}

install_docker_plugin() {
  local plugin=$1 package
  [[ $DOCKER_AUTO_INSTALL != manual ]] \
    || die "Install Docker $plugin for $PLATFORM_ID $PLATFORM_VERSION, then rerun."
  package=$(docker_plugin_package "$plugin")
  if [[ $PKG_FAMILY == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "$package"
  else
    dnf install -y "$package"
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    install_docker_engine
  fi
  if ! docker_ready && command -v systemctl >/dev/null 2>&1; then
    # Package reinstall can leave an active socket unit without an open fd.
    # dockerd uses -H fd:// and needs a fresh systemd socket activation fd.
    systemctl reset-failed docker.service
    if systemctl cat docker.socket >/dev/null 2>&1; then
      systemctl reset-failed docker.socket
      systemctl enable docker.socket
      systemctl restart docker.socket
    fi
    systemctl enable --now docker.service
  fi
  docker_ready || die "Docker daemon is unavailable. Inspect docker.service and socket permissions."
  if ! docker compose version >/dev/null 2>&1; then
    install_docker_plugin compose
  fi
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is unavailable."
}

ensure_buildx() {
  if docker buildx version >/dev/null 2>&1; then
    return
  fi
  log "Installing Docker Buildx for the local image build."
  install_docker_plugin buildx
  docker buildx version >/dev/null 2>&1 || die "Docker Buildx is unavailable."
}

preflight() {
  detect_platform
  load_config "$CONFIG_FILE"
  [[ ${AUTH_MODE:-} == interactive || ${AUTH_MODE:-} == authkey ]] \
    || die "AUTH_MODE must be interactive or authkey."
  [[ $DERP_PORT != 80 && $DERP_PORT != "$STUN_PORT" ]] \
    || die "DERP_PORT must differ from TCP 80 and STUN_PORT."
  [[ -d /run/systemd/system ]] || die "The Docker host needs systemd for automatic Engine startup."
  if docker_ready; then
    log "Docker Engine is running."
  else
    log "Docker Engine is missing or stopped; install will use the $DOCKER_AUTO_INSTALL path if needed."
  fi
  local managed_running=false container_id
  if docker_ready; then
    container_id=$(compose ps -q derp 2>/dev/null || true)
    if [[ -n $container_id && $(docker inspect --format '{{.State.Running}}' "$container_id") == true ]]; then
      managed_running=true
    fi
  fi
  if [[ $managed_running == false ]] && command -v ss >/dev/null 2>&1; then
    local port
    for port in 80 "$DERP_PORT"; do
      if ss -H -ltn "sport = :$port" | grep -q .; then
        log "TCP $port is already listening; install may fail if it belongs to another service."
      fi
    done
    if ss -H -lun "sport = :$STUN_PORT" | grep -q .; then
      log "UDP $STUN_PORT is already listening; install may fail if it belongs to another service."
    fi
  fi
  log "Verify cloud ingress: TCP 80/$DERP_PORT, UDP $STUN_PORT; retain SSH."
}

main() {
  local action=${1:-}
  [[ $action == preflight || $action == install || $action == check || \
     $action == renew || $action == derpmap || $action == logs ]] || { usage; exit 2; }
  CONFIG_FILE=${2:-$ROOT_DIR/docker/config.env}
  [[ -f $CONFIG_FILE ]] || die "Configuration file not found: $CONFIG_FILE"
  if [[ $action == install ]]; then
    require_root
    detect_platform
    if ! command -v python3 >/dev/null 2>&1; then
      if [[ $PKG_FAMILY == apt ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y python3
      else
        dnf install -y python3
      fi
    fi
  fi
  case "$action" in
    preflight) preflight ;;
    derpmap) bash "$ROOT_DIR/install.sh" derpmap "$CONFIG_FILE" ;;
    logs) require_root; compose logs -f derp ;;
    check)
      require_root
      docker_ready || die "Docker Engine is unavailable."
      compose exec -T derp /usr/local/bin/derp-container-healthcheck
      [[ $(compose ps -q derp | xargs -r docker inspect --format '{{.State.Health.Status}}') == healthy ]] \
        || die "Container health status is not healthy."
      log "Docker DERP certificate, tailnet identity and served TLS are healthy."
      ;;
    renew)
      require_root
      docker_ready || die "Docker Engine is unavailable."
      local before line generation result i
      before=$(compose exec -T derp cat /run/derp-bootstrap/last-renew 2>/dev/null || true)
      before=${before%% *}
      [[ $before =~ ^[0-9]+$ ]] || before=0
      compose exec -T derp bash -c 'kill -USR1 "$(cat /run/derp-bootstrap/supervisor.pid)"'
      for ((i=0; i<150; i++)); do
        line=$(compose exec -T derp cat /run/derp-bootstrap/last-renew 2>/dev/null || true)
        read -r generation result <<<"$line"
        if [[ $generation =~ ^[0-9]+$ ]] && ((generation > before)); then
          [[ $result == ok ]] || die "Certificate renewal check failed; inspect container logs."
          compose exec -T derp /usr/local/bin/derp-container-healthcheck
          log "Certificate renewal path and served TLS passed."
          return
        fi
        sleep 2
      done
      die "Timed out waiting for certificate renewal check."
      ;;
    install)
      require_root
      preflight
      ensure_docker
      install -d -m 0700 "$ROOT_DIR/docker/secrets" "$ROOT_DIR/docker/state" \
        "$ROOT_DIR/docker/state/tailscale" "$ROOT_DIR/docker/state/letsencrypt" \
        "$ROOT_DIR/docker/state/derper"
      if [[ ${AUTH_MODE:-} == authkey && ! -e $ROOT_DIR/docker/state/tailscale/tailscaled.state ]]; then
        [[ -f $ROOT_DIR/docker/secrets/auth.key && \
           $(stat -c '%a' "$ROOT_DIR/docker/secrets/auth.key") == 600 ]] \
          || die "Headless enrollment needs docker/secrets/auth.key with mode 0600."
      fi
      if [[ -n ${IMAGE_ARCHIVE:-} ]]; then
        [[ -f $IMAGE_ARCHIVE ]] || die "Image archive does not exist: $IMAGE_ARCHIVE"
        docker load -i "$IMAGE_ARCHIVE"
      fi
      if ! docker image inspect "derp-bootstrap:$TAILSCALE_VERSION" >/dev/null 2>&1; then
        log "Image is absent; building it. Public image registries and Go modules must be reachable."
        ensure_buildx
        compose build derp
      fi
      if [[ $AUTH_MODE == authkey ]]; then
        compose up -d --wait --wait-timeout 900 --no-build --pull never
        compose exec -T derp /usr/local/bin/derp-container-healthcheck
        log "Headless installation completed and passed health checks."
      else
        compose up -d --no-build --pull never
        log "Container started. The interactive login URL is in docker/deploy.sh logs."
      fi
      ;;
  esac
}

main "$@"
