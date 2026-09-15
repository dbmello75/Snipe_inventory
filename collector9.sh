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
    echo "ERROR: GLPI AppImage not found:"
    echo "$GLPI_APPIMAGE"
    exit 1
fi

# =========================================================
# FUNCTIONS
# =========================================================

find_printer() {
    if [ -n "${PRINTER_DEVICE:-}" ] && [ -e "$PRINTER_DEVICE" ]; then
        echo "$PRINTER_DEVICE"
        return
    fi

    find /dev/usb -maxdepth 1 -type c -name 'lp*' 2>/dev/null \
        | sort \
        | head -1 || true
}

print_label() {

    local asset_id="$1"
    local asset_tag="$2"
    local model="$3"
    local serial="$4"

    local printer
    local qr
    local len
    local p1
    local p2

    printer=$(find_printer)

    if [ -z "$printer" ]; then
        echo
        echo "No ESC/POS USB printer detected."
        return 1
    fi

    qr="$SNIPE_URL/hardware/$asset_id"

    echo
    echo "Printer: $printer"
    echo "Printing label..."

    {
        # Reset
        printf '\x1b\x40'

        # Center
        printf '\x1b\x61\x01'

        # Asset tag - double size
        printf '\x1d\x21\x11'
        printf '%s\n' "$asset_tag"
        printf '\x1d\x21\x00'

        # Model
        printf '%s\n' "$model"

        # Serial
        printf 'SN: %s\n' "$serial"

        # Technical summary
        printf '%s / %s / %s\n\n' \
            "${CPU_SHORT:-}" \
            "${RAM_SHORT:-}" \
            "${STORAGE_SHORT:-}"

        # QR Model 2
        printf '\x1d\x28\x6b\x04\x00\x31\x41\x32\x00'

        # QR module size
        printf '\x1d\x28\x6b\x03\x00\x31\x43\x06'

        # Error correction M
        printf '\x1d\x28\x6b\x03\x00\x31\x45\x31'

        # Store QR
        len=$((${#qr} + 3))
        p1=$((len % 256))
        p2=$((len / 256))

        printf '\x1d\x28\x6b'
        printf "$(printf '\\x%02x\\x%02x' "$p1" "$p2")"
        printf '\x31\x50\x30'
        printf '%s' "$qr"

        # Print QR
        printf '\x1d\x28\x6b\x03\x00\x31\x51\x30'

        printf '\n\n\n'

    } | sudo tee "$printer" >/dev/null

    echo "Label printed successfully."
}

ask_print_label() {

    local asset_id="$1"
    local asset_tag="$2"

    echo
    read -r -p "Print label? [Y/n]: " PRINT_CONFIRM

    if [[ -z "$PRINT_CONFIRM" || "$PRINT_CONFIRM" =~ ^[Yy]$ ]]; then
        print_label \
            "$asset_id" \
            "$asset_tag" \
            "$MODEL" \
            "$SERIAL" || true
    fi
}

get_custom_field() {

    local field_name="$1"

    echo "$CURRENT" | jq -r \
        --arg FIELD "$field_name" '
        [
            (.custom_fields // {})
            | to_entries[]
            | select(.value.field == $FIELD)
            | .value.value
        ][0] // ""
    '
}

# =========================================================
# GLPI INVENTORY
# =========================================================

echo "Running GLPI Agent inventory..."

sudo "$GLPI_APPIMAGE" \
    --script=glpi-inventory \
    --json > "$INVENTORY_JSON"

if ! jq -e . "$INVENTORY_JSON" >/dev/null 2>&1; then
    echo "ERROR: Invalid GLPI inventory JSON."
    exit 1
fi

# =========================================================
# SYSTEM
# =========================================================

MANUFACTURER=$(jq -r \
    '.content.bios.smanufacturer // "Unknown"' \
    "$INVENTORY_JSON")

MODEL=$(jq -r \
    '.content.bios.smodel // "Unknown"' \
    "$INVENTORY_JSON")

SERIAL=$(jq -r \
    '.content.bios.ssn // "Unknown"' \
    "$INVENTORY_JSON")

UUID=$(jq -r \
    '.content.hardware.uuid // "Unknown"' \
    "$INVENTORY_JSON")

CHASSIS=$(jq -r \
    '.content.hardware.chassis_type // "Unknown"' \
    "$INVENTORY_JSON")

if [ "$SERIAL" = "Unknown" ] || [ -z "$SERIAL" ]; then
    echo "ERROR: No valid system serial detected."
    exit 1
fi

# =========================================================
# CPU
# =========================================================

CPU=$(jq -r '
    .content.cpus
    | map(.name)
    | unique
    | join("; ")
' "$INVENTORY_JSON")

CPU_SHORT=$(echo "$CPU" | sed -E \
    -e 's/^Intel\(R\) Core\(TM\) //' \
    -e 's/^Intel Core //' \
    -e 's/ CPU.*$//' \
    -e 's/ @.*$//' \
    -e 's/^AMD //' \
    -e 's/ [0-9]+-Core Processor.*$//' \
    -e 's/ with Radeon.*$//')

# =========================================================
# GPU
# =========================================================

GPU=$(jq -r '
    [
        .content.controllers[]?
        | select(
            .type == "VGA compatible controller"
            or .type == "3D controller"
            or .pciclass == "0300"
            or .pciclass == "0302"
        )
        | (.caption // .name // "Unknown GPU")
    ]
    | unique
    | join("; ")
' "$INVENTORY_JSON")

# =========================================================
# RAM
# =========================================================

RAM_MB=$(jq '
    [.content.memories[]?.capacity // 0]
    | add // 0
' "$INVENTORY_JSON")

RAM_TOTAL="$((RAM_MB / 1024)) GB"
RAM_SHORT="${RAM_TOTAL// /}"

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
            elif (.disksize // 0) > 0
            then (((.disksize / 1000) | floor) | tostring) + " GB"
            else "Unknown Size"
            end
        ) | " +
        "\(.interface // "Unknown")"
    ]
    | join("; ")
' "$INVENTORY_JSON")

STORAGE_SERIALS=$(jq -r '
    [
        .content.storages[]?
        | select(.type == "disk")
        | .serial
        | select(. != null and . != "" and . != "Unknown")
    ]
    | sort
    | join(";")
' "$INVENTORY_JSON")

# First internal disk capacity for label
STORAGE_SHORT=$(jq -r '
    [
        .content.storages[]?
        | select(.type == "disk")
    ][0]
    |
    if . == null then
        ""
    elif (.disksize // 0) >= 1000000 then
        (
            if ((.disksize / 1000000) | round) == 1
            then "1TB"
            else (((.disksize / 1000000) | round | tostring) + "TB")
            end
        )
    elif (.disksize // 0) > 0 then
        (((.disksize / 1000) | round | tostring) + "GB")
    else
        ""
    end
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
# CATEGORY
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
# MANUFACTURER
# =========================================================

MANUFACTURER_RESPONSE=$(curl -s \
    -G \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    --data-urlencode "search=$MANUFACTURER" \
    "$SNIPE_URL/api/v1/manufacturers")

MANUFACTURER_ID=$(echo "$MANUFACTURER_RESPONSE" | jq -r \
    --arg NAME "$MANUFACTURER" '
        .rows[]?
        | select(
            (.name | ascii_downcase)
            ==
            ($NAME | ascii_downcase)
        )
        | .id
    ' | head -1)

if [ -z "$MANUFACTURER_ID" ]; then

    echo "Creating manufacturer: $MANUFACTURER"

    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "$SNIPE_URL/api/v1/manufacturers" \
        -d "$(jq -n \
            --arg name "$MANUFACTURER" \
            '{name:$name}')")

    MANUFACTURER_ID=$(echo "$RESPONSE" | jq -r '.payload.id // empty')

    if [ -z "$MANUFACTURER_ID" ]; then
        echo "ERROR creating manufacturer:"
        echo "$RESPONSE" | jq
        exit 1
    fi
fi

# =========================================================
# MODEL
# =========================================================

MODEL_RESPONSE=$(curl -s \
    -G \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    --data-urlencode "search=$MODEL" \
    "$SNIPE_URL/api/v1/models")

MODEL_ID=$(echo "$MODEL_RESPONSE" | jq -r \
    --arg MODEL "$MODEL" \
    --argjson MID "$MANUFACTURER_ID" '
        .rows[]?
        | select(
            (.name | ascii_downcase)
            ==
            ($MODEL | ascii_downcase)
        )
        | select(.manufacturer.id == $MID)
        | .id
    ' | head -1)

if [ -z "$MODEL_ID" ]; then

    echo "Creating model: $MODEL"

    MODEL_JSON=$(jq -n \
        --arg name "$MODEL" \
        --argjson manufacturer_id "$MANUFACTURER_ID" \
        --argjson category_id "$CATEGORY_ID" \
        --argjson fieldset_id "$FIELDSET_ID" '
        {
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
        -d "$MODEL_JSON")

    MODEL_ID=$(echo "$RESPONSE" | jq -r '.payload.id // empty')

    if [ -z "$MODEL_ID" ]; then
        echo "ERROR creating model:"
        echo "$RESPONSE" | jq
        exit 1
    fi
fi

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
echo "CPU:          $CPU"
echo "CPU Label:    $CPU_SHORT"
echo "GPU:          ${GPU:-None detected}"
echo "RAM Total:    $RAM_TOTAL"

echo
echo "Memory:"
if [ -n "$MEMORY_DETAILS" ]; then
    echo "$MEMORY_DETAILS" | sed 's/^/  /'
else
    echo "  None detected"
fi

echo
echo "Storage:"
if [ -n "$STORAGE" ]; then
    echo "  $STORAGE"
else
    echo "  No internal storage detected"
fi

echo
echo "Label Summary:"
echo "  $CPU_SHORT / $RAM_SHORT / ${STORAGE_SHORT:-NO DISK}"

echo
echo "MAC:          ${MAC:-None detected}"
echo "======================================================"
echo

# =========================================================
# FIND ASSET
# =========================================================

EXISTING=$(curl -s \
    -G \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    --data-urlencode "search=$SERIAL" \
    "$SNIPE_URL/api/v1/hardware")

EXISTING_ID=$(echo "$EXISTING" | jq -r \
    --arg SERIAL "$SERIAL" '
        .rows[]?
        | select(.serial == $SERIAL)
        | .id
    ' | head -1)

# =========================================================
# NEW ASSET
# =========================================================

if [ -z "$EXISTING_ID" ]; then

    echo "New asset detected."

    read -r -p "Lot ID (leave blank if none): " LOT_ID
    read -r -p "Create asset? [y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi

    ASSET_JSON=$(jq -n \
        --arg name "$MODEL" \
        --arg serial "$SERIAL" \
        --arg cpu "$CPU" \
        --arg gpu "$GPU" \
        --arg ram "$RAM_TOTAL" \
        --arg memory "$MEMORY_DETAILS" \
        --arg storage "$STORAGE" \
        --arg uuid "$UUID" \
        --arg mac "$MAC" \
        --arg lot "$LOT_ID" \
        --argjson model_id "$MODEL_ID" \
        --argjson status_id "$STATUS_ID" '
        {
            model_id: $model_id,
            status_id: $status_id,
            name: $name,
            serial: $serial,
            "_snipeit_cpu_2": $cpu,
            "_snipeit_gpu_8": $gpu,
            "_snipeit_storage_3": $storage,
            "_snipeit_system_uuid_4": $uuid,
            "_snipeit_mac_address_1": $mac,
            "_snipeit_lot_id_5": $lot,
            "_snipeit_ram_total_6": $ram,
            "_snipeit_memory_details_7": $memory
        }')

    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "$SNIPE_URL/api/v1/hardware" \
        -d "$ASSET_JSON")

    if [ "$(echo "$RESPONSE" | jq -r '.status // empty')" != "success" ]; then
        echo "ERROR creating asset:"
        echo "$RESPONSE" | jq
        exit 1
    fi

    ASSET_ID=$(echo "$RESPONSE" | jq -r '.payload.id')
    ASSET_TAG=$(echo "$RESPONSE" | jq -r '.payload.asset_tag')

    echo
    echo "======================================================"
    echo "ASSET CREATED SUCCESSFULLY"
    echo "Asset ID:  $ASSET_ID"
    echo "Asset Tag: $ASSET_TAG"
    echo "======================================================"

    ask_print_label "$ASSET_ID" "$ASSET_TAG"

    exit 0
fi

# =========================================================
# EXISTING ASSET
# =========================================================

echo "Existing asset found: ID $EXISTING_ID"

CURRENT=$(curl -s \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    "$SNIPE_URL/api/v1/hardware/$EXISTING_ID")

ASSET_TAG=$(echo "$CURRENT" | jq -r '.asset_tag // ""')

CURRENT_CPU=$(get_custom_field "_snipeit_cpu_2")
CURRENT_GPU=$(get_custom_field "_snipeit_gpu_8")
CURRENT_RAM=$(get_custom_field "_snipeit_ram_total_6")
CURRENT_MEMORY=$(get_custom_field "_snipeit_memory_details_7")
CURRENT_STORAGE=$(get_custom_field "_snipeit_storage_3")
CURRENT_UUID=$(get_custom_field "_snipeit_system_uuid_4")
CURRENT_MAC=$(get_custom_field "_snipeit_mac_address_1")

CURRENT_STORAGE_SERIALS=$(printf '%s\n' "$CURRENT_STORAGE" \
    | grep -oE 'SN [^ |;]+' \
    | sed 's/^SN //' \
    | sort \
    | paste -sd ';' - \
    || true)

# =========================================================
# COMPARE
# =========================================================

CHANGES=0

echo
echo "======================================================"
echo "ASSET FOUND: $ASSET_TAG"
echo "CURRENT vs DETECTED HARDWARE"
echo "======================================================"

compare_field() {

    local label="$1"
    local old="$2"
    local new="$3"

    echo
    echo "$label"
    echo "  OLD: ${old:-<empty>}"
    echo "  NEW: ${new:-<empty>}"

    if [ "$old" = "$new" ]; then
        echo "  [OK]"
    else
        echo "  [CHANGED]"
        CHANGES=$((CHANGES + 1))
    fi
}

compare_field "CPU" "$CURRENT_CPU" "$CPU"
compare_field "GPU" "$CURRENT_GPU" "$GPU"
compare_field "RAM Total" "$CURRENT_RAM" "$RAM_TOTAL"
compare_field "Memory Details" "$CURRENT_MEMORY" "$MEMORY_DETAILS"
compare_field "System UUID" "$CURRENT_UUID" "$UUID"
compare_field "MAC Address" "$CURRENT_MAC" "$MAC"

echo
echo "Storage"
echo "  OLD: ${CURRENT_STORAGE:-<no storage>}"
echo "  NEW: ${STORAGE:-<no storage>}"
echo "  OLD Serial(s): ${CURRENT_STORAGE_SERIALS:-<none>}"
echo "  NEW Serial(s): ${STORAGE_SERIALS:-<none>}"

if [ "$CURRENT_STORAGE_SERIALS" = "$STORAGE_SERIALS" ]; then
    echo "  [OK - same storage serial(s)]"
else
    echo "  [CHANGED - storage serial changed]"
    CHANGES=$((CHANGES + 1))
fi

echo
echo "======================================================"

# =========================================================
# NO CHANGES
# =========================================================

if [ "$CHANGES" -eq 0 ]; then

    echo
    echo "No hardware changes detected."

    ask_print_label "$EXISTING_ID" "$ASSET_TAG"

    exit 0
fi

echo
echo "$CHANGES hardware change(s) detected."

# =========================================================
# UPDATE
# =========================================================

read -r -p "Update technical inventory? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

    echo "No changes made."

    ask_print_label "$EXISTING_ID" "$ASSET_TAG"

    exit 0
fi

UPDATE_JSON=$(jq -n \
    --arg cpu "$CPU" \
    --arg gpu "$GPU" \
    --arg ram "$RAM_TOTAL" \
    --arg memory "$MEMORY_DETAILS" \
    --arg storage "$STORAGE" \
    --arg uuid "$UUID" \
    --arg mac "$MAC" '
    {
        "_snipeit_cpu_2": $cpu,
        "_snipeit_gpu_8": $gpu,
        "_snipeit_storage_3": $storage,
        "_snipeit_system_uuid_4": $uuid,
        "_snipeit_mac_address_1": $mac,
        "_snipeit_ram_total_6": $ram,
        "_snipeit_memory_details_7": $memory
    }')

RESPONSE=$(curl -s -X PATCH \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$SNIPE_URL/api/v1/hardware/$EXISTING_ID" \
    -d "$UPDATE_JSON")

if [ "$(echo "$RESPONSE" | jq -r '.status // empty')" != "success" ]; then
    echo
    echo "ERROR updating asset:"
    echo "$RESPONSE" | jq
    exit 1
fi

echo
echo "======================================================"
echo "ASSET UPDATED SUCCESSFULLY"
echo "Asset Tag: $ASSET_TAG"
echo "Serial:    $SERIAL"
echo "Changes:   $CHANGES"
echo "======================================================"

ask_print_label "$EXISTING_ID" "$ASSET_TAG"
