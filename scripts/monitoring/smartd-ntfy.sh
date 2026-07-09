#!/usr/bin/env bash
# smartd-ntfy.sh — smartd -M exec handler: forward SMART warnings to ntfy.
#
# Usage: not run by hand; invoked by smartd via /etc/smartd.conf:
#   DEVICESCAN -a -n standby,q -m <nomailer> -M exec /usr/local/bin/smartd-ntfy.sh
# Deploy: install -m 0755 smartd-ntfy.sh /usr/local/bin/smartd-ntfy.sh
# Requires: /etc/ntfy.topic (mode 600) containing the ntfy topic name;
#           smartd exports SMARTD_* env vars describing the event.
set -euo pipefail

topic="$(cat /etc/ntfy.topic)"

curl -fsS --max-time 15 \
  -H "Title: SMART ${SMARTD_FAILTYPE:-warning} on $(hostname -s): ${SMARTD_DEVICE:-?}" \
  -H "Priority: high" \
  -d "${SMARTD_FULLMESSAGE:-${SMARTD_MESSAGE:-no detail}}" \
  "https://ntfy.sh/${topic}" >/dev/null
