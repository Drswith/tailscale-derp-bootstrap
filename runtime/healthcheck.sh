#!/usr/bin/env bash
set -euo pipefail
source /usr/local/libexec/derp-bootstrap/common.sh
load_config /etc/derp-bootstrap/config.env
check_tailnet
validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 129600
validate_derper_cert_links
systemctl is-active --quiet derper || die "derper is not active."
check_served_certificate
log "DERP healthcheck passed."
