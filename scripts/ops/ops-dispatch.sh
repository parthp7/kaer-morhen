#!/usr/bin/env bash
# ops-dispatch.sh — forced-command receiver for the dashboard's ops SSH key
# (proposal 008 §6). Installed as the `command=` of ONE authorized_keys line.
# The requested word arrives EITHER as $1 (ciri: the forced command is
# `sudo -n ops-dispatch.sh "$SSH_ORIGINAL_COMMAND"`, because sudo's env_reset
# drops the variable) OR in SSH_ORIGINAL_COMMAND (PVE nodes: the key sits on
# root, no sudo). It must equal one whitelisted word exactly; anything else —
# extra args, shell metacharacters, an empty request — is refused with exit
# 126. Words map to scripts in /usr/local/lib/ops; a word whose script is
# absent on this host is refused the same way.
set -euo pipefail
LIB=/usr/local/lib/ops
[[ $# -le 1 ]] || { echo "refused: too many arguments" >&2; exit 126; }
word=${1:-${SSH_ORIGINAL_COMMAND:-}}
case "$word" in
  updates)   script="$LIB/updates-report.sh" ;;
  qbit-move) script="$LIB/qbit-move-progress.sh" ;;
  media-df)  script="$LIB/media-df.sh" ;;
  *) echo "refused: ${word:-<none>}" >&2; exit 126 ;;
esac
[[ -x $script ]] || { echo "refused: $word not available here" >&2; exit 126; }
exec "$script"
