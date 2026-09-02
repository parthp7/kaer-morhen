# scripts/docs — exact-size document shrinking

The deterministic fallback behind the `shrink` stack
([proposal 009](../../docs/proposals/009-document-shrinker.md) §6). Stirling-PDF
and Mazanoke both *iterate* towards a target size; Ghostscript and ImageMagick
can be driven straight at one. When a portal's cap is tighter than the UIs will
reach, this is the way through.

| Script | Does |
|---|---|
| `shrink-to-size.sh` | shrinks a PDF or image to fit a stated KB budget, or fails loudly saying how close it got |

## Usage

```bash
shrink-to-size.sh <input> <target-kb> [output]

shrink-to-size.sh scan.pdf 200            # -> scan-200kb.pdf
shrink-to-size.sh photo.heic 50 sign.jpg  # -> sign.jpg
```

The input is never overwritten, and re-running rebuilds the output from the
input rather than from a previous output, so it is safe to repeat.

## Requirements

`ghostscript` for PDFs, `imagemagick` 7 for images. The script checks for each
one only on the branch that needs it, so an images-only machine does not need
Ghostscript.

```bash
sudo apt install ghostscript imagemagick   # ciri / any Debian or Ubuntu host
brew install ghostscript imagemagick       # macOS
```

## How it works

- **PDFs** step down a DPI ladder (200 → 50) in colour first, then repeat it in
  grayscale, stopping at the first output inside the budget. Colour is dropped
  last because it is the visible change: downsampling alone usually gets there.
  If even 50 dpi grayscale misses, the script says how close it got rather than
  writing an unusable file.
- **Images** use ImageMagick's `-define jpeg:extent=`, which binary-searches
  its own quality setting to land under the budget in a single pass. That only
  applies to JPEG output, which is why the default output extension is `.jpg`
  whatever went in — convenient, since portals that impose small caps almost
  always want JPEG anyway.
- **`-strip`** removes EXIF, which is where a phone photo of a document keeps
  its GPS coordinates. Worth having whether or not the size needs it.

## Scope

Deliberately not wired into any service. OliveTin, arriving with
[proposal 008](../../docs/proposals/008-lab-dashboard.md), has no file-upload
argument type, so the only available wiring would be a watched folder — worse
than either web UI for a one-off shrink.
