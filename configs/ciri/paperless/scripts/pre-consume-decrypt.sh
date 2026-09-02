#!/usr/bin/env bash
# pre-consume-decrypt.sh — strip PDF open-passwords during paperless-ngx ingest.
#
# Why this exists
#   Paperless has no notion of a PDF password, and the failure is silent rather
#   than loud. Verified on this stack (paperless-ngx 3.0.5, ocrmypdf 17.4.2):
#   OCRmyPDF raises EncryptedPdfError, and paperless/parsers/tesseract.py:611
#   *catches* it —
#
#       "This file is encrypted and/or signed, OCR is impossible.
#        Using any text present in the original file."
#
#   — so the document is still created, but with empty content, no OCR text and
#   no archive PDF, and the stored original is still encrypted (it re-prompts
#   for the password on download). It looks like a clean import and is useless:
#   unsearchable and unpreviewable.
#
#   This hook decrypts the file after paperless has copied it to a scratch
#   working copy but before the parser runs, so OCR sees a plain PDF and every
#   artefact paperless then stores — original, archive, thumbnail — is
#   password-free. Because uploads from the web UI and the mobile apps go
#   through the same consume_file task as the watched folder (views.py:2021),
#   one hook covers every upload path: Mac, phone, PC, consume/.
#
# Contract (paperless-ngx 3.0.x, documents/consumer.py:288)
#   DOCUMENT_WORKING_PATH  the scratch copy that actually gets parsed and then
#                          stored. THIS is the file to modify, in place.
#   DOCUMENT_SOURCE_PATH   the untouched original (consume/ file or API temp).
#                          Never written to here: paperless owns its lifecycle,
#                          and the document's created-date falls back to this
#                          file's mtime (consumer.py:831).
#   TASK_ID                the celery task id.
#   A non-zero exit fails the consume with pre_consume_script_error
#   (documents/utils.py:176, check_exit_code defaults to True) — which is the
#   point: a file we cannot decrypt must not become a silent empty document.
#
# Passwords, in the order tried
#   1. the empty password — files carrying only an OWNER password (printing or
#      copy restrictions, no prompt on open) decrypt with no secret at all
#   2. every line of $PAPERLESS_PDF_PASSWORD_FILE — the recurring senders
#   3. a `__pw=` suffix on the uploaded filename, e.g. `oneoff__pw=hunter2.pdf`
#      — the escape hatch for a one-off whose password is not worth storing
#
#   NOTE on 3: the suffix survives into the document TITLE and into
#   original_filename, because paperless derives both from the *upload*
#   filename (consumer.py:839), which this hook cannot rename. Rename the title
#   in the UI after such an upload. Only the stored PDF is cleaned.
#
# Stdout is logged by paperless at INFO, stderr at WARNING. Passwords are never
# printed, and are passed to qpdf on stdin (--password-file=-) so they stay out
# of argv, where any process on the box could read them.
#
# Wired up by compose: ./scripts mounted read-only at /usr/src/paperless/scripts
# and PAPERLESS_PRE_CONSUME_SCRIPT pointing here. Runs as uid 1000 (paperless);
# needs mode 0755, and the password file must be readable by that uid.

set -euo pipefail

readonly PW_FILE="${PAPERLESS_PDF_PASSWORD_FILE:-/usr/src/paperless/scripts/pdf-passwords.txt}"

log()  { printf 'pre-consume-decrypt: %s\n' "$*"; }
warn() { printf 'pre-consume-decrypt: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

work="${DOCUMENT_WORKING_PATH:-}"
[[ -n "$work" ]] || die "DOCUMENT_WORKING_PATH is unset — not running as a paperless pre-consume hook?"
[[ -f "$work" ]] || die "working copy does not exist: $work"

command -v qpdf >/dev/null 2>&1 || die "qpdf not found in the container"

tmp=""
cleanup() { [[ -n "$tmp" && -e "$tmp" ]] && rm -f "$tmp"; return 0; }
trap cleanup EXIT

base="${work##*/}"

# Only PDFs are candidates; images and everything else pass straight through.
# Checked by extension OR magic bytes, because qpdf cannot distinguish "not
# encrypted" from "not a PDF" — both exit 2.
if [[ "${base,,}" != *.pdf && "$(head -c 5 "$work")" != "%PDF-" ]]; then
  log "$base is not a PDF, nothing to do"
  exit 0
fi

# qpdf --is-encrypted: 0 = encrypted, 2 = not encrypted (or unreadable).
rc=0
qpdf --is-encrypted "$work" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  log "$base is not encrypted, nothing to do"
  exit 0
fi

log "$base is encrypted, looking for a password"

# Candidate passwords, paired with a human-readable source for the log. The
# values themselves are never logged.
declare -a candidates=("") sources=("empty (owner-password-only)")

if [[ -r "$PW_FILE" ]]; then
  perms="$(stat -c '%a' "$PW_FILE" 2>/dev/null || echo '?')"
  case "$perms" in
    400 | 440 | 600 | 640) ;;
    *) warn "password file is mode $perms — tighten it to 600" ;;
  esac
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    candidates+=("$line")
    n=$((n + 1))
    sources+=("password file line $n")
  done < "$PW_FILE"
  log "loaded $n password(s) from the password file"
elif [[ -e "$PW_FILE" ]]; then
  warn "password file exists but is not readable as uid $(id -u): $PW_FILE"
else
  log "no password file at $PW_FILE"
fi

# Filename escape hatch, tried last: name__pw=SECRET.pdf
if [[ "$base" == *__pw=* ]]; then
  suffix="${base##*__pw=}"
  suffix="${suffix%.[Pp][Dd][Ff]}"
  if [[ -n "$suffix" ]]; then
    candidates+=("$suffix")
    sources+=("__pw= filename suffix")
  fi
fi

# qpdf --requires-password: 3 = the supplied password is correct,
# 0 = a different password is needed, 2 = the file is not encrypted.
matched=-1
for i in "${!candidates[@]}"; do
  rc=0
  printf '%s\n' "${candidates[$i]}" |
    qpdf --requires-password --password-file=- "$work" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    matched="$i"
    break
  fi
done

if [[ "$matched" -lt 0 ]]; then
  die "no known password opens $base (tried ${#candidates[@]}) — refusing to import it as an empty document. Add its password to the password file, or re-upload it as NAME__pw=THEPASSWORD.pdf"
fi

log "matched via ${sources[$matched]}, decrypting"

tmp="${work}.decrypt.$$"
rc=0
printf '%s\n' "${candidates[$matched]}" |
  qpdf --decrypt --password-file=- "$work" "$tmp" || rc=$?
# qpdf exit 3 is "warnings detected"; the output file is still written and sound.
if [[ "$rc" -eq 3 ]]; then
  warn "qpdf reported warnings while decrypting $base; continuing"
elif [[ "$rc" -ne 0 ]]; then
  die "qpdf --decrypt failed on $base (exit $rc)"
fi

rc=0
qpdf --is-encrypted "$tmp" || rc=$?
[[ "$rc" -eq 2 ]] || die "$base is still encrypted after --decrypt (exit $rc) — refusing to hand it to the parser"

# Keep the working copy's timestamps faithful to what paperless handed us.
touch -r "$work" "$tmp"
mv -f "$tmp" "$work"
tmp=""

log "$base decrypted in place; OCR and the stored original will be password-free"
