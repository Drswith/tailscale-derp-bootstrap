#!/usr/bin/env bash
set -euo pipefail
source /usr/local/libexec/derp-bootstrap/common.sh
load_config /etc/derp-bootstrap/config.env
exec 9>/run/derp-bootstrap.lock
flock -n 9 || die "Another install or renewal is running."
/opt/derp-bootstrap/certbot/bin/certbot renew --non-interactive \
  --no-random-sleep-on-renew --cert-name "$CERT_NAME" \
  --deploy-hook /usr/local/libexec/derp-bootstrap/deploy-certificate \
  --no-directory-hooks
# Certbot can report success even when its deploy hook failed. Check the
# certificate that derper actually presents and fail the systemd unit if stale.
validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 3600
systemctl is-active --quiet derper || die "derper stopped after renewal."
check_served_certificate
log "Certificate renewal check passed."
