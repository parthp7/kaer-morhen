#!/usr/bin/env bash
# post-consume-strip-pw.sh — remove the `__pw=` password suffix from the title
# of a document that was uploaded through the pre-consume decrypt escape hatch.
#
# Why this exists
#   pre-consume-decrypt.sh accepts a one-off password as a filename suffix,
#   e.g. `statement__pw=hunter2.pdf`. It can decrypt the file but it cannot
#   rename it: paperless derives both the document title and original_filename
#   from the *upload* filename (consumer.py:839), captured before the hook runs,
#   and the hook may only rewrite the bytes at a fixed path. So the password
#   survives into the title, in the UI and in every list it appears in.
#
#   This hook runs after the document exists and rewrites those two fields.
#   `statement__pw=hunter2` becomes `statement`.
#
# Why it never fails
#   A non-zero exit here makes paperless call _fail() and mark the whole consume
#   task red (consumer.py, POST_CONSUME_SCRIPT_ERROR) even though the document
#   imported perfectly. That is the opposite of what the pre-consume hook wants,
#   and it would be actively misleading: this cleanup is cosmetic. Every path
#   therefore exits 0, and problems are reported on stderr, which paperless logs
#   at WARNING.
#
# Why it re-indexes
#   The search index is written by add_to_index, wired to the
#   document_consumption_finished signal (documents/apps.py:29), which fires
#   BEFORE post-consume scripts. Without an explicit refresh the index would
#   keep the old `__pw=` title: searching the cleaned name would miss, and
#   searching the password would hit. The refresh goes through
#   documents.tasks.bulk_update_documents — the same task the REST API queues
#   after an edit — so it also clears the document caches and inherits that
#   task's index-lock retry handling instead of writing the index from here.
#
# Cost
#   A Django bootstrap is ~8s (measured 2026-09-02), so the shell gates on the
#   marker first: an ordinary upload never gets past the second `if` below and
#   pays nothing.
#
# Contract (paperless-ngx 3.0.x, documents/consumer.py:330)
#   DOCUMENT_ID                 pk of the freshly created document
#   DOCUMENT_ORIGINAL_FILENAME  the upload filename, incl. the __pw= suffix
#   Runs AFTER the consumer's transaction.atomic() block has committed
#   (consumer.py:766 vs :578), so updating the row from this second process
#   cannot deadlock against it.
#
# Wired up by compose as PAPERLESS_POST_CONSUME_SCRIPT. Runs as uid 1000
# (paperless); needs mode 0755.

set -euo pipefail

# Belt and braces: whatever happens below, this hook exits 0. See "Why it never
# fails" above.
trap 'exit 0' EXIT

readonly MARKER='__pw='
readonly PAPERLESS_SRC='/usr/src/paperless/src'

warn() { printf 'post-consume-strip-pw: %s\n' "$*" >&2; }

doc_id="${DOCUMENT_ID:-}"
orig="${DOCUMENT_ORIGINAL_FILENAME:-}"

if [[ -z "$doc_id" ]]; then
  warn "DOCUMENT_ID is unset — not running as a paperless post-consume hook?"
  exit 0
fi

# The cheap gate. Ordinary uploads stop here, before paying for Django.
if [[ "$orig" != *"$MARKER"* ]]; then
  exit 0
fi

# /usr/src/paperless/src is NOT on the default sys.path in this image, and
# PYTHONPATH is unset — the settings module is only importable if we add it.
PYTHONPATH="$PAPERLESS_SRC${PYTHONPATH:+:$PYTHONPATH}" \
  DJANGO_SETTINGS_MODULE=paperless.settings \
  python3 - "$doc_id" <<'PY'
import os
import re
import sys

import django

django.setup()

from documents.models import Document

TAG = "post-consume-strip-pw:"
MARKER_RE = re.compile(r"__pw=.*$")

doc_id = int(sys.argv[1])

try:
    doc = Document.objects.get(pk=doc_id)
except Document.DoesNotExist:
    print(f"{TAG} document {doc_id} no longer exists, nothing to clean", file=sys.stderr)
    sys.exit(0)

changed = []

# Title: strip the marker and everything after it. Refuse to leave an empty
# title behind — a file literally named "__pw=secret.pdf" keeps its odd title
# rather than becoming untitled.
new_title = MARKER_RE.sub("", doc.title)
if new_title and new_title != doc.title:
    doc.title = new_title
    changed.append("title")

# original_filename: strip inside the stem so the extension survives.
if doc.original_filename:
    stem, ext = os.path.splitext(doc.original_filename)
    new_stem = MARKER_RE.sub("", stem)
    if new_stem and new_stem + ext != doc.original_filename:
        doc.original_filename = new_stem + ext
        changed.append("original_filename")

if not changed:
    print(f"{TAG} document {doc_id}: nothing to clean")
    sys.exit(0)

# Full save, not update_fields: this is the same shape of write the REST API
# does on a title edit, so the post_save receivers see a normal update.
doc.save()
print(f"{TAG} document {doc_id} cleaned ({', '.join(changed)}) -> {doc.title!r}")

# Refresh the search index + document caches; see "Why it re-indexes" above.
try:
    from documents.tasks import bulk_update_documents

    kwargs = {"document_ids": [doc_id]}
    try:
        from documents.models import PaperlessTask

        bulk_update_documents.apply_async(
            kwargs=kwargs,
            headers={"trigger_source": PaperlessTask.TriggerSource.SYSTEM},
        )
    except Exception:
        # Older/newer paperless may not label task sources; the refresh matters
        # more than the label.
        bulk_update_documents.apply_async(kwargs=kwargs)
    print(f"{TAG} queued a search-index refresh for document {doc_id}")
except Exception as exc:  # noqa: BLE001 - cosmetic hook, must not fail the task
    print(
        f"{TAG} title cleaned but the index refresh could not be queued: {exc}. "
        f"Search will still match the old title until the next reindex.",
        file=sys.stderr,
    )
PY
