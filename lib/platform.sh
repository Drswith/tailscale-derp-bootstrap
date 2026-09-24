#!/usr/bin/env bash

# Only map distributions whose package and repository paths we know. ID_LIKE
# alone is not enough to assume a derivative uses its parent's repositories.
detect_platform() {
  local os_file=${1:-/etc/os-release}
  [[ -r $os_file ]] || die "Cannot read $os_file to identify the Linux distribution."
  local ID= ID_LIKE= VERSION_ID= VERSION_CODENAME=
  # shellcheck disable=SC1090
  source "$os_file"
  PLATFORM_ID=$ID
  PLATFORM_VERSION=$VERSION_ID
  PKG_CODENAME=$VERSION_CODENAME
  PKG_REPO_PATH=
  PYTHON_BIN=python3
  DOCKER_AUTO_INSTALL=manual

  case "$ID:$VERSION_ID:$VERSION_CODENAME" in
    ubuntu:22.04:jammy|ubuntu:24.04:noble)
      PKG_FAMILY=apt; PKG_OS=ubuntu; DOCKER_AUTO_INSTALL=ubuntu ;;
    debian:12:bookworm|debian:13:trixie)
      PKG_FAMILY=apt; PKG_OS=debian; DOCKER_AUTO_INSTALL=debian ;;
    fedora:43:*|fedora:44:*)
      PKG_FAMILY=dnf; PKG_OS=fedora; PKG_REPO_PATH=fedora/tailscale.repo
      DOCKER_AUTO_INSTALL=fedora ;;
    rhel:9:*|rhel:9.*:*|rhel:10:*|rhel:10.*:*)
      PKG_FAMILY=dnf; PKG_OS=rhel
      PKG_REPO_PATH="rhel/${VERSION_ID%%.*}/tailscale.repo"
      DOCKER_AUTO_INSTALL=rhel ;;
    rocky:9:*|rocky:9.*:*|rocky:10:*|rocky:10.*:*|\
    almalinux:9:*|almalinux:9.*:*|almalinux:10:*|almalinux:10.*:*)
      [[ " $ID_LIKE " == *" rhel "* ]] \
        || die "$ID $VERSION_ID does not declare RHEL compatibility in ID_LIKE."
      PKG_FAMILY=dnf; PKG_OS=rhel
      PKG_REPO_PATH="rhel/${VERSION_ID%%.*}/tailscale.repo" ;;
    *)
      die "Unsupported Linux distribution: $ID $VERSION_ID ($VERSION_CODENAME). Supported: Ubuntu 22.04/24.04, Debian 12/13, Fedora 43/44, RHEL/Rocky/AlmaLinux 9/10."
      ;;
  esac

  if [[ $PKG_FAMILY == dnf && ${VERSION_ID%%.*} == 9 ]]; then
    PYTHON_BIN=python3.11
  fi
}
