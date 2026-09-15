#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------
# Optional .env
# ---------------------------------------------------------

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# ---------------------------------------------------------
# Printer
# ---------------------------------------------------------

PRINTER_DEVICE="${PRINTER_DEVICE:-/dev/usb/lp1}"
SNIPE_URL="${SNIPE_URL:-https://elecrics.vicpro.co}"

# ---------------------------------------------------------
# Test data / command-line arguments
#
# ./print_label.sh \
#   ELE00027 \
#   "Dell OptiPlex 7050" \
#   ABC1234 \
#   i7-7700 \
#   16GB \
#   512GB \
#   27
# ---------------------------------------------------------

ASSET_TAG="${1:-ELE00027}"
MODEL="${2:-Dell OptiPlex 7050}"
SERIAL="${3:-ABC1234}"
CPU="${4:-i7-7700}"
RAM="${5:-16GB}"
STORAGE="${6:-512GB}"
ASSET_ID="${7:-27}"

QR_URL="${SNIPE_URL}/hardware/${ASSET_ID}"

# ---------------------------------------------------------
# Checks
# ---------------------------------------------------------

if [ ! -e "$PRINTER_DEVICE" ]; then
    echo "ERROR: Printer not found: $PRINTER_DEVICE"
    exit 1
fi

echo "Printing 3x1 label..."
echo
echo "Asset Tag: $ASSET_TAG"
echo "Model:     $MODEL"
echo "Serial:    $SERIAL"
echo "Hardware:  $CPU / $RAM / $STORAGE"
echo "QR:        $QR_URL"
echo "Printer:   $PRINTER_DEVICE"
echo

# ---------------------------------------------------------
# Generate ESC/POS raster data
# ---------------------------------------------------------

TMP_FILE=$(mktemp /tmp/label-XXXXXX.bin)

python3 - \
    "$ASSET_TAG" \
    "$MODEL" \
    "$SERIAL" \
    "$CPU" \
    "$RAM" \
    "$STORAGE" \
    "$QR_URL" \
    "$TMP_FILE" <<'PYTHON'

import sys
import struct
from PIL import Image, ImageDraw, ImageFont
import qrcode

asset_tag = sys.argv[1]
model     = sys.argv[2]
serial    = sys.argv[3]
cpu       = sys.argv[4]
ram       = sys.argv[5]
storage   = sys.argv[6]
qr_url    = sys.argv[7]
outfile   = sys.argv[8]

# =========================================================
# LABEL SIZE
#
# POS80 commonly provides 576 printable dots.
#
# At ~203 DPI:
#   3" x 1" ~= 609 x 203 dots
#
# We deliberately use 576 x 200 so it fits inside
# the printable area of common 80 mm ESC/POS printers.
# =========================================================

WIDTH  = 576
HEIGHT = 200

img = Image.new("1", (WIDTH, HEIGHT), 1)
draw = ImageDraw.Draw(img)

# =========================================================
# FONTS
# =========================================================

font_paths = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf",
]

regular_paths = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
]

def load_font(paths, size):
    for path in paths:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            pass
    return ImageFont.load_default()

font_tag   = load_font(font_paths, 30)
font_model = load_font(font_paths, 22)
font_text  = load_font(regular_paths, 19)
font_hw    = load_font(font_paths, 19)
font_all = load_font(font_paths, 30)

# =========================================================
# QR CODE
# =========================================================

qr = qrcode.QRCode(
    version=None,
    error_correction=qrcode.constants.ERROR_CORRECT_M,
    box_size=4,
    border=1,
)

qr.add_data(qr_url)
qr.make(fit=True)

qr_img = qr.make_image(fill_color="black", back_color="white")
qr_img = qr_img.convert("1")

QR_SIZE = 178

qr_img = qr_img.resize((QR_SIZE, QR_SIZE))

QR_X = 8
QR_Y = 10

img.paste(qr_img, (QR_X, QR_Y))

# =========================================================
# TEXT AREA
# =========================================================

TEXT_X = 200
MAX_X  = WIDTH - 8

def fit_text(text, font, max_width):
    """
    Trim long strings so they fit the label.
    """
    if not text:
        return ""

    candidate = text

    while candidate:
        box = draw.textbbox((0, 0), candidate, font=font)
        width = box[2] - box[0]

        if width <= max_width:
            return candidate

        candidate = candidate[:-1]

    return ""

text_width = MAX_X - TEXT_X

# Asset Tag
draw.text(
    (TEXT_X, 8),
    fit_text(asset_tag, font_all, text_width),
    font=font_all,
    fill=0
)

# Model
model_text = fit_text(model, font_all, text_width)

draw.text(
    (TEXT_X, 51),
    model_text,
    font=font_all,
    fill=0
)

# Serial
serial_text = f"SN: {serial}"

draw.text(
    (TEXT_X, 91),
    fit_text(serial_text, font_all, text_width),
    font=font_all,
    fill=0
)

# Hardware summary
hardware = f"{cpu} / {ram} / {storage}"

draw.text(
    (TEXT_X, 130),
    fit_text(hardware, font_all, text_width),
    font=font_all,
    fill=0
)

# =========================================================
# ESC/POS RASTER
#
# GS v 0
# =========================================================

# Width must be a multiple of 8
width_bytes = (WIDTH + 7) // 8

data = bytearray()

pixels = img.load()

for y in range(HEIGHT):

    for xb in range(width_bytes):

        byte = 0

        for bit in range(8):

            x = xb * 8 + bit

            if x < WIDTH:
                # PIL 1-bit:
                # 0 = black
                # 255/1 = white
                pixel = pixels[x, y]

                if pixel == 0:
                    byte |= 1 << (7 - bit)

        data.append(byte)

xL = width_bytes & 0xff
xH = (width_bytes >> 8) & 0xff

yL = HEIGHT & 0xff
yH = (HEIGHT >> 8) & 0xff

with open(outfile, "wb") as f:

    # Initialize printer
    f.write(b"\x1b\x40")

    # Align left
    f.write(b"\x1b\x61\x00")

    # Raster bitmap
    f.write(
        b"\x1d\x76\x30\x00" +
        bytes([xL, xH, yL, yH]) +
        data
    )

    # Small feed
    f.write(b"\n\n")

PYTHON

# ---------------------------------------------------------
# Send to printer
# ---------------------------------------------------------

sudo tee "$PRINTER_DEVICE" < "$TMP_FILE" >/dev/null

rm -f "$TMP_FILE"

echo "Label printed successfully."
