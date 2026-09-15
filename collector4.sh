#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found:"
    echo "$ENV_FILE"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

if [ -z "${SNIPE_TOKEN:-}" ]; then
    echo "ERROR: SNIPE_TOKEN is not defined in .env"
    exit 1
fi

SNIPE_URL="${SNIPE_URL:-https://elecrics.vicpro.co}"

STATUS_ID=4
MODEL_ID=1

GLPI_APPIMAGE="$SCRIPT_DIR/glpi-agent-1.19-x86_64.AppImage"
INVENTORY_JSON="/tmp/glpi-inventory.json"

# =========================================================
# CHECKS
# =========================================================

if [ -z "${SNIPE_TOKEN:-}" ]; then
    echo "ERROR: SNIPE_TOKEN is not defined."
    echo "Run:"
    echo "export SNIPE_TOKEN='YOUR_TOKEN'"
    exit 1
fi

for CMD in jq curl; do
    command -v "$CMD" >/dev/null 2>&1 || {
        echo "ERROR: $CMD is required."
        exit 1
    }
done

if [ ! -x "$GLPI_APPIMAGE" ]; then
    echo "ERROR: GLPI AppImage not found or not executable:"
    echo "$GLPI_APPIMAGE"
    exit 1
fi

# =========================================================
# RUN GLPI INVENTORY
# =========================================================

echo "Running GLPI Agent inventory..."

sudo "$GLPI_APPIMAGE" \
    --script=glpi-inventory \
    --json > "$INVENTORY_JSON"

if ! jq -e . "$INVENTORY_JSON" >/dev/null 2>&1; then
    echo "ERROR: GLPI Agent did not generate valid JSON."
    exit 1
fi

# =========================================================
# SYSTEM
# =========================================================

MANUFACTURER=$(jq -r '.content.bios.smanufacturer // "Unknown"' "$INVENTORY_JSON")
MODEL=$(jq -r '.content.bios.smodel // "Unknown"' "$INVENTORY_JSON")
SERIAL=$(jq -r '.content.bios.ssn // "Unknown"' "$INVENTORY_JSON")
UUID=$(jq -r '.content.hardware.uuid // "Unknown"' "$INVENTORY_JSON")
CHASSIS=$(jq -r '.content.hardware.chassis_type // "Unknown"' "$INVENTORY_JSON")

NAME="$MANUFACTURER $MODEL"

# =========================================================
# CPU
# =========================================================

CPU=$(jq -r '
    .content.cpus
    | map(.name)
    | unique
    | join("; ")
' "$INVENTORY_JSON")

# =========================================================
# RAM TOTAL
# GLPI reports capacity in MB
# =========================================================

RAM_MB=$(jq '
    [.content.memories[]?.capacity // 0]
    | add // 0
' "$INVENTORY_JSON")

RAM_TOTAL="$((RAM_MB / 1024)) GB"

# =========================================================
# MEMORY DETAILS
# =========================================================

MEMORY_DETAILS=$(jq -r '
    .content.memories[]?
    |
    "\(.caption // "Unknown Slot") | " +
    "\((.capacity // 0) / 1024 | floor) GB | " +
    "\(.type // "Unknown") | " +
    "\(.speed // "Unknown") MT/s | " +
    "\(.manufacturer // "Unknown") | " +
    "SN \(.serialnumber // "Unknown") | " +
    "PN \(.model // "Unknown")"
' "$INVENTORY_JSON")

# =========================================================
# STORAGE
#
# Only physical non-removable disks.
# GLPI disksize is reported in MB.
# =========================================================

STORAGE=$(jq -r '
    [
        .content.storages[]?
        | select(.type != "removable")
        | select(.type == "disk")
        |
        "\(.model // "Unknown") | " +
        "SN \(.serial // "Unknown") | " +
        "\(
            if (.disksize // 0) >= 1000000
            then (((.disksize / 1000000) * 10 | floor) / 10 | tostring) + " TB"
            else (((.disksize / 1000) | floor) | tostring) + " GB"
            end
        ) | " +
        "\(.interface // "Unknown")"
    ]
    | join("; ")
' "$INVENTORY_JSON")

# =========================================================
# NETWORK
#
# Prefer physical ethernet.
# If none, use physical Wi-Fi.
# =========================================================

MAC=$(jq -r '
    (
        [
            .content.networks[]?
            | select(.virtualdev == false)
            | select(.type == "ethernet")
            | .mac
            | select(. != null)
        ][0]
    ) //
    (
        [
            .content.networks[]?
            | select(.virtualdev == false)
            | select(.type == "wifi")
            | .mac
            | select(. != null)
        ][0]
    ) //
    ""
' "$INVENTORY_JSON")

ETHERNET_MAC=$(jq -r '
    [
        .content.networks[]?
        | select(.virtualdev == false)
        | select(.type == "ethernet")
        | .mac
        | select(. != null)
    ][0] // ""
' "$INVENTORY_JSON")

WIFI_MAC=$(jq -r '
    [
        .content.networks[]?
        | select(.virtualdev == false)
        | select(.type == "wifi")
        | .mac
        | select(. != null)
    ][0] // ""
' "$INVENTORY_JSON")

# =========================================================
# LOT
# =========================================================

echo
read -r -p "Lot ID (leave blank if none): " LOT_ID

# =========================================================
# DISPLAY
# =========================================================

echo
echo "======================================================"
echo "              GLPI HARDWARE INVENTORY"
echo "======================================================"
echo "Manufacturer: $MANUFACTURER"
echo "Model:        $MODEL"
echo "Serial:       $SERIAL"
echo "UUID:         $UUID"
echo "Chassis:      $CHASSIS"
echo "CPU:          $CPU"
echo "RAM Total:    $RAM_TOTAL"
echo
echo "Memory:"
echo "$MEMORY_DETAILS" | sed 's/^/  /'
echo
echo "Storage:"
echo "  $STORAGE"
echo
echo "Ethernet MAC: $ETHERNET_MAC"
echo "Wi-Fi MAC:    $WIFI_MAC"
echo "Primary MAC:  $MAC"
echo "Lot ID:       ${LOT_ID:-None}"
echo "======================================================"
echo

# =========================================================
# VALIDATION
# =========================================================

if [ "$SERIAL" = "Unknown" ] || [ -z "$SERIAL" ]; then
    echo "ERROR: No valid system serial number detected."
    exit 1
fi

# =========================================================
# DUPLICATE CHECK
# =========================================================

echo "Checking Snipe-IT for serial $SERIAL..."

EXISTING=$(curl -s \
    -G \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    --data-urlencode "search=$SERIAL" \
    "$SNIPE_URL/api/v1/hardware")

EXISTING_ID=$(echo "$EXISTING" | jq -r \
    --arg SERIAL "$SERIAL" \
    '.rows[]? | select(.serial == $SERIAL) | .id' \
    | head -1)

if [ -n "$EXISTING_ID" ]; then

    EXISTING_TAG=$(echo "$EXISTING" | jq -r \
        --arg SERIAL "$SERIAL" \
        '.rows[]? | select(.serial == $SERIAL) | .asset_tag' \
        | head -1)

    echo
    echo "======================================================"
    echo "ASSET ALREADY EXISTS"
    echo "Asset ID:  $EXISTING_ID"
    echo "Asset Tag: $EXISTING_TAG"
    echo "Serial:    $SERIAL"
    echo "======================================================"
    exit 0
fi

# =========================================================
# CONFIRM
# =========================================================

read -r -p "Create this asset in Snipe-IT? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# =========================================================
# BUILD JSON
# =========================================================

JSON=$(jq -n \
    --arg name "$NAME" \
    --arg serial "$SERIAL" \
    --arg cpu "$CPU" \
    --arg ram "$RAM_TOTAL" \
    --arg memory "$MEMORY_DETAILS" \
    --arg storage "$STORAGE" \
    --arg uuid "$UUID" \
    --arg mac "$MAC" \
    --arg lot "$LOT_ID" \
    --argjson model_id "$MODEL_ID" \
    --argjson status_id "$STATUS_ID" \
    '{
        model_id: $model_id,
        status_id: $status_id,
        name: $name,
        serial: $serial,
        "_snipeit_cpu_2": $cpu,
        "_snipeit_storage_3": $storage,
        "_snipeit_system_uuid_4": $uuid,
        "_snipeit_mac_address_1": $mac,
        "_snipeit_lot_id_5": $lot,
        "_snipeit_ram_total_6": $ram,
        "_snipeit_memory_details_7": $memory
    }')

# =========================================================
# CREATE ASSET
# =========================================================

echo
echo "Sending asset to Snipe-IT..."

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$SNIPE_URL/api/v1/hardware" \
    -d "$JSON")

echo
echo "$RESPONSE" | jq

STATUS=$(echo "$RESPONSE" | jq -r '.status // empty')

if [ "$STATUS" = "success" ]; then

    ASSET_TAG=$(echo "$RESPONSE" | jq -r '.payload.asset_tag')

    echo
    echo "======================================================"
    echo "ASSET CREATED SUCCESSFULLY"
    echo
    echo "Asset Tag:    $ASSET_TAG"
    echo "Manufacturer: $MANUFACTURER"
    echo "Model:        $MODEL"
    echo "Serial:       $SERIAL"
    echo "RAM:          $RAM_TOTAL"
    echo "======================================================"

else

    echo
    echo "ERROR creating asset in Snipe-IT."
    exit 1

fi
