#!/usr/bin/env bash

# Only map distributions whose package and repository paths we know. ID_LIKE
# alone is not enough to assume a derivative uses its parent's repositories.
detect_platform() {
  local os_file=${1:-/etc/os-release}
  [[ -r $os_file ]] || die "Cannot read $os_file to identify the Linux distribution."
  local ID= VERSION_ID= VERSION_CODENAME=
  # shellcheck disable=SC1090
  source "$os_file"
  PLATFORM_ID=$ID
  PLATFORM_VERSION=$VERSION_ID
  PKG_CODENAME=$VERSION_CODENAME
  PYTHON_BIN=python3

  case "$ID:$VERSION_ID:$VERSION_CODENAME" in
    ubuntu:22.04:jammy|ubuntu:24.04:noble)
      PKG_OS=ubuntu ;;
    debian:12:bookworm|debian:13:trixie)
      PKG_OS=debian ;;
    *)
      die "Unsupported Linux distribution: $ID $VERSION_ID ($VERSION_CODENAME). Supported: Ubuntu 22.04/24.04, Debian 12/13."
      ;;
  esac
}
