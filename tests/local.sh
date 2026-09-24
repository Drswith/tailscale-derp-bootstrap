#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for script in "$ROOT_DIR"/install.sh "$ROOT_DIR"/lib/*.sh \
  "$ROOT_DIR"/runtime/*.sh "$ROOT_DIR"/hooks/*.sh "$ROOT_DIR"/docker/*.sh; do
  bash -n "$script"
done

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/platform.sh"
check_platform() {
  local id=$1 version=$2 codename=$3 like=$4 family=$5 repo=$6 docker_path=$7 python=$8 repo_path=$9
  printf 'ID=%s\nVERSION_ID=%s\nVERSION_CODENAME=%s\nID_LIKE="%s"\n' \
    "$id" "$version" "$codename" "$like" > "$tmp/os-release"
  detect_platform "$tmp/os-release"
  [[ $PKG_FAMILY == "$family" && $PKG_OS == "$repo" && \
     $DOCKER_AUTO_INSTALL == "$docker_path" && $PYTHON_BIN == "$python" && \
     $PKG_REPO_PATH == "$repo_path" ]]
}
check_platform ubuntu 22.04 jammy '' apt ubuntu ubuntu python3 ''
check_platform ubuntu 24.04 noble '' apt ubuntu ubuntu python3 ''
check_platform debian 12 bookworm '' apt debian debian python3 ''
check_platform debian 13 trixie '' apt debian debian python3 ''
check_platform fedora 43 '' '' dnf fedora fedora python3 fedora/tailscale.repo
check_platform fedora 44 '' '' dnf fedora fedora python3 fedora/tailscale.repo
check_platform rhel 9.6 '' '' dnf rhel rhel python3.11 rhel/9/tailscale.repo
check_platform rhel 10.1 '' '' dnf rhel rhel python3 rhel/10/tailscale.repo
check_platform rocky 9.6 '' 'rhel centos fedora' dnf rhel manual python3.11 rhel/9/tailscale.repo
check_platform almalinux 10.1 '' 'rhel centos fedora' dnf rhel manual python3 rhel/10/tailscale.repo
check_unsupported_platform() {
  printf 'ID=%s\nVERSION_ID=%s\nVERSION_CODENAME=%s\nID_LIKE="%s"\n' \
    "$1" "$2" "$3" "$4" > "$tmp/os-release"
  if (detect_platform "$tmp/os-release") >/dev/null 2>&1; then
    echo "Unsupported Linux distribution was accepted: $1 $2" >&2; exit 1
  fi
}
check_unsupported_platform ubuntu 20.04 focal debian
check_unsupported_platform linuxmint 22 wilma ubuntu
check_unsupported_platform unknown 1 '' ''

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  docker compose --project-directory "$ROOT_DIR/docker" \
    --env-file "$ROOT_DIR/versions.lock" \
    --env-file "$ROOT_DIR/docker/config.example.env" \
    -f "$ROOT_DIR/docker/compose.yaml" config --quiet
fi

sed 's/203\.0\.113\.10/1.1.1.1/' "$ROOT_DIR/config.example.env" > "$tmp/config.env"
python3 -m json.tool <(bash "$ROOT_DIR/install.sh" derpmap "$tmp/config.env") > "$tmp/map.json"
sed -i.bak 's/EXPECTED_TAILNET="example.com"/EXPECTED_TAILNET="user@example.com"/' "$tmp/config.env"
bash "$ROOT_DIR/install.sh" derpmap "$tmp/config.env" >/dev/null
python3 - "$tmp/map.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))['derpMap']
node = data['Regions']['900']['Nodes'][0]
assert data['OmitDefaultRegions'] is False
assert node['HostName'] == node['IPv4'] == '1.1.1.1'
assert node['IPv6'] == 'none'
assert 'CertName' not in node and 'InsecureForTests' not in node
PY
if bash "$ROOT_DIR/install.sh" derpmap "$ROOT_DIR/config.example.env" >/dev/null 2>&1; then
  echo 'Reserved example IPv4 was accepted' >&2
  exit 1
fi

PUBLIC_IPV4=1.1.1.1
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -quiet \
  -subj '/CN=Test Root' -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$tmp/root.key" -out "$tmp/root.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -quiet -subj '/CN=1.1.1.1' \
  -keyout "$tmp/leaf.key" -out "$tmp/leaf.csr" 2>/dev/null
printf 'subjectAltName=IP:1.1.1.1\nextendedKeyUsage=serverAuth\n' > "$tmp/extensions"
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/root.pem" -CAkey "$tmp/root.key" \
  -CAcreateserial -days 3 -extfile "$tmp/extensions" -out "$tmp/cert.pem" 2>/dev/null
cat "$tmp/cert.pem" "$tmp/root.pem" > "$tmp/fullchain.pem"
validate_certificate "$tmp/cert.pem" "$tmp/fullchain.pem" "$tmp/leaf.key" 3600 "$tmp/root.pem"
if (PUBLIC_IPV4=8.8.8.8; validate_certificate "$tmp/cert.pem" "$tmp/fullchain.pem" "$tmp/leaf.key" 3600 "$tmp/root.pem") >/dev/null 2>&1; then
  echo 'Wrong IP SAN was accepted' >&2; exit 1
fi
if (validate_certificate "$tmp/cert.pem" "$tmp/fullchain.pem" "$tmp/root.key" 3600 "$tmp/root.pem") >/dev/null 2>&1; then
  echo 'Wrong private key was accepted' >&2; exit 1
fi
if (validate_certificate "$tmp/cert.pem" "$tmp/fullchain.pem" "$tmp/leaf.key" 604800 "$tmp/root.pem") >/dev/null 2>&1; then
  echo 'Nearly expired certificate was accepted' >&2; exit 1
fi

CERT_LIVE="$tmp/live"
DERPER_CERT_DIR="$tmp/derper"
mkdir -p "$CERT_LIVE" "$DERPER_CERT_DIR"
cp "$tmp/fullchain.pem" "$CERT_LIVE/fullchain.pem"
cp "$tmp/leaf.key" "$CERT_LIVE/privkey.pem"
ln -s "$CERT_LIVE/fullchain.pem" "$DERPER_CERT_DIR/$PUBLIC_IPV4.crt"
ln -s "$CERT_LIVE/privkey.pem" "$DERPER_CERT_DIR/$PUBLIC_IPV4.key"
validate_derper_cert_links
ln -sfn "$tmp/root.key" "$DERPER_CERT_DIR/$PUBLIC_IPV4.key"
if (validate_derper_cert_links) >/dev/null 2>&1; then
  echo 'Incorrect derper key link was accepted' >&2; exit 1
fi

echo 'Local configuration, DERP map and certificate safeguards passed.'
