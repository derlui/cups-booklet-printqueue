#!/bin/bash
# install-booklet-printqueue.sh
# Installs virtual CUPS "Booklet-*" printers that impose PDFs for saddle-stitch booklet printing.
# Usage: sudo ./install-booklet-printqueue.sh [--install | --remove | --help]
set -euo pipefail

FILTER_PATH=/usr/lib/cups/filter/cups-booklet-filter
PPD_PATH=/usr/share/cups/model/BookletPrinter.ppd
CONF=/etc/booklet-printers.conf
BACKEND_PATH=/usr/lib/cups/backend/booklet
PREFIX="Booklet-"
ME=$(basename "$0")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  cat <<USAGE
Usage: sudo $ME [--install | --remove | --help]

  --install   Install/update Booklet PrintQueue (default)
  --remove    Remove all Booklet queues and associated files
  --help      Show this help

The script creates virtual CUPS printers named Booklet-<PrinterName> that
perform booklet imposition via pypdf and forward jobs to a real printer.
USAGE
  exit 0
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

# ---------------------------------------------------------------------------
# Reload CUPS (shared)
# ---------------------------------------------------------------------------

reload_cups() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload-or-restart cups 2>/dev/null || true
  else
    service cups restart 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Remove mode
# ---------------------------------------------------------------------------

do_remove() {
  echo "==> Removing Booklet PrintQueue..."
  if [[ -f "$CONF" ]]; then
    while IFS='|' read -r qname _uri || [[ -n "$qname" ]]; do
      [[ -z "$qname" ]] && continue
      fullname="${PREFIX}${qname}"
      info "Removing queue: $fullname"
      lpadmin -x "$fullname" 2>/dev/null || true
    done < "$CONF"
  fi
  rm -f "$FILTER_PATH" "$PPD_PATH" "$CONF" "$BACKEND_PATH"
  reload_cups
  echo "==> Done. All Booklet queues and files removed."
}

# ---------------------------------------------------------------------------
# Write Python filter
# ---------------------------------------------------------------------------

write_filter() {
  cat > "$FILTER_PATH" <<'PYEOF'
#!/usr/bin/env python3
"""
cups-booklet-filter — CUPS filter for booklet imposition using pypdf.

CUPS calling convention:
  filter <job-id> <user> <title> <copies> <options> [<filename>]

Standalone / test mode:
  filter input.pdf > output.pdf
"""

import sys
import io
import traceback


def log(level, msg):
    print(f"{level}: {msg}", file=sys.stderr, flush=True)


def impose_booklet(src_bytes: bytes) -> bytes:
    try:
        from pypdf import PdfReader, PdfWriter, PageObject, Transformation
    except ImportError:
        log("ERROR", "pypdf is not installed. Run: pip3 install pypdf")
        sys.exit(1)

    reader = PdfReader(io.BytesIO(src_bytes))
    n_orig = len(reader.pages)
    if n_orig == 0:
        log("ERROR", "Input PDF has no pages.")
        sys.exit(1)

    # Normalise rotations into content streams
    pages = []
    for p in reader.pages:
        p.transfer_rotation_to_content()
        pages.append(p)

    # Pad to multiple of 4 with blank pages
    while len(pages) % 4 != 0:
        blank = PageObject.create_blank_page(
            width=pages[0].mediabox.width,
            height=pages[0].mediabox.height,
        )
        pages.append(blank)
    N = len(pages)
    log("INFO", f"Imposing {n_orig} pages (padded to {N}) into booklet layout")

    # Saddle-stitch booklet page ordering (0-based)
    order = []
    for i in range(N // 2):
        if i % 2 == 0:
            order.append((N - 1 - i, i))   # (left, right)
        else:
            order.append((i, N - 1 - i))   # (left, right)

    # Output page dimensions: landscape, two input pages side-by-side
    mb = pages[0].mediabox
    pw = float(mb.width)
    ph = float(mb.height)
    out_w = max(pw, ph)
    out_h = min(pw, ph)
    half_w = out_w / 2.0

    writer = PdfWriter()

    for left_idx, right_idx in order:
        out_page = PageObject.create_blank_page(width=out_w, height=out_h)

        for col, src_idx in enumerate((left_idx, right_idx)):
            src = pages[src_idx]
            mb_src = src.mediabox
            src_w = float(mb_src.width)
            src_h = float(mb_src.height)
            llx = float(mb_src.left)
            lly = float(mb_src.bottom)

            # Scale uniformly to fit half-slot, then centre
            scale = min(half_w / src_w, out_h / src_h)
            placed_w = src_w * scale
            placed_h = src_h * scale
            tx = col * half_w + (half_w - placed_w) / 2 - llx * scale
            ty = (out_h - placed_h) / 2 - lly * scale

            t = Transformation(ctm=(scale, 0, 0, scale, tx, ty))
            out_page.merge_transformed_page(src, t)

        writer.add_page(out_page)

    buf = io.BytesIO()
    writer.write(buf)
    return buf.getvalue()


def main():
    args = sys.argv[1:]

    # CUPS calling convention: filter job-id user title copies options [filename]
    # Standalone / test: filter input.pdf > output.pdf
    filename = None
    if len(args) >= 5:
        # CUPS mode
        if len(args) >= 6:
            filename = args[5]
    elif len(args) == 1 and not args[0].isdigit():
        # Standalone single-file mode
        filename = args[0]

    try:
        if filename:
            log("INFO", f"Reading from file: {filename}")
            with open(filename, "rb") as fh:
                src_bytes = fh.read()
        else:
            log("INFO", "Reading from stdin")
            src_bytes = sys.stdin.buffer.read()

        result = impose_booklet(src_bytes)
        sys.stdout.buffer.write(result)
        sys.stdout.buffer.flush()
        log("INFO", "Booklet imposition complete")

    except Exception as exc:
        log("ERROR", f"Filter failed: {exc}")
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
PYEOF
  chmod 755 "$FILTER_PATH"
  chown root:root "$FILTER_PATH"
  info "Filter written to $FILTER_PATH"
}

# ---------------------------------------------------------------------------
# Write PPD
# ---------------------------------------------------------------------------

write_ppd() {
  cat > "$PPD_PATH" <<'PPDEOF'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*Manufacturer: "Booklet PrintQueue"
*ModelName: "Booklet Printer"
*ShortNickName: "Booklet Printer"
*NickName: "Booklet Printer"
*Product: "(Booklet Printer)"
*PSVersion: "(3010) 0"
*PCFileName: "BOOKLET.PPD"
*cupsFilter: "application/vnd.cups-pdf 0 cups-booklet-filter"
*ColorDevice: True
*DefaultColorSpace: RGB

*% ---- Page Sizes ----

*OpenUI *PageSize/Media Size: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: A4
*PageSize A4/A4: "<</PageSize[595 842]/ImagingBBox null>>setpagedevice"
*PageSize Letter/Letter: "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageSize

*OpenUI *PageRegion: PickOne
*OrderDependency: 10 AnySetup *PageRegion
*DefaultPageRegion: A4
*PageRegion A4/A4: "<</PageSize[595 842]/ImagingBBox null>>setpagedevice"
*PageRegion Letter/Letter: "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageRegion

*DefaultImageableArea: A4
*ImageableArea A4/A4: "0 0 595 842"
*ImageableArea Letter/Letter: "0 0 612 792"

*DefaultPaperDimension: A4
*PaperDimension A4/A4: "595 842"
*PaperDimension Letter/Letter: "612 792"

*% ---- Duplex ----

*OpenUI *Duplex/Two-Sided Printing: PickOne
*OrderDependency: 20 AnySetup *Duplex
*DefaultDuplex: DuplexTumble
*Duplex None/Off (One-Sided): "<</Duplex false>>setpagedevice"
*Duplex DuplexNoTumble/Long-Edge (Portrait): "<</Duplex true/Tumble false>>setpagedevice"
*Duplex DuplexTumble/Short-Edge (Landscape): "<</Duplex true/Tumble true>>setpagedevice"
*CloseUI: *Duplex

*% End of BookletPrinter.ppd
PPDEOF
  chmod 644 "$PPD_PATH"
  chown root:root "$PPD_PATH"
  info "PPD written to $PPD_PATH"
}

# ---------------------------------------------------------------------------
# Write backend
# ---------------------------------------------------------------------------

write_backend() {
  cat > "$BACKEND_PATH" <<'BACKENDEOF'
#!/bin/bash
# cups booklet backend — receives imposed PDF and forwards to real printer with forced duplex.
# CUPS sets DEVICE_URI env var: booklet://TargetQueueName

# Discovery mode (called with no args)
if [ "$#" -eq 0 ]; then
    echo "network booklet \"Unknown\" \"Booklet Forwarder\""
    exit 0
fi

# Args: job-id user title copies options [filename]
TITLE="$3"
COPIES="$4"
OPTIONS="$5"
FILENAME="${6:-}"

DEST="${DEVICE_URI#booklet://}"
if [ -z "$DEST" ]; then
    echo "ERROR: DEVICE_URI not set or missing target queue" >&2
    exit 1
fi

# Strip options that must not be forwarded or that we override
# sides: we force our own; others would double-apply filter-level settings
CLEAN_OPTS=$(printf '%s' "$OPTIONS" | tr ' ' '\n' \
    | grep -vE '^(sides|number-up|job-sheets|outputorder|mirror|page-border|fit-to-page)=' \
    | tr '\n' ' ')

echo "INFO: Forwarding booklet job to $DEST with sides=two-sided-short-edge" >&2

if [ -n "$FILENAME" ] && [ -f "$FILENAME" ]; then
    exec lp -d "$DEST" -n "$COPIES" -t "$TITLE" -o "$CLEAN_OPTS" -o sides=two-sided-short-edge "$FILENAME"
else
    exec lp -d "$DEST" -n "$COPIES" -t "$TITLE" -o "$CLEAN_OPTS" -o sides=two-sided-short-edge -
fi
BACKENDEOF
  chmod 0500 "$BACKEND_PATH"
  chown root:root "$BACKEND_PATH"
  info "Backend written to $BACKEND_PATH"
}

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------

install_deps() {
  echo "==> Installing dependencies..."
  if ! command -v apt-get >/dev/null 2>&1; then
    die "This script requires an apt-based distro (Debian/Ubuntu)."
  fi
  if apt-get install -y python3 python3-pypdf 2>/dev/null; then
    info "Installed via apt: python3, python3-pypdf"
  else
    info "python3-pypdf not available in apt, falling back to pip3..."
    apt-get install -y python3 python3-pip
    pip3 install --quiet pypdf
    info "Installed pypdf via pip3"
  fi
}

# ---------------------------------------------------------------------------
# Printer selection
# ---------------------------------------------------------------------------

detect_printers() {
  lpstat -p 2>/dev/null | awk '{print $2}' | grep -v "^${PREFIX}" || true
}

select_printers() {
  mapfile -t DETECTED < <(detect_printers)

  echo ""
  if [[ ${#DETECTED[@]} -gt 0 ]]; then
    echo "Detected CUPS printers (excluding existing Booklet- queues):"
    for i in "${!DETECTED[@]}"; do
      printf "  [%d] %s\n" "$((i+1))" "${DETECTED[$i]}"
    done
    echo ""
    echo "Enter numbers (comma-separated) to wrap in Booklet queues, e.g.:  1,3"
    echo "Or type a full URI (ipp://host/printers/name) directly."
    echo "You can mix numbers and URIs. Submit an empty line when done."
  else
    echo "No existing CUPS printers detected."
    echo "Enter full printer URIs (e.g. ipp://host/printers/name), one per line."
    echo "Submit an empty line when done."
  fi

  SELECTED_NAMES=()
  SELECTED_URIS=()

  while true; do
    read -r -p "> " entry || break
    [[ -z "$entry" ]] && break

    IFS=',' read -ra parts <<< "$entry"
    for part in "${parts[@]}"; do
      part="${part// /}"   # strip spaces
      if [[ "$part" =~ ^[0-9]+$ ]]; then
        idx=$((part - 1))
        if [[ $idx -ge 0 && $idx -lt ${#DETECTED[@]} ]]; then
          name="${DETECTED[$idx]}"
          SELECTED_NAMES+=("$name")
          SELECTED_URIS+=("booklet://${name}")
          info "Selected: $name"
        else
          echo "  Warning: number $part is out of range, skipping."
        fi
      elif [[ "$part" =~ ^(ipp|ipps|socket|lpd|http|https):// ]]; then
        name="${part%/}"
        name="${name##*/}"
        name="${name// /_}"
        SELECTED_NAMES+=("$name")
        SELECTED_URIS+=("booklet://${name}")
        info "Selected URI: $part (queue name: $name)"
      else
        echo "  Warning: '$part' is not a valid number or URI, skipping."
      fi
    done
  done

  if [[ ${#SELECTED_NAMES[@]} -eq 0 ]]; then
    die "No printers selected. Aborting."
  fi
}

# ---------------------------------------------------------------------------
# Create CUPS queues
# ---------------------------------------------------------------------------

create_queues() {
  : > "$CONF"   # truncate / create config
  local lpadmin_err derived_ppd
  lpadmin_err=$(mktemp)
  echo "==> Creating Booklet queues..."

  for i in "${!SELECTED_NAMES[@]}"; do
    name="${SELECTED_NAMES[$i]}"
    uri="${SELECTED_URIS[$i]}"
    qname="${PREFIX}${name// /_}"

    # Determine PPD to use: prefer real printer's PPD with booklet filter injected
    real_ppd="/etc/cups/ppd/${name}.ppd"
    if [[ -f "$real_ppd" ]]; then
      derived_ppd=$(mktemp --suffix=.ppd)
      grep -v '^\*cupsFilter' "$real_ppd" > "$derived_ppd"
      echo '*cupsFilter: "application/vnd.cups-pdf 0 cups-booklet-filter"' >> "$derived_ppd"
      selected_ppd="$derived_ppd"
      info "Using real printer PPD for $qname"
    else
      derived_ppd=""
      selected_ppd="$PPD_PATH"
      info "Using generic PPD for $qname (real PPD not found at $real_ppd)"
    fi

    info "Creating $qname -> $uri"
    if lpadmin -p "$qname" -E -v "$uri" -P "$selected_ppd" 2>"$lpadmin_err"; then
      lpadmin -p "$qname" -o sides=two-sided-short-edge || true
      echo "${name}|${uri}" >> "$CONF"
      info "OK: $qname"
    else
      echo "  WARNING: lpadmin failed for $qname; skipping." >&2
      cat "$lpadmin_err" >&2
    fi

    # lpadmin copies the PPD internally; delete our temp file
    [[ -n "$derived_ppd" ]] && rm -f "$derived_ppd"
  done

  rm -f "$lpadmin_err"
}

# ---------------------------------------------------------------------------
# Install mode
# ---------------------------------------------------------------------------

do_install() {
  echo "==> Booklet PrintQueue Installer"
  install_deps
  write_filter
  write_ppd
  write_backend
  select_printers
  create_queues
  reload_cups

  echo ""
  echo "==> Installation complete."
  if [[ -s "$CONF" ]]; then
    echo "    Queues created:"
    while IFS='|' read -r qname _uri; do
      [[ -z "$qname" ]] && continue
      echo "      ${PREFIX}${qname}"
    done < "$CONF"
  fi
  echo ""
  echo "    Config : $CONF"
  echo "    Filter : $FILTER_PATH"
  echo "    PPD    : $PPD_PATH"
  echo ""
  echo "    To uninstall: sudo $ME --remove"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

[[ "$(id -u)" -ne 0 ]] && die "This script must be run as root: sudo $ME"

case "${1:-}" in
  --help|-h)    usage ;;
  --remove)     do_remove ;;
  --install|"") do_install ;;
  *)            die "Unknown option: $1  (use --help for usage)" ;;
esac
