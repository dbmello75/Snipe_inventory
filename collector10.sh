#!/bin/bash

set -u
set -o pipefail

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
# HELPERS
# =========================================================

safe_value() {
    local value="${1:-}"

    if [ -z "$value" ] || [ "$value" = "null" ] || [ "$value" = "Unknown" ]; then
        echo "N/A"
    else
        echo "$value"
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
    ' 2>/dev/null
}

api_get() {
    curl -sS \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        "$1"
}

# =========================================================
# REQUIREMENTS
# =========================================================

for CMD in jq curl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is required."
        exit 1
    fi
done

if [ ! -x "$GLPI_APPIMAGE" ]; then
    echo "ERROR: GLPI AppImage not found:"
    echo "$GLPI_APPIMAGE"
    exit 1
fi

# =========================================================
# GLPI INVENTORY
# =========================================================

echo "Running GLPI Agent inventory..."

if ! sudo "$GLPI_APPIMAGE" \
    --script=glpi-inventory \
    --json > "$INVENTORY_JSON"; then

    echo "ERROR: GLPI Agent execution failed."
    exit 1
fi

if ! jq -e . "$INVENTORY_JSON" >/dev/null 2>&1; then
    echo "ERROR: Invalid GLPI inventory JSON."
    exit 1
fi

# =========================================================
# BASIC SYSTEM INFO
# =========================================================

MANUFACTURER=$(jq -r '.content.bios.smanufacturer // empty' "$INVENTORY_JSON")
MODEL=$(jq -r '.content.bios.smodel // empty' "$INVENTORY_JSON")
SERIAL=$(jq -r '.content.bios.ssn // empty' "$INVENTORY_JSON")
UUID=$(jq -r '.content.hardware.uuid // empty' "$INVENTORY_JSON")
CHASSIS=$(jq -r '.content.hardware.chassis_type // empty' "$INVENTORY_JSON")

MANUFACTURER=$(safe_value "$MANUFACTURER")
MODEL=$(safe_value "$MODEL")
SERIAL=$(safe_value "$SERIAL")
UUID=$(safe_value "$UUID")
CHASSIS=$(safe_value "$CHASSIS")

# =========================================================
# CPU
# =========================================================

CPU=$(jq -r '
    [
        .content.cpus[]?.name
        | select(. != null and . != "")
    ]
    | unique
    | join("; ")
' "$INVENTORY_JSON" 2>/dev/null)

CPU=$(safe_value "$CPU")

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
        | (.caption // .name // empty)
        | select(. != "")
    ]
    | unique
    | join("; ")
' "$INVENTORY_JSON" 2>/dev/null)

GPU=$(safe_value "$GPU")

# =========================================================
# MEMORY
# =========================================================

RAM_MB=$(jq '
    [
        .content.memories[]?.capacity
        | select(. != null)
    ]
    | add // 0
' "$INVENTORY_JSON" 2>/dev/null)

if [ -n "$RAM_MB" ] && [ "$RAM_MB" -gt 0 ] 2>/dev/null; then
    RAM_TOTAL="$((RAM_MB / 1024)) GB"
else
    RAM_TOTAL="N/A"
fi

MEMORY_DETAILS=$(jq -r '
    .content.memories[]?
    |
    "\(.caption // "N/A") | " +
    "\(
        if (.capacity // 0) > 0
        then (((.capacity / 1024) | floor | tostring) + " GB")
        else "N/A"
        end
    ) + " | " +
    "\(.type // "N/A") | " +
    "\(.speed // "N/A") MT/s | " +
    "\(.manufacturer // "N/A") | " +
    "SN \(.serialnumber // "N/A") | " +
    "PN \(.model // "N/A")"
' "$INVENTORY_JSON" 2>/dev/null)

if [ -z "$MEMORY_DETAILS" ]; then
    MEMORY_DETAILS="None"
fi

# =========================================================
# STORAGE
# =========================================================

STORAGE=$(jq -r '
    [
        .content.storages[]?
        | select(.type == "disk")
        |
        "\(.model // "N/A") | " +
        "SN \(.serial // "N/A") | " +
        "\(
            if (.disksize // 0) >= 1000000
            then (((.disksize / 1000000) * 10 | floor) / 10 | tostring) + " TB"
            elif (.disksize // 0) > 0
            then (((.disksize / 1000) | floor) | tostring) + " GB"
            else "N/A"
            end
        ) | " +
        "\(.interface // "N/A")"
    ]
    | join("; ")
' "$INVENTORY_JSON" 2>/dev/null)

if [ -z "$STORAGE" ]; then
    STORAGE="None"
fi

STORAGE_SERIALS=$(jq -r '
    [
        .content.storages[]?
        | select(.type == "disk")
        | .serial
        | select(. != null and . != "" and . != "Unknown")
    ]
    | sort
    | join(";")
' "$INVENTORY_JSON" 2>/dev/null)

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
            | select(. != null and . != "")
        ][0]
    ) //
    (
        [
            .content.networks[]?
            | select(.virtualdev == false)
            | select(.type == "wifi")
            | .mac
            | select(. != null and . != "")
        ][0]
    ) //
    ""
' "$INVENTORY_JSON" 2>/dev/null)

MAC=$(safe_value "$MAC")

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
        CATEGORY_ID=$CATEGORY_DESKTOP
        CATEGORY_NAME="Desktop"
        ;;
esac

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
echo "GPU:          $GPU"
echo "RAM Total:    $RAM_TOTAL"

echo
echo "Memory:"
echo "$MEMORY_DETAILS" | sed 's/^/  /'

echo
echo "Storage:"
echo "  $STORAGE"

echo
echo "MAC:          $MAC"
echo "======================================================"
echo

# =========================================================
# IDENTIFICATION STRATEGY
# =========================================================

IDENT_TYPE="none"
IDENT_VALUE=""

if [ "$SERIAL" != "N/A" ]; then
    IDENT_TYPE="serial"
    IDENT_VALUE="$SERIAL"
elif [ "$UUID" != "N/A" ]; then
    IDENT_TYPE="uuid"
    IDENT_VALUE="$UUID"
elif [ "$MAC" != "N/A" ]; then
    IDENT_TYPE="mac"
    IDENT_VALUE="$MAC"
fi

echo "Identification method: $IDENT_TYPE"
echo

# =========================================================
# FIND EXISTING ASSET
# =========================================================

EXISTING_ID=""

if [ "$IDENT_TYPE" = "serial" ]; then

    EXISTING=$(curl -sS \
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

elif [ "$IDENT_TYPE" = "uuid" ]; then

    EXISTING=$(curl -sS \
        -G \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        --data-urlencode "search=$UUID" \
        "$SNIPE_URL/api/v1/hardware")

    EXISTING_ID=$(echo "$EXISTING" | jq -r \
        --arg UUID "$UUID" '
        .rows[]?
        | select(
            [
                (.custom_fields // {})
                | to_entries[]
                | select(.value.field == "_snipeit_system_uuid_4")
                | .value.value
            ][0] == $UUID
        )
        | .id
    ' | head -1)

elif [ "$IDENT_TYPE" = "mac" ]; then

    EXISTING=$(curl -sS \
        -G \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        --data-urlencode "search=$MAC" \
        "$SNIPE_URL/api/v1/hardware")

    EXISTING_ID=$(echo "$EXISTING" | jq -r \
        --arg MAC "$MAC" '
        .rows[]?
        | select(
            [
                (.custom_fields // {})
                | to_entries[]
                | select(.value.field == "_snipeit_mac_address_1")
                | .value.value
            ][0] == $MAC
        )
        | .id
    ' | head -1)
fi

# =========================================================
# MANUFACTURER
# =========================================================

if [ "$MANUFACTURER" != "N/A" ]; then

    MANUFACTURER_RESPONSE=$(curl -sS \
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

        RESPONSE=$(curl -sS -X POST \
            -H "Authorization: Bearer $SNIPE_TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            "$SNIPE_URL/api/v1/manufacturers" \
            -d "$(jq -n \
                --arg name "$MANUFACTURER" \
                '{name:$name}')")

        MANUFACTURER_ID=$(echo "$RESPONSE" | jq -r '.payload.id // empty')
    fi

else
    MANUFACTURER_ID=""
fi

# =========================================================
# MODEL
# =========================================================

MODEL_ID=""

if [ "$MODEL" != "N/A" ] && [ -n "$MANUFACTURER_ID" ]; then

    MODEL_RESPONSE=$(curl -sS \
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

        RESPONSE=$(curl -sS -X POST \
            -H "Authorization: Bearer $SNIPE_TOKEN" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            "$SNIPE_URL/api/v1/models" \
            -d "$MODEL_JSON")

        MODEL_ID=$(echo "$RESPONSE" | jq -r '.payload.id // empty')
    fi
fi

# =========================================================
# EXISTING ASSET
# =========================================================

if [ -n "$EXISTING_ID" ]; then

    echo "Existing asset found: ID $EXISTING_ID"

    CURRENT=$(api_get "$SNIPE_URL/api/v1/hardware/$EXISTING_ID")

    ASSET_TAG=$(echo "$CURRENT" | jq -r '.asset_tag // "N/A"')

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
    echo "  OLD: ${CURRENT_STORAGE:-None}"
    echo "  NEW: ${STORAGE:-None}"
    echo "  OLD Serial(s): ${CURRENT_STORAGE_SERIALS:-<none>}"
    echo "  NEW Serial(s): ${STORAGE_SERIALS:-<none>}"

    if [ "$CURRENT_STORAGE_SERIALS" = "$STORAGE_SERIALS" ]; then
        echo "  [OK]"
    else
        echo "  [CHANGED]"
        CHANGES=$((CHANGES + 1))
    fi

    echo
    echo "======================================================"

    if [ "$CHANGES" -eq 0 ]; then
        echo "No hardware changes detected."
        exit 0
    fi

    echo "$CHANGES hardware change(s) detected."

    read -r -p "Update technical inventory? [y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "No changes made."
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

    RESPONSE=$(curl -sS -X PATCH \
        -H "Authorization: Bearer $SNIPE_TOKEN" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        "$SNIPE_URL/api/v1/hardware/$EXISTING_ID" \
        -d "$UPDATE_JSON")

    if [ "$(echo "$RESPONSE" | jq -r '.status // empty')" = "success" ]; then
        echo
        echo "ASSET UPDATED SUCCESSFULLY"
    else
        echo
        echo "ERROR updating asset:"
        echo "$RESPONSE" | jq
        exit 1
    fi

    exit 0
fi

# =========================================================
# NEW ASSET
# =========================================================

if [ -z "$MODEL_ID" ]; then
    echo
    echo "WARNING: Could not determine/create a valid model."
    echo "Asset will not be created automatically."
    exit 0
fi

echo "New asset detected."

read -r -p "Lot ID (leave blank if none): " LOT_ID
read -r -p "Create asset? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

CREATE_SERIAL="$SERIAL"

if [ "$CREATE_SERIAL" = "N/A" ]; then
    CREATE_SERIAL=""
fi

ASSET_JSON=$(jq -n \
    --arg name "$MODEL" \
    --arg serial "$CREATE_SERIAL" \
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

RESPONSE=$(curl -sS -X POST \
    -H "Authorization: Bearer $SNIPE_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$SNIPE_URL/api/v1/hardware" \
    -d "$ASSET_JSON")

if [ "$(echo "$RESPONSE" | jq -r '.status // empty')" = "success" ]; then

    echo
    echo "======================================================"
    echo "ASSET CREATED SUCCESSFULLY"
    echo "Asset ID:  $(echo "$RESPONSE" | jq -r '.payload.id')"
    echo "Asset Tag: $(echo "$RESPONSE" | jq -r '.payload.asset_tag')"
    echo "======================================================"

else

    echo
    echo "ERROR creating asset:"
    echo "$RESPONSE" | jq
    exit 1
fi
