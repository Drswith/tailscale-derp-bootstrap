#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/libexec/derp-bootstrap/common.sh

write_config() {
  install -d -m 0700 /run/derp-bootstrap /var/run/tailscale \
    /var/lib/tailscale /var/lib/derper/certs
  HAD_TAILSCALE_STATE=false
  [[ ! -s /var/lib/tailscale/tailscaled.state ]] || HAD_TAILSCALE_STATE=true
  {
    local name
    for name in PUBLIC_IPV4 ACME_EMAIL EXPECTED_TAILNET TS_HOSTNAME \
      DERP_PORT STUN_PORT REGION_ID REGION_CODE REGION_NAME; do
      printf '%s=%q\n' "$name" "${!name:-}"
    done
    printf 'TS_AUTH_KEY_FILE=%q\n' ''
  } > /run/derp-bootstrap/config.env
  chmod 0600 /run/derp-bootstrap/config.env
  load_config /run/derp-bootstrap/config.env
  case "${AUTH_MODE:-}" in
    interactive|authkey) ;;
    *) die "AUTH_MODE must be interactive or authkey." ;;
  esac
  [[ $DERP_PORT != 80 && $DERP_PORT != "$STUN_PORT" ]] \
    || die "DERP_PORT must differ from TCP 80 and STUN_PORT."
}

cleanup() {
  trap - EXIT
  [[ -z ${DERPER_PID:-} ]] || kill "$DERPER_PID" 2>/dev/null || true
  [[ -z ${TAILSCALED_PID:-} ]] || kill "$TAILSCALED_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT
renew_requested=0
renew_generation=0
trap 'renew_requested=1' USR1

start_tailscaled() {
  tailscaled --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock &
  TAILSCALED_PID=$!
  local i
  for ((i=0; i<60; i++)); do
    [[ -S /var/run/tailscale/tailscaled.sock ]] && return
    kill -0 "$TAILSCALED_PID" 2>/dev/null || die "tailscaled exited during startup."
    sleep 1
  done
  die "tailscaled did not create its LocalAPI socket."
}

join_tailnet() {
  local status state i key=/run/derp-secrets/auth.key
  if [[ $HAD_TAILSCALE_STATE == true && ! -f $key ]]; then
    log "Waiting for the persisted Tailscale identity to reconnect."
    for ((i=0; i<60; i++)); do
      status=$(tailscale status --json 2>/dev/null || true)
      if jq -e '.BackendState == "Running" and .Self.Online == true' \
        <<<"$status" >/dev/null 2>&1; then
        break
      fi
      kill -0 "$TAILSCALED_PID" 2>/dev/null || die "tailscaled exited while reconnecting."
      sleep 2
    done
  fi
  status=$(tailscale status --json 2>/dev/null || true)
  state=$(jq -r '.BackendState // ""' <<<"$status" 2>/dev/null || true)
  if [[ $state != Running ]]; then
    if [[ $AUTH_MODE == authkey ]]; then
      [[ -f $key && $(stat -c '%a' "$key") == 600 ]] \
        || die "Headless enrollment requires /run/derp-secrets/auth.key (mode 0600)."
      log "Joining tailnet with a one-use key from a file."
      tailscale up --auth-key="file:$key" --hostname="$TS_HOSTNAME" \
        --accept-dns=false --accept-routes=false
      rm -f -- "$key"
    else
      log "Open the Tailscale login URL printed below and approve the device."
      tailscale up --hostname="$TS_HOSTNAME" \
        --accept-dns=false --accept-routes=false
    fi
  fi
  check_tailnet
}

obtain_certificate() {
  if [[ ! -e $CERT_LIVE/cert.pem ]]; then
    log "Testing public IP HTTP-01 validation with Let's Encrypt staging."
    certbot certonly --dry-run --non-interactive --agree-tos --email "$ACME_EMAIL" \
      --standalone --preferred-profile shortlived --ip-address "$PUBLIC_IPV4" \
      --cert-name "$CERT_NAME" --no-directory-hooks \
      --server https://acme-staging-v02.api.letsencrypt.org/directory
    log "Requesting the production IP certificate."
    certbot certonly --non-interactive --agree-tos --email "$ACME_EMAIL" \
      --standalone --preferred-profile shortlived --ip-address "$PUBLIC_IPV4" \
      --cert-name "$CERT_NAME" --no-directory-hooks \
      --server https://acme-v02.api.letsencrypt.org/directory
  else
    certbot renew --non-interactive --no-random-sleep-on-renew \
      --cert-name "$CERT_NAME" --no-directory-hooks
  fi
  validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 86400
  local crt="$DERPER_CERT_DIR/$PUBLIC_IPV4.crt" key="$DERPER_CERT_DIR/$PUBLIC_IPV4.key"
  [[ ! -e $crt || -L $crt ]] || die "Refusing to replace non-symlink certificate: $crt"
  [[ ! -e $key || -L $key ]] || die "Refusing to replace non-symlink key: $key"
  ln -sfn "$CERT_LIVE/fullchain.pem" "$crt"
  ln -sfn "$CERT_LIVE/privkey.pem" "$key"
  validate_derper_cert_links
}

start_derper() {
  derper --hostname="$PUBLIC_IPV4" --certmode=manual \
    --certdir="$DERPER_CERT_DIR" --a=":$DERP_PORT" --http-port=-1 \
    --stun-port="$STUN_PORT" --verify-clients \
    --socket=/var/run/tailscale/tailscaled.sock \
    --c=/var/lib/derper/derper.key &
  DERPER_PID=$!
  wait_served_certificate 60
}

renew_certificate() {
  local before after
  before=$(cert_fingerprint "$CERT_LIVE/cert.pem")
  if ! certbot renew --non-interactive --no-random-sleep-on-renew \
    --cert-name "$CERT_NAME" --no-directory-hooks; then
    log "Certificate renewal failed; the existing certificate remains in service."
    return 1
  fi
  validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 3600
  after=$(cert_fingerprint "$CERT_LIVE/cert.pem")
  if [[ $before != "$after" ]]; then
    log "Certificate changed; restarting derper to load it."
    kill "$DERPER_PID"
    wait "$DERPER_PID" || true
    start_derper
  fi
  check_served_certificate
  log "Certificate renewal check passed."
}

write_config
printf '%s\n' "$$" > /run/derp-bootstrap/supervisor.pid
printf '0 pending\n' > /run/derp-bootstrap/last-renew
start_tailscaled
join_tailnet
obtain_certificate
start_derper
/usr/local/bin/derp-container-healthcheck
log "Docker DERP is healthy."

last_renew=$(date +%s)
last_health=$last_renew
while true; do
  sleep 30 || true
  kill -0 "$TAILSCALED_PID" 2>/dev/null || die "tailscaled exited."
  kill -0 "$DERPER_PID" 2>/dev/null || die "derper exited."
  now=$(date +%s)
  if ((renew_requested || now - last_renew >= 28800)); then
    renew_requested=0
    renew_generation=$((renew_generation + 1))
    if renew_certificate; then
      printf '%s ok\n' "$renew_generation" > /run/derp-bootstrap/last-renew
    else
      printf '%s failed\n' "$renew_generation" > /run/derp-bootstrap/last-renew
    fi
    last_renew=$now
  fi
  if ((now - last_health >= 3600)); then
    /usr/local/bin/derp-container-healthcheck
    last_health=$now
  fi
done
