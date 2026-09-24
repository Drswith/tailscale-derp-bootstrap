#!/usr/bin/env bash

log() { printf '[derp-bootstrap] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
require_root() { [[ $(id -u) == 0 ]] || die "Run as root (sudo)."; }

load_config() {
  local file=${1:?configuration file required}
  [[ -f $file ]] || die "Configuration file not found: $file"
  # This is an operator-owned shell environment file; never load an untrusted file.
  # shellcheck disable=SC1090
  source "$file"
  : "${PUBLIC_IPV4:?Set PUBLIC_IPV4}"
  : "${ACME_EMAIL:?Set ACME_EMAIL}"
  : "${EXPECTED_TAILNET:?Set EXPECTED_TAILNET}"
  : "${TS_HOSTNAME:?Set TS_HOSTNAME}"
  : "${DERP_PORT:=52625}" "${STUN_PORT:=3478}" "${REGION_ID:=900}"
  : "${REGION_CODE:=example-derp}" "${REGION_NAME:=Example DERP}"
  : "${TS_AUTH_KEY_FILE:=}"
  : "${TS_ADVERTISE_TAGS:=}"

  need python3
  python3 - "$PUBLIC_IPV4" <<'PY' || die "PUBLIC_IPV4 must be a globally routable IPv4 address."
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
assert isinstance(ip, ipaddress.IPv4Address) and ip.is_global
PY
  [[ $ACME_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Invalid ACME_EMAIL"
  [[ $EXPECTED_TAILNET =~ ^[a-zA-Z0-9@._-]+$ ]] || die "Invalid EXPECTED_TAILNET"
  [[ $TS_HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Invalid TS_HOSTNAME"
  [[ $REGION_CODE =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "Invalid REGION_CODE"
  [[ $REGION_NAME != *$'\n'* && $REGION_NAME != *$'\r'* ]] || die "Invalid REGION_NAME"
  local port
  for port in "$DERP_PORT" "$STUN_PORT"; do
    [[ $port =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die "Invalid port: $port"
  done
  [[ $REGION_ID =~ ^[0-9]+$ ]] && ((10#$REGION_ID >= 900 && 10#$REGION_ID <= 999)) || die "REGION_ID must be 900..999"
  CERT_NAME="derp-ip-${PUBLIC_IPV4//./-}"
  CERT_LIVE="/etc/letsencrypt/live/$CERT_NAME"
  DERPER_CERT_DIR="/var/lib/derper/certs"
}

cert_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':'
}

validate_certificate() {
  local cert=${1:-$CERT_LIVE/cert.pem}
  local chain=${2:-$CERT_LIVE/fullchain.pem}
  local key=${3:-$CERT_LIVE/privkey.pem}
  local min_seconds=${4:-3600}
  local ca_bundle=${5:-/etc/ssl/certs/ca-certificates.crt}
  [[ -s $cert && -s $chain && -s $key ]] || die "Certificate, full chain or private key is missing."
  openssl x509 -in "$cert" -noout -checkend "$min_seconds" >/dev/null || die "Certificate is expired or close to expiry."
  openssl verify -purpose sslserver -verify_ip "$PUBLIC_IPV4" \
    -CAfile "$ca_bundle" -untrusted "$chain" "$cert" >/dev/null \
    || die "Certificate is not trusted by the system CA bundle or lacks the public IP SAN."
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout | openssl dgst -sha256)
  key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl dgst -sha256)
  [[ -n $cert_pub && $cert_pub == "$key_pub" ]] || die "Certificate and private key do not match."
}

validate_derper_cert_links() {
  local crt="$DERPER_CERT_DIR/$PUBLIC_IPV4.crt" key="$DERPER_CERT_DIR/$PUBLIC_IPV4.key"
  [[ -L $crt && -L $key ]] || die "Managed derper certificate links are missing."
  [[ $(readlink -f "$crt") == "$(readlink -f "$CERT_LIVE/fullchain.pem")" ]] \
    || die "derper certificate link points away from the validated chain."
  [[ $(readlink -f "$key") == "$(readlink -f "$CERT_LIVE/privkey.pem")" ]] \
    || die "derper key link points away from the validated private key."
}

check_served_certificate() {
  local presented expected
  expected=$(cert_fingerprint "$CERT_LIVE/cert.pem")
  presented=$(timeout 10 openssl s_client -connect "127.0.0.1:$DERP_PORT" \
    -verify_ip "$PUBLIC_IPV4" -verify_return_error -showcerts </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | cut -d= -f2 | tr -d ':') || die "Local DERP TLS handshake failed."
  [[ -n $presented && $expected == "$presented" ]] || die "DERP is not serving the current certificate."
}

wait_served_certificate() {
  local attempts=${1:-30} i
  for ((i=0; i<attempts; i++)); do
    if (check_served_certificate) >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "DERP did not serve the current certificate within ${attempts} seconds."
}

check_tailnet() {
  need tailscale
  need jq
  local status name state
  status=$(tailscale status --json) || die "Cannot read tailscaled status."
  state=$(jq -r '.BackendState // ""' <<<"$status")
  name=$(jq -r '.CurrentTailnet.Name // ""' <<<"$status")
  [[ $state == Running && $(jq -r '.Self.Online // false' <<<"$status") == true ]] \
    || die "tailscaled is $state; complete login or device approval before continuing."
  [[ $name == "$EXPECTED_TAILNET" ]] || die "Joined tailnet '$name', expected '$EXPECTED_TAILNET'."
  [[ $(jq -r '.Self.Expired // false' <<<"$status") != true ]] || die "Tailscale node key has expired."
  local expiry expiry_epoch
  expiry=$(jq -r '.Self.KeyExpiry // empty' <<<"$status")
  if [[ -n $expiry ]]; then
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || die "Cannot parse Tailscale node key expiry."
    ((expiry_epoch > $(date +%s) + 604800)) || die "Tailscale node key expires within seven days: $expiry"
  fi
  if jq -e '.Health | any(.[]; test("key expir|auth|approval"; "i"))' <<<"$status" >/dev/null 2>&1; then
    die "Tailscale reports an authentication or approval health issue."
  fi
}
