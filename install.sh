#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/platform.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh {preflight|install|check|derpmap} [config.env]

preflight  Read-only host and network checks; does not prove cloud ingress.
install    Install or rerun; a lock-file version change upgrades both binaries.
check      Check identity, service, certificate, and served TLS certificate.
derpmap    Print a JSON fragment to merge into the existing tailnet policy.
EOF
}

load_versions() {
  # shellcheck source=versions.lock
  source "$ROOT_DIR/versions.lock"
  [[ $TAILSCALE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid TAILSCALE_VERSION"
  [[ $GO_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid GO_VERSION"
  [[ $CERTBOT_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid CERTBOT_VERSION"
}

read_os() {
  [[ -d /run/systemd/system ]] || die "A systemd-based Linux host is required."
  detect_platform
  case "$(uname -m)" in
    x86_64) GO_ARCH=amd64; GO_SHA256=$GO_LINUX_AMD64_SHA256 ;;
    aarch64) GO_ARCH=arm64; GO_SHA256=$GO_LINUX_ARM64_SHA256 ;;
    *) die "Only x86_64 and aarch64 are supported." ;;
  esac
}

go_archive_url() {
  printf '%s\n' "${GO_ARCHIVE_URL:-https://go.dev/dl/go$GO_VERSION.linux-$GO_ARCH.tar.gz}"
}

listening() {
  local port=$1 protocol=$2
  if [[ $protocol == tcp ]]; then
    ss -H -ltn "sport = :$port" | grep -q .
  else
    ss -H -lun "sport = :$port" | grep -q .
  fi
}

preflight() {
  read_os
  need curl; need openssl; need df
  log "OS: $PLATFORM_ID $PLATFORM_VERSION; architecture: $GO_ARCH; public IPv4: $PUBLIC_IPV4"
  local free_kb
  free_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  ((free_kb >= 2097152)) || die "At least 2 GiB free on / is needed for download and build."
  if command -v timedatectl >/dev/null && [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) != yes ]]; then
    log "WARNING: NTP synchronization is not confirmed; check the server clock."
  fi
  if command -v ss >/dev/null; then
    listening 80 tcp && die "TCP 80 is occupied; Certbot standalone needs it at issuance and renewal."
    local own_derper=false
    [[ -f /etc/derp-bootstrap/config.env ]] && systemctl is-active --quiet derper && own_derper=true
    if [[ $own_derper == false ]]; then
      listening "$DERP_PORT" tcp && die "TCP $DERP_PORT is occupied."
      listening "$STUN_PORT" udp && die "UDP $STUN_PORT is occupied."
    fi
  else
    log "WARNING: ss unavailable; port occupation will be checked after dependencies install."
  fi
  local url repo_probe
  if [[ $PKG_FAMILY == apt ]]; then
    repo_probe="https://pkgs.tailscale.com/stable/$PKG_OS/$PKG_CODENAME.noarmor.gpg"
  else
    repo_probe="https://pkgs.tailscale.com/stable/$PKG_REPO_PATH"
  fi
  for url in "$repo_probe" https://pypi.org/simple/certbot/ \
    https://acme-v02.api.letsencrypt.org/directory \
    https://acme-staging-v02.api.letsencrypt.org/directory; do
    curl -fsSL --max-time 15 -o /dev/null "$url" || die "Cannot reach $url; inspect direct/proxy paths and NO_PROXY before retrying."
  done
  url=$(go_archive_url)
  curl -fsSLI --retry 2 --retry-all-errors --connect-timeout 8 --max-time 15 -o /dev/null "$url" \
    || die "Cannot reach $url; inspect direct/proxy paths and NO_PROXY before retrying."
  [[ ${GOSUMDB:-sum.golang.org} != off ]] || die "GOSUMDB=off is not supported for an official derper build."
  local go_proxies=${GOPROXY:-https://proxy.golang.org,direct}
  local proxy reachable=false tried=false
  go_proxies=${go_proxies//|/,}
  local -a proxy_items
  IFS=, read -r -a proxy_items <<<"$go_proxies"
  for proxy in "${proxy_items[@]}"; do
    [[ $proxy == https://* || $proxy == http://* ]] || continue
    tried=true
    if curl -fsSL --max-time 15 -o /dev/null "${proxy%/}/tailscale.com/@v/v$TAILSCALE_VERSION.info"; then
      reachable=true
      break
    fi
  done
  if [[ $tried == true && $reachable == false ]]; then
    die "Configured GOPROXY endpoints are unreachable; inspect direct/proxy paths or choose a reachable module mirror."
  fi
  if [[ $tried == false ]]; then
    log "GOPROXY has no HTTP module source; the Go build will validate its direct VCS path."
  fi
  local observed
  observed=$(curl --noproxy '*' -fsSL --max-time 8 https://api.ipify.org 2>/dev/null \
    || curl --noproxy '*' -fsSL --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
  if [[ -n $observed && $observed != "$PUBLIC_IPV4" ]]; then
    log "WARNING: direct outbound IPv4 is $observed, different from PUBLIC_IPV4; confirm cloud NAT mapping."
  elif [[ -z $observed ]]; then
    log "WARNING: direct public-IP probe unavailable; confirm public IPv4 and inbound routing separately."
  fi
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    log "Host UFW is active; inspect allow rules for TCP 80/$DERP_PORT, UDP $STUN_PORT and SSH."
  fi
  log "Cloud security group and public ingress remain to be verified: TCP 80/$DERP_PORT, UDP $STUN_PORT, ICMP, and existing SSH. No firewall rules were changed."
}

install_base_packages() {
  if [[ $PKG_FAMILY == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git jq openssl python3 python3-venv \
      iproute2 tar util-linux
  else
    local -a packages=(ca-certificates git jq openssl iproute tar util-linux)
    if [[ $PYTHON_BIN == python3.11 ]]; then
      packages+=(python3.11 python3.11-pip)
    else
      packages+=(python3 python3-pip)
    fi
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    dnf install -y "${packages[@]}"
  fi
}

setup_tailscale_repo() {
  local base tmp
  tmp=$(mktemp -d)
  if [[ $PKG_FAMILY == apt ]]; then
    base="https://pkgs.tailscale.com/stable/$PKG_OS/$PKG_CODENAME"
    curl -fsSL "$base.noarmor.gpg" -o "$tmp/key.gpg"
    curl -fsSL "$base.tailscale-keyring.list" -o "$tmp/tailscale.list"
    if [[ -e /etc/apt/sources.list.d/tailscale.list ]] && ! cmp -s "$tmp/tailscale.list" /etc/apt/sources.list.d/tailscale.list; then
      rm -rf "$tmp"
      die "Existing Tailscale apt source differs; inspect it before replacing."
    fi
    install -D -m 0644 "$tmp/key.gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
    install -D -m 0644 "$tmp/tailscale.list" /etc/apt/sources.list.d/tailscale.list
    apt-get update
  else
    base="https://pkgs.tailscale.com/stable/$PKG_REPO_PATH"
    curl -fsSL "$base" -o "$tmp/tailscale.repo"
    grep -qx '\[tailscale-stable\]' "$tmp/tailscale.repo" \
      || die "Unexpected Tailscale RPM repository definition."
    grep -qx 'repo_gpgcheck=1' "$tmp/tailscale.repo" \
      || die "Tailscale RPM repository signature check is missing."
    sed -i 's/^enabled=1$/enabled=0/' "$tmp/tailscale.repo"
    if [[ -e /etc/yum.repos.d/tailscale.repo ]] && ! cmp -s "$tmp/tailscale.repo" /etc/yum.repos.d/tailscale.repo; then
      rm -rf "$tmp"
      die "Existing Tailscale RPM source differs; inspect it before replacing."
    fi
    install -D -m 0644 "$tmp/tailscale.repo" /etc/yum.repos.d/tailscale.repo
  fi
  rm -rf "$tmp"
  available_tailscale_version "$TAILSCALE_VERSION" \
    || die "Tailscale package $TAILSCALE_VERSION is unavailable in the stable repository."
}

available_tailscale_version() {
  local version=$1
  if [[ $PKG_FAMILY == apt ]]; then
    apt-cache madison tailscale | awk -v v="$version" '$3==v {found=1} END {exit !found}'
  else
    dnf -y --disablerepo='*' --enablerepo=tailscale-stable repoquery \
      --available --qf '%{version}\n' tailscale \
      | awk -v v="$version" '$0==v {found=1} END {exit !found}'
  fi
}

installed_tailscale_version() {
  if [[ $PKG_FAMILY == apt ]]; then
    dpkg-query -W -f='${Version}' tailscale 2>/dev/null || true
  elif rpm -q --quiet tailscale; then
    rpm -q --qf '%{VERSION}' tailscale
  fi
}

install_tailscale_version() {
  local version=$1 current
  if [[ $PKG_FAMILY == apt ]]; then
    apt-get install -y --allow-downgrades "tailscale=$version"
    return
  fi
  current=$(installed_tailscale_version)
  if [[ -n $current && $current != "$version" && \
        $(printf '%s\n%s\n' "$current" "$version" | sort -V | sed -n '1p') == "$version" ]]; then
    dnf --enablerepo=tailscale-stable downgrade -y "tailscale-$version"
  else
    dnf --enablerepo=tailscale-stable install -y "tailscale-$version"
  fi
}

hold_tailscale_package() {
  [[ $PKG_FAMILY != apt ]] || apt-mark hold tailscale >/dev/null
}

unhold_tailscale_package() {
  [[ $PKG_FAMILY != apt ]] || apt-mark unhold tailscale >/dev/null
}

install_tailscale_package() {
  local actual
  actual=$(installed_tailscale_version)
  if [[ -z $actual ]]; then
    install_tailscale_version "$TAILSCALE_VERSION"
  elif [[ $actual != "$TAILSCALE_VERSION" ]]; then
    die "Installed Tailscale is $actual; the managed upgrade path is required."
  fi
  hold_tailscale_package
  systemctl enable --now tailscaled
  [[ $(tailscaled --version | head -n 1) == "$TAILSCALE_VERSION" ]] || die "tailscaled binary version does not match versions.lock."
}

join_tailnet() {
  local status state
  local -a up_args=(--hostname="$TS_HOSTNAME" --accept-dns=false --accept-routes=false)
  if [[ -n $TS_ADVERTISE_TAGS ]]; then
    up_args+=(--advertise-tags="$TS_ADVERTISE_TAGS")
  fi
  status=$(tailscale status --json 2>/dev/null || true)
  state=$(jq -r '.BackendState // ""' <<<"$status" 2>/dev/null || true)
  if [[ $state != Running ]]; then
    if [[ -n $TS_AUTH_KEY_FILE ]]; then
      [[ -f $TS_AUTH_KEY_FILE && $(stat -c '%a' "$TS_AUTH_KEY_FILE") == 600 ]] \
        || die "Auth key file must exist with mode 0600: $TS_AUTH_KEY_FILE"
      tailscale up --auth-key="file:$TS_AUTH_KEY_FILE" "${up_args[@]}"
      if [[ $TS_AUTH_KEY_FILE == /run/derp-bootstrap/auth.key ]]; then
        rm -f -- "$TS_AUTH_KEY_FILE"
      fi
    else
      log "Complete the Tailscale login in the URL printed below."
      tailscale up "${up_args[@]}"
    fi
  fi
  check_tailnet
  log "Tailnet identity is active. Review node key expiry and verify-clients visibility in the Tailscale console."
}

ensure_go() {
  GO_BIN="/opt/derp-bootstrap/toolchains/go$GO_VERSION/bin/go"
  if [[ -x $GO_BIN ]]; then
    [[ $($GO_BIN version) == "go version go$GO_VERSION "* ]] || die "Go toolchain at $GO_BIN is not $GO_VERSION."
    return
  fi
  local tmp archive
  tmp=$(mktemp -d)
  archive="$tmp/go$GO_VERSION.linux-$GO_ARCH.tar.gz"
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 600 \
    "$(go_archive_url)" -o "$archive"
  printf '%s  %s\n' "$GO_SHA256" "$archive" | sha256sum -c - >/dev/null \
    || die "Go toolchain SHA-256 mismatch."
  mkdir -p /opt/derp-bootstrap/toolchains
  tar -xzf "$archive" -C "$tmp"
  mv "$tmp/go" "/opt/derp-bootstrap/toolchains/go$GO_VERSION"
  rm -rf "$tmp"
}

derper_module_matches() {
  [[ -x /usr/local/bin/derper ]] || return 1
  local go_cmd="/opt/derp-bootstrap/toolchains/go$GO_VERSION/bin/go"
  [[ -x $go_cmd ]] || return 1
  "$go_cmd" version -m /usr/local/bin/derper \
    | awk -v v="v$TAILSCALE_VERSION" '$1=="mod" && $2=="tailscale.com" && $3==v {found=1} END {exit !found}'
}

tailscaled_module_matches() {
  local go_cmd="/opt/derp-bootstrap/toolchains/go$GO_VERSION/bin/go"
  [[ -x $go_cmd ]] || return 1
  "$go_cmd" version -m "$(command -v tailscaled)" \
    | awk -v v="v$TAILSCALE_VERSION" '$1=="mod" && $2=="tailscale.com" && $3==v {found=1} END {exit !found}'
}

build_derper() {
  BUILT_DERPER=''
  if derper_module_matches; then
    log "Official derper v$TAILSCALE_VERSION is already installed."
    return
  fi
  ensure_go
  local tmp
  tmp=$(mktemp -d)
  GOBIN="$tmp" GOTOOLCHAIN=local "$GO_BIN" install "tailscale.com/cmd/derper@v$TAILSCALE_VERSION"
  "$GO_BIN" version -m "$tmp/derper" \
    | awk -v v="v$TAILSCALE_VERSION" '$1=="mod" && $2=="tailscale.com" && $3==v {found=1} END {exit !found}' \
    || die "Built derper module does not match Tailscale $TAILSCALE_VERSION."
  install -m 0755 "$tmp/derper" "$tmp/derper.new"
  BUILT_DERPER="$tmp/derper.new"
  log "Built official derper v$TAILSCALE_VERSION from the matching Go module."
}

install_certbot() {
  local venv=/opt/derp-bootstrap/certbot
  "$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3, 10)' \
    || die "Certbot $CERTBOT_VERSION requires Python 3.10 or newer ($PYTHON_BIN)."
  if [[ ! -x $venv/bin/certbot || $($venv/bin/certbot --version 2>/dev/null) != "certbot $CERTBOT_VERSION" ]]; then
    "$PYTHON_BIN" -m venv "$venv"
    "$venv/bin/python" -m pip install --disable-pip-version-check "certbot==$CERTBOT_VERSION"
  fi
  CERTBOT="$venv/bin/certbot"
  [[ $($CERTBOT --version) == "certbot $CERTBOT_VERSION" ]] || die "Certbot version mismatch."
}

obtain_certificate() {
  if [[ -e $CERT_LIVE/cert.pem ]]; then
    if ! (validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 86400); then
      log "Existing certificate needs renewal."
      "$CERTBOT" renew --non-interactive --no-random-sleep-on-renew \
        --cert-name "$CERT_NAME" --no-directory-hooks
    fi
  else
    log "Testing public IP HTTP-01 validation against Let's Encrypt staging."
    "$CERTBOT" certonly --dry-run --non-interactive --agree-tos --email "$ACME_EMAIL" \
      --standalone --preferred-profile shortlived --ip-address "$PUBLIC_IPV4" \
      --cert-name "$CERT_NAME" --no-directory-hooks \
      --server https://acme-staging-v02.api.letsencrypt.org/directory
    log "Requesting the production IP certificate."
    "$CERTBOT" certonly --non-interactive --agree-tos --email "$ACME_EMAIL" \
      --standalone --preferred-profile shortlived --ip-address "$PUBLIC_IPV4" \
      --cert-name "$CERT_NAME" --no-directory-hooks \
      --server https://acme-v02.api.letsencrypt.org/directory
  fi
  validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 86400
}

install_runtime() {
  local dst=/usr/local/libexec/derp-bootstrap
  install -d -m 0755 "$dst" /etc/derp-bootstrap /var/lib/derper "$DERPER_CERT_DIR"
  if [[ -f /etc/derp-bootstrap/config.env ]]; then
    local old_ip
    old_ip=$(bash -c 'source "$1"; printf "%s" "$PUBLIC_IPV4"' _ /etc/derp-bootstrap/config.env)
    [[ -z $old_ip || $old_ip == "$PUBLIC_IPV4" ]] || die "Existing managed install uses $old_ip; IP migration needs a separate review."
  fi
  if [[ ! $CONFIG_FILE -ef /etc/derp-bootstrap/config.env ]]; then
    install -m 0600 "$CONFIG_FILE" /etc/derp-bootstrap/config.env
  fi
  install -m 0644 "$ROOT_DIR/lib/common.sh" "$dst/common.sh"
  install -m 0755 "$ROOT_DIR/runtime/run-derper.sh" "$dst/run-derper"
  install -m 0755 "$ROOT_DIR/runtime/healthcheck.sh" "$dst/healthcheck"
  install -m 0755 "$ROOT_DIR/runtime/renew.sh" "$dst/renew"
  install -m 0755 "$ROOT_DIR/hooks/deploy-certificate.sh" "$dst/deploy-certificate"
  local crt="$DERPER_CERT_DIR/$PUBLIC_IPV4.crt" key="$DERPER_CERT_DIR/$PUBLIC_IPV4.key"
  [[ ! -e $crt || -L $crt ]] || die "Refusing to replace non-symlink certificate: $crt"
  [[ ! -e $key || -L $key ]] || die "Refusing to replace non-symlink key: $key"
  ln -sfn "$CERT_LIVE/fullchain.pem" "$crt"
  ln -sfn "$CERT_LIVE/privkey.pem" "$key"
  install -m 0644 "$ROOT_DIR/systemd/derper.service" /etc/systemd/system/derper.service
  install -m 0644 "$ROOT_DIR/systemd/derp-cert-renew.service" /etc/systemd/system/derp-cert-renew.service
  install -m 0644 "$ROOT_DIR/systemd/derp-cert-renew.timer" /etc/systemd/system/derp-cert-renew.timer
  install -m 0644 "$ROOT_DIR/systemd/derp-healthcheck.service" /etc/systemd/system/derp-healthcheck.service
  install -m 0644 "$ROOT_DIR/systemd/derp-healthcheck.timer" /etc/systemd/system/derp-healthcheck.timer
  systemctl daemon-reload
}

check_install() {
  check_tailnet
  [[ $(tailscaled --version | head -n 1) == "$TAILSCALE_VERSION" ]] || die "tailscaled version mismatch."
  tailscaled_module_matches || die "tailscaled module revision does not match versions.lock."
  derper_module_matches || die "derper module version mismatch."
  validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 3600
  validate_derper_cert_links
  systemctl is-active --quiet derper || die "derper is not active."
  wait_served_certificate 30
  log "Local DERP service, tailnet identity, certificate chain, and served TLS certificate are healthy."
}

wait_tailnet_online() {
  local i status
  for ((i=0; i<30; i++)); do
    status=$(tailscale status --json 2>/dev/null || true)
    if jq -e --arg name "$EXPECTED_TAILNET" \
      '.BackendState == "Running" and .Self.Online == true and .CurrentTailnet.Name == $name' \
      <<<"$status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

coordinated_upgrade() {
  local old_version=$1 old_binary status=0
  available_tailscale_version "$old_version" \
    || die "Cannot upgrade safely: prior Tailscale package $old_version is unavailable for rollback."
  systemctl is-active --quiet derper || die "Existing derper must be healthy before upgrading."
  old_binary=$(mktemp)
  cp -p /usr/local/bin/derper "$old_binary"
  log "Upgrading Tailscale and derper together: $old_version -> $TAILSCALE_VERSION."
  unhold_tailscale_package
  if ! install_tailscale_version "$TAILSCALE_VERSION"; then
    status=1
  elif [[ $(tailscaled --version | head -n 1) != "$TAILSCALE_VERSION" ]]; then
    status=1
  elif [[ -n $BUILT_DERPER ]] && ! install -m 0755 "$BUILT_DERPER" /usr/local/bin/derper.new; then
    status=1
  else
    if [[ -n $BUILT_DERPER ]]; then
      mv -f /usr/local/bin/derper.new /usr/local/bin/derper || status=1
    fi
    if ((status == 0)); then systemctl restart tailscaled || status=1; fi
    if ((status == 0)); then wait_tailnet_online || status=1; fi
    if ((status == 0)); then systemctl restart derper || status=1; fi
    if ((status == 0)); then (check_install) || status=1; fi
  fi
  if ((status == 0)); then
    hold_tailscale_package
    rm -f "$old_binary"
    log "Coordinated upgrade passed health checks."
    return
  fi
  log "Upgrade failed; restoring prior package and derper binary."
  local rollback_failed=0
  install_tailscale_version "$old_version" || rollback_failed=1
  install -m 0755 "$old_binary" /usr/local/bin/derper.rollback || rollback_failed=1
  if ((rollback_failed == 0)); then mv -f /usr/local/bin/derper.rollback /usr/local/bin/derper || rollback_failed=1; fi
  systemctl restart tailscaled || rollback_failed=1
  if ((rollback_failed == 0)); then wait_tailnet_online || rollback_failed=1; fi
  systemctl restart derper || rollback_failed=1
  [[ $(installed_tailscale_version) == "$old_version" ]] || rollback_failed=1
  if ((rollback_failed == 0)); then (check_served_certificate) || rollback_failed=1; fi
  hold_tailscale_package || rollback_failed=1
  rm -f "$old_binary"
  ((rollback_failed == 0)) || die "Upgrade and rollback both failed. Inspect package, service and network state immediately."
  die "Upgrade failed; previous Tailscale and derper were restored."
}

print_derpmap() {
  PUBLIC_IPV4="$PUBLIC_IPV4" DERP_PORT="$DERP_PORT" STUN_PORT="$STUN_PORT" \
  REGION_ID="$REGION_ID" REGION_CODE="$REGION_CODE" REGION_NAME="$REGION_NAME" python3 - <<'PY'
import json, os
ip = os.environ['PUBLIC_IPV4']
rid = int(os.environ['REGION_ID'])
node = {'Name': os.environ['REGION_CODE'] + '-1', 'RegionID': rid,
        'HostName': ip, 'IPv4': ip, 'IPv6': 'none',
        'DERPPort': int(os.environ['DERP_PORT']),
        'STUNPort': int(os.environ['STUN_PORT'])}
region = {'RegionID': rid, 'RegionCode': os.environ['REGION_CODE'],
          'RegionName': os.environ['REGION_NAME'], 'Nodes': [node]}
print(json.dumps({'derpMap': {'OmitDefaultRegions': False,
                              'Regions': {str(rid): region}}}, indent=2))
PY
}

main() {
  local action=${1:-}
  [[ $action == preflight || $action == install || $action == check || $action == derpmap ]] || { usage; exit 2; }
  CONFIG_FILE=${2:-/etc/derp-bootstrap/config.env}
  if [[ $action == install ]]; then
    require_root
    load_versions
    read_os
    if [[ $PKG_FAMILY == apt ]]; then need apt-get; else need dnf; fi
    # A minimal cloud image may not yet have Python, curl, OpenSSL or ss.
    if ! command -v python3 >/dev/null || ! command -v curl >/dev/null \
      || ! command -v openssl >/dev/null || ! command -v ss >/dev/null; then
      install_base_packages
    fi
  fi
  load_config "$CONFIG_FILE"
  load_versions
  case "$action" in
    preflight) preflight ;;
    derpmap) print_derpmap ;;
    check) require_root; check_install ;;
    install)
      need flock
      exec 9>/run/derp-bootstrap.lock
      flock -n 9 || die "Another derp-bootstrap install is running."
      preflight
      install_base_packages
      preflight
      setup_tailscale_repo
      local previous_version
      previous_version=$(installed_tailscale_version)
      if [[ -n $previous_version && $previous_version != "$TAILSCALE_VERSION" ]]; then
        [[ -f /etc/derp-bootstrap/config.env && -x /usr/local/bin/derper ]] \
          || die "Existing Tailscale $previous_version is not managed by this project; inspect before upgrading."
        build_derper
        install_certbot
        obtain_certificate
        install_runtime
        coordinated_upgrade "$previous_version"
      else
        install_tailscale_package
        join_tailnet
        build_derper
        install_certbot
        obtain_certificate
        install_runtime
        if [[ -n $BUILT_DERPER ]]; then
          install -m 0755 "$BUILT_DERPER" /usr/local/bin/derper
        fi
        systemctl enable derper
        systemctl restart derper
      fi
      systemctl enable --now derp-cert-renew.timer derp-healthcheck.timer
      "$CERTBOT" renew --dry-run --non-interactive --no-random-sleep-on-renew \
        --cert-name "$CERT_NAME" \
        --no-directory-hooks --server https://acme-staging-v02.api.letsencrypt.org/directory
      check_install
      print_derpmap
      log "Merge the printed derpMap into the existing policy, then test from real tailnet clients."
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
