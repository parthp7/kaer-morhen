# scripts/monitoring

Helper scripts for the monitoring/alerting stack (see [docs/monitoring.md](../../docs/monitoring.md)).

## smartd-ntfy.sh

smartd `-M exec` handler that forwards SMART warnings (failing health,
reallocated/pending sectors, error-log growth) to the shared ntfy topic.

- **Deployed to**: `/usr/local/bin/smartd-ntfy.sh` on **both** nodes (0755).
- **Wired via** `/etc/smartd.conf`:
  `DEVICESCAN -a -n standby,q -m <nomailer> -M exec /usr/local/bin/smartd-ntfy.sh`
- **Reads** the topic from `/etc/ntfy.topic` (mode 600, git-ignored world —
  the real topic lives only on the nodes and in `secrets.local.yaml`).
- **Test** the full chain: temporarily append ` -M test` to the DEVICESCAN
  line, `systemctl restart smartmontools`, confirm the phone notification,
  revert.
