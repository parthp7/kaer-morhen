#!/usr/bin/env bash
# shrink-to-size.sh — shrink a PDF or image to fit a byte budget.
#
# Purpose: the deterministic fallback for upload forms with a hard cap that
#          Stirling-PDF or Mazanoke cannot quite hit. Both UIs iterate towards
#          a target; ghostscript and imagemagick can be driven straight at it.
# Usage:   shrink-to-size.sh <input> <target-kb> [output]
#            shrink-to-size.sh scan.pdf 200
#            shrink-to-size.sh photo.heic 50 signature.jpg
# Needs:   ghostscript (PDFs) and imagemagick 7 (images) on PATH.
#          ciri: sudo apt install ghostscript imagemagick
#          mac:  brew install ghostscript imagemagick
# Output:  <name>-<target>kb.<ext> beside the input unless a third argument
#          names one. Never overwrites the input; re-running rebuilds the
#          output from the input, never from a previous output.
# Note:    -strip drops EXIF, which is where a phone photo of a document keeps
#          its GPS coordinates.

set -euo pipefail

die() { printf 'shrink-to-size: %s\n' "$*" >&2; exit 1; }
size_of() { wc -c < "$1" | tr -d '[:space:]'; }

(( $# >= 2 && $# <= 3 )) || die "usage: $(basename "$0") <input> <target-kb> [output]"

in=$1
target_kb=$2
[[ -f $in ]] || die "no such file: $in"
[[ $target_kb =~ ^[1-9][0-9]*$ ]] || die "target-kb must be a positive integer, got: $target_kb"

target_bytes=$(( target_kb * 1024 ))
orig=$(size_of "$in")
base=${in%.*}
ext=$(printf '%s' "${in##*.}" | tr '[:upper:]' '[:lower:]')

# Validate the type BEFORE the size shortcut below, so an unsupported file
# that happens to be small cannot exit 0 looking like a success.
case $ext in
  pdf|jpg|jpeg|png|webp|heic|heif|tif|tiff|bmp) ;;
  *) die "unsupported extension: .$ext (pdf, jpg, jpeg, png, webp, heic, heif, tif, tiff, bmp)" ;;
esac

if (( orig <= target_bytes )); then
  printf 'already %d KB, inside the %d KB budget — nothing to do\n' \
    "$(( orig / 1024 ))" "$target_kb"
  exit 0
fi

case $ext in
  pdf)
    command -v gs >/dev/null 2>&1 || die "ghostscript (gs) not on PATH"
    out=${3:-${base}-${target_kb}kb.pdf}
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    got=$orig
    # Colour before grayscale: dropping colour is a visible change, so only
    # spend it once downsampling alone has failed at every step.
    for mode in color gray; do
      for dpi in 200 150 120 100 72 50; do
        args=(
          -sDEVICE=pdfwrite -dCompatibilityLevel=1.7
          -dNOPAUSE -dBATCH -dQUIET
          -dDetectDuplicateImages=true -dCompressFonts=true -dSubsetFonts=true
          -dDownsampleColorImages=true -dColorImageDownsampleType=/Bicubic
          -dColorImageResolution="$dpi"
          -dDownsampleGrayImages=true -dGrayImageDownsampleType=/Bicubic
          -dGrayImageResolution="$dpi"
          -dDownsampleMonoImages=true -dMonoImageDownsampleType=/Subsample
          -dMonoImageResolution=$(( dpi * 2 ))
        )
        if [[ $mode == gray ]]; then
          args+=(-sColorConversionStrategy=Gray -dProcessColorModel=/DeviceGray)
        fi
        gs "${args[@]}" -sOutputFile="$tmp/try.pdf" "$in"
        got=$(size_of "$tmp/try.pdf")
        if (( got <= target_bytes )); then
          cp "$tmp/try.pdf" "$out"
          printf '%s: %d KB -> %d KB (%s, %d dpi)\n' \
            "$out" "$(( orig / 1024 ))" "$(( got / 1024 ))" "$mode" "$dpi"
          exit 0
        fi
      done
    done
    die "cannot reach ${target_kb} KB; the smallest attempt was $(( got / 1024 )) KB at 50 dpi grayscale. Split the document or drop pages."
    ;;
  *)
    # Images. The extension was whitelisted above, so this is not a catch-all.
    command -v magick >/dev/null 2>&1 || die "imagemagick 7 (magick) not on PATH"
    # jpeg:extent only applies to JPEG output, which is why the default
    # output extension is .jpg whatever went in.
    out=${3:-${base}-${target_kb}kb.jpg}
    magick "$in" -auto-orient -strip -define jpeg:extent="${target_kb}kb" "$out"
    got=$(size_of "$out")
    (( got <= target_bytes )) || die "landed at $(( got / 1024 )) KB, over budget. Add a resize: magick '$in' -resize 50% -strip -define jpeg:extent=${target_kb}kb '$out'"
    printf '%s: %d KB -> %d KB\n' "$out" "$(( orig / 1024 ))" "$(( got / 1024 ))"
    ;;
esac
