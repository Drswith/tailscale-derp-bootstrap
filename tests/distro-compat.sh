#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${EXPECTED_ID:?Set EXPECTED_ID for the container image}"
: "${EXPECTED_MAJOR:?Set EXPECTED_MAJOR for the container image}"
PACKAGE_MODE=${PACKAGE_MODE:-install}
[[ $PACKAGE_MODE == install || $PACKAGE_MODE == metadata ]] \
  || { echo "Invalid PACKAGE_MODE: $PACKAGE_MODE" >&2; exit 2; }

# Source the same functions used by the installer. This container deliberately has
# no systemd, Docker daemon, tailnet credentials, public listener or ACME account.
source "$ROOT_DIR/install.sh"
load_versions
detect_platform
[[ $PLATFORM_ID == "$EXPECTED_ID" && ${PLATFORM_VERSION%%.*} == "$EXPECTED_MAJOR" ]] \
  || die "Unexpected image OS: $PLATFORM_ID $PLATFORM_VERSION"
[[ $(uname -m) == x86_64 ]] || die "The compatibility matrix expects linux/amd64."
GO_ARCH=amd64
GO_SHA256=$GO_LINUX_AMD64_SHA256

install_base_packages
setup_tailscale_repo
if [[ $PACKAGE_MODE == install ]]; then
  install_tailscale_version "$TAILSCALE_VERSION"
  [[ $(tailscaled --version | head -n 1) == "$TAILSCALE_VERSION" ]] \
    || die "Installed tailscaled version does not match versions.lock."
else
  [[ $PLATFORM_ID == rhel && $EXPECTED_MAJOR == 10 ]] \
    || die "Only RHEL UBI 10 uses the metadata-only package check."
  log "UBI 10 lacks the iptables dependency required by the Tailscale RPM; only repository metadata is checked."
fi

ensure_go
build_derper
[[ -n $BUILT_DERPER && -x $BUILT_DERPER ]] || die "derper build did not produce a binary."
install_certbot
[[ $($CERTBOT --version) == "certbot $CERTBOT_VERSION" ]] \
  || die "Installed Certbot version does not match versions.lock."

source "$ROOT_DIR/docker/deploy.sh"
if [[ $DOCKER_AUTO_INSTALL == manual ]]; then
  if output=$(install_docker_engine 2>&1); then
    die "Docker was auto-installed on a distribution that requires a manual Engine installation."
  fi
  [[ $output == *"Install Docker Engine and Compose v2 for"* ]] \
    || die "The manual Docker prerequisite produced an unexpected error."
else
  if [[ $PACKAGE_MODE == metadata ]]; then
    setup_docker_rpm_repo
    for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
      dnf -y --disablerepo='*' --enablerepo=docker-ce-stable repoquery \
        --available --qf '%{name}\n' "$package" | grep -qx "$package" \
        || die "Docker repository has no $package package."
    done
  else
    install_docker_engine
    if [[ $DOCKER_AUTO_INSTALL == ubuntu ]]; then
      install_docker_plugin buildx
    fi
    docker --version
    docker compose version
    docker buildx version
    docker compose --project-directory "$ROOT_DIR/docker" \
      --env-file "$ROOT_DIR/versions.lock" \
      --env-file "$ROOT_DIR/docker/config.example.env" \
      -f "$ROOT_DIR/docker/compose.yaml" config --quiet
  fi
fi

bash "$ROOT_DIR/tests/local.sh"
printf 'Compatibility commands and derper build passed on %s %s.\n' \
  "$PLATFORM_ID" "$PLATFORM_VERSION"
