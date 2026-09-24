#!/usr/bin/env bash
set -euo pipefail
source /usr/local/libexec/derp-bootstrap/common.sh
load_config /etc/derp-bootstrap/config.env
[[ ${RENEWED_LINEAGE:-} == "$CERT_LIVE" ]] || exit 0
validate_certificate "$CERT_LIVE/cert.pem" "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" 3600
systemctl restart derper
systemctl is-active --quiet derper || die "derper did not restart after certificate renewal."
wait_served_certificate 30
printf '[derp-bootstrap] derper loaded the renewed public CA certificate.\n'
