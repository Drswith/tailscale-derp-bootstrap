#!/usr/bin/env bash
set -euo pipefail
source /usr/local/libexec/derp-bootstrap/common.sh
load_config /etc/derp-bootstrap/config.env
check_tailnet
validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 3600
validate_derper_cert_links
exec /usr/local/bin/derper \
  --hostname="$PUBLIC_IPV4" \
  --certmode=manual \
  --certdir="$DERPER_CERT_DIR" \
  --a=":$DERP_PORT" \
  --http-port=-1 \
  --stun-port="$STUN_PORT" \
  --verify-clients \
  --c=/var/lib/derper/derper.key
