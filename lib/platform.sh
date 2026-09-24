#!/usr/bin/env bash

# Only map distributions whose package and repository paths we know. ID_LIKE
# alone is not enough to assume a derivative uses its parent's repositories.
detect_platform() {
  local os_file=${1:-/etc/os-release}
  [[ -r $os_file ]] || die "Cannot read $os_file to identify the Linux distribution."
  local ID= NAME= VERSION_ID= VERSION_CODENAME=
  # shellcheck disable=SC1090
  source "$os_file"
  PLATFORM_ID=$ID
  PLATFORM_VERSION=$VERSION_ID
  PKG_CODENAME=$VERSION_CODENAME
  PKG_REPO_PATH=
  PYTHON_BIN=python3

  case "$ID:$VERSION_ID:$VERSION_CODENAME" in
    ubuntu:22.04:jammy|ubuntu:24.04:noble)
      PKG_FAMILY=apt; PKG_OS=ubuntu ;;
    debian:12:bookworm|debian:13:trixie)
      PKG_FAMILY=apt; PKG_OS=debian ;;
    centos:9:|centos:10:)
      [[ $NAME == 'CentOS Stream' ]] || die "Only CentOS Stream 9/10 is supported, not CentOS Linux."
      PKG_FAMILY=dnf; PKG_OS=centos
      PKG_REPO_PATH="centos/$VERSION_ID/tailscale.repo"
      if [[ $VERSION_ID == 9 ]]; then PYTHON_BIN=python3.11; fi ;;
    *)
      die "Unsupported Linux distribution: $ID $VERSION_ID ($VERSION_CODENAME). Supported: Ubuntu 22.04/24.04, Debian 12/13, CentOS Stream 9/10."
      ;;
  esac
}
