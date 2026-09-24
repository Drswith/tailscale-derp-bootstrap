#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${EXPECTED_ID:?Set EXPECTED_ID for the container image}"
: "${EXPECTED_MAJOR:?Set EXPECTED_MAJOR for the container image}"
: "${EXPECTED_ARCH:=amd64}"

# Source the same functions used by the installer. This container deliberately has
# no systemd, Docker daemon, tailnet credentials, public listener or ACME account.
source "$ROOT_DIR/install.sh"
load_versions
detect_platform
[[ $PLATFORM_ID == "$EXPECTED_ID" && ${PLATFORM_VERSION%%.*} == "$EXPECTED_MAJOR" ]] \
  || die "Unexpected image OS: $PLATFORM_ID $PLATFORM_VERSION"
case "$EXPECTED_ARCH:$(uname -m)" in
  amd64:x86_64) GO_ARCH=amd64; GO_SHA256=$GO_LINUX_AMD64_SHA256 ;;
  arm64:aarch64) GO_ARCH=arm64; GO_SHA256=$GO_LINUX_ARM64_SHA256 ;;
  *) die "Container architecture does not match EXPECTED_ARCH=$EXPECTED_ARCH." ;;
esac

install_base_packages
setup_tailscale_repo
install_tailscale_version "$TAILSCALE_VERSION"
[[ $(tailscaled --version | head -n 1) == "$TAILSCALE_VERSION" ]] \
  || die "Installed tailscaled version does not match versions.lock."

ensure_go
build_derper
[[ -n $BUILT_DERPER && -x $BUILT_DERPER ]] || die "derper build did not produce a binary."
install_certbot
[[ $($CERTBOT --version) == "certbot $CERTBOT_VERSION" ]] \
  || die "Installed Certbot version does not match versions.lock."

source "$ROOT_DIR/docker/deploy.sh"
install_docker_engine
if [[ $PKG_OS == ubuntu ]]; then
  install_docker_plugin buildx
fi
docker --version
docker compose version
docker buildx version
docker compose --project-directory "$ROOT_DIR/docker" \
  --env-file "$ROOT_DIR/versions.lock" \
  --env-file "$ROOT_DIR/docker/config.example.env" \
  -f "$ROOT_DIR/docker/compose.yaml" config --quiet

bash "$ROOT_DIR/tests/local.sh"
printf 'Compatibility commands and derper build passed on %s %s.\n' \
  "$PLATFORM_ID" "$PLATFORM_VERSION"
