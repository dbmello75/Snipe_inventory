#!/bin/bash

set -euo pipefail

# =========================================================
# PATHS / ENV
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found: $ENV_FILE"
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

GLPI_APPIMAGE="$SCRIPT_DIR/glpi-agent-1.19-x86_64.AppImage"
INVENTORY_JSON="/tmp/glpi-inventory.json"

STATUS_ID=4
FIELDSET_ID=2

# Categories
CATEGORY_LAPTOP=2
CATEGORY_DESKTOP=3
CATEGORY_MINIPC=4

# =========================================================
# REQUIREMENTS
# =========================================================

for CMD in jq curl; do
    command -v "$CMD" >/dev/null 2>&1 || {
        echo "ERROR: $CMD is required."
        exit 1
    }
done

if [ ! -x "$GLPI_APPIMAGE" ]; then
    echo "ERROR: GLPI AppImage not found or not executable."
    exit 1
fi

# =========================================================
# GLPI INVENTORY
# =========================================================

echo "Running GLPI Agent inventory..."

sudo "$GLPI_APPIMAGE" \
    --script=glpi-inventory \
    --json > "$INVENTORY_JSON"

jq -e . "$INVENTORY_JSON" >/dev/null || {
    echo "ERROR: Invalid GLPI inventory JSON."
    exit 1
}

# =========================================================
# BASIC SYSTEM INFO
# =========================================================

MANUFACTURER=$(jq -r '.content.bios.smanufacturer // "Unknown"' "$INVENTORY_JSON")
MODEL=$(jq -r '.content.bios.smodel // "Unknown"' "$INVENTORY_JSON")
SERIAL=$(jq -r '.content.bios.ssn // "Unknown"' "$INVENTORY_JSON")
UUID=$(jq -r '.content.hardware.uuid // "Unknown"' "$INVENTORY_JSON")
CHASSIS=$(jq -r '.content.hardware.chassis_type // "Unknown"' "$INVENTORY_JSON")

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
# MEMORY
# =========================================================

RAM_MB=$(jq '
    [.content.memories[]?.capacity // 0]
    | add // 0
' "$INVENTORY_JSON")

RAM_TOTAL="$((RAM_MB / 1024)) GB"

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
# =========================================================

STORAGE=$(jq -r '
    [
        .content.storages[]?
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

# =========================================================
# CATEGORY DETECTION
# =========================================================

CHASSIS_LC=$(echo "$CHASSIS" | tr '[:upper:]' '[:lower:]')

case "$CHASSIS_LC" in
    *mini*)
        CATEGORY_ID=$CATEGORY_MINIPC
        CATEGORY_NAME="Mini PC"
        ;;
    *laptop*|*notebook*|*portable*)
        CATEGORY_ID=$CATEGORY_LAPTOP
        CATEGORY_NAME="Laptop"
        ;;
    *desktop*|*tower*)
        CATEGORY_ID=$CATEGORY_DESKTOP
        CATEGORY_NAME="Desktop"
        ;;
    *)
        echo
        echo "Unknown chassis type: $CHASSIS"
        echo "Select category:"
        echo "1) Laptop"
        echo "2) Desktop"
        echo "3) Mini PC"
        read -r -p "> " CHOICE

        case "$CHOICE" in
            1)
                CATEGORY_ID=$CATEGORY_LAPTOP
                CATEGORY_NAME="Laptop"
                ;;
            2)
                CATEGORY_ID=$CATEGORY_DESKTOP
                CATEGORY_NAME="Desktop"
                ;;
            3)
                CATEGORY_ID=$CATEGORY_MINIPC
                CATEGORY_NAME="Mini PC"
                ;;
            *)
                echo "Invalid selection."
                exit 1
                ;;
        esac
        ;;
esac

# =========================================================
# FIND / CREATE MANUFACTURER
# =========================================================

echo "Checking manufacturer: $MANUFACTURER"

MANUFACTURER_RESPONSE=$(curl -s \
    -G \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    --data-urlencode "name=$MANUFACTURER" \
    "$SNIPE_URL/api/v1/manufacturers")

MANUFACTURER_ID=$(echo "$MANUFACTURER_RESPONSE" | jq -r \
    --arg NAME "$MANUFACTURER" \
    '.rows[]? | select((.name | ascii_downcase) == ($NAME | ascii_downcase)) | .id' \
    | head -1)

if [ -z "$MANUFACTURER_ID" ]; then

    echo "Manufacturer not found. Creating..."

    MANUFACTURER_CREATE=$(jq -n \
        --arg name "$MANUFACTURER" \
        '{name:$name}')

    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "$SNIPE_URL/api/v1/manufacturers" \
        -d "$MANUFACTURER_CREATE")

    MANUFACTURER_ID=$(echo "$RESPONSE" | jq -r '.payload.id // empty')

    if [ -z "$MANUFACTURER_ID" ]; then
        echo "ERROR creating manufacturer:"
        echo "$RESPONSE" | jq
        exit 1
    fi

    echo "Manufacturer created: ID $MANUFACTURER_ID"

else
    echo "Manufacturer exists: ID $MANUFACTURER_ID"
fi

# =========================================================
# FIND / CREATE MODEL
# =========================================================

echo "Checking model: $MODEL"

MODEL_RESPONSE=$(curl -s \
    -G \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    --data-urlencode "search=$MODEL" \
    "$SNIPE_URL/api/v1/models")

MODEL_ID=$(echo "$MODEL_RESPONSE" | jq -r \
    --arg MODEL "$MODEL" \
    --argjson MID "$MANUFACTURER_ID" \
    '.rows[]?
     | select((.name | ascii_downcase) == ($MODEL | ascii_downcase))
     | select(.manufacturer.id == $MID)
     | .id' \
    | head -1)

if [ -z "$MODEL_ID" ]; then

    echo "Model not found. Creating..."

    MODEL_CREATE=$(jq -n \
        --arg name "$MODEL" \
        --argjson manufacturer_id "$MANUFACTURER_ID" \
        --argjson category_id "$CATEGORY_ID" \
        --argjson fieldset_id "$FIELDSET_ID" \
        '{
            name: $name,
            manufacturer_id: $manufacturer_id,
            category_id: $category_id,
            fieldset_id: $fieldset_id
        }')

    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "$SNIPE_URL/api/v1/models" \
        -d "$MODEL_CREATE")

    MODEL_ID=$(echo "$RESPONSE" | jq -r '.payload.id // empty')

    if [ -z "$MODEL_ID" ]; then
        echo "ERROR creating model:"
        echo "$RESPONSE" | jq
        exit 1
    fi

    echo "Model created: ID $MODEL_ID"

else
    echo "Model exists: ID $MODEL_ID"
fi

# =========================================================
# LOT
# =========================================================

echo
read -r -p "Lot ID (leave blank if none): " LOT_ID

# =========================================================
# SUMMARY
# =========================================================

echo
echo "======================================================"
echo "              EQUIPMENT INVENTORY"
echo "======================================================"
echo "Manufacturer: $MANUFACTURER"
echo "Model:        $MODEL"
echo "Category:     $CATEGORY_NAME"
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
echo "MAC:          $MAC"
echo "Lot ID:       ${LOT_ID:-None}"
echo "Model ID:     $MODEL_ID"
echo "======================================================"
echo

# =========================================================
# DUPLICATE CHECK
# =========================================================

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

    echo "Asset already exists:"
    echo "Asset ID:  $EXISTING_ID"
    echo "Asset Tag: $EXISTING_TAG"
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
# CREATE ASSET JSON
# =========================================================

ASSET_JSON=$(jq -n \
    --arg name "$MODEL" \
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
echo "Creating asset..."

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$SNIPE_URL/api/v1/hardware" \
    -d "$ASSET_JSON")

STATUS=$(echo "$RESPONSE" | jq -r '.status // empty')

if [ "$STATUS" != "success" ]; then
    echo "ERROR creating asset:"
    echo "$RESPONSE" | jq
    exit 1
fi

ASSET_TAG=$(echo "$RESPONSE" | jq -r '.payload.asset_tag')

echo
echo "======================================================"
echo "ASSET CREATED SUCCESSFULLY"
echo "Asset Tag:    $ASSET_TAG"
echo "Manufacturer: $MANUFACTURER"
echo "Model:        $MODEL"
echo "Category:     $CATEGORY_NAME"
echo "Serial:       $SERIAL"
echo "RAM:          $RAM_TOTAL"
echo "======================================================"
