#!/usr/bin/env bash
# Title: PMF-Checker
# Author: Skinny R&D
# Description: Displays PMF/MFP status and security type for a selected Recon AP
# Note: PMF is inferred from the AKM suite bits in the libwifi encryption_info
# bitmask because the recon DB does not store the RSN capability byte.
# Bit layout: hak5/libwifi src/libwifi/core/misc/security.h

# 1. Ensure an Access Point was selected from the Recon menu
if [ -z "$_RECON_SELECTED_AP_BSSID" ]; then
    LOG red "Error: No target BSSID selected from Recon menu."
    exit 1
fi

# Sanitize BSSID: Strip colons and convert to uppercase to match SQLite schema
RAW_BSSID="$_RECON_SELECTED_AP_BSSID"
TARGET_BSSID=$(echo "$RAW_BSSID" | tr -d ':' | tr 'a-z' 'A-Z')
TARGET_SSID="${_RECON_SELECTED_AP_SSID:-<Hidden>}"

LOG "Analyzing Target: $TARGET_SSID"
LOG "BSSID: $RAW_BSSID"

DB_PATH="/root/recon/recon.db"

if [ ! -f "$DB_PATH" ]; then
    LOG red "Error: Recon DB not found at $DB_PATH"
    exit 1
fi

# 2. Query the encryption bitmask for the sanitized BSSID
ENC_VAL=$(sqlite3 "$DB_PATH" "SELECT encryption FROM ssid WHERE UPPER(REPLACE(bssid, ':', '')) = '$TARGET_BSSID' ORDER BY time DESC LIMIT 1;" 2>/dev/null)

if [ -z "$ENC_VAL" ]; then
    LOG yellow "No security record found for $RAW_BSSID"
    exit 0
fi

# 2a. encryption=0 means only a probe request was captured, no beacon/probe-resp
if [ "$ENC_VAL" = "0" ]; then
    LOG yellow "No beacon captured for $RAW_BSSID — cannot determine PMF."
    exit 0
fi

# 3. Parse security protocol and PMF status from the libwifi encryption_info
#    bitmask. Done in pure bash because the Pager ships BusyBox awk, which
#    is 32-bit and silently truncates the 64-bit libwifi bitmask.
ENC=$ENC_VAL  # bash arithmetic needs a name without dashes

# Bit definitions (decimal so bash $((...)) handles them portably)
WEP=$((1 << 1))                        # 0x2
WPA2=$((1 << 3))                       # 0x8
WPA3=$((1 << 4))                       # 0x10
PW_TKIP=$((1 << 20))                   # 0x100000
PW_CCMP128=$((1 << 22))                # 0x400000
PW_GCMP128=$((1 << 26))                # 0x4000000
PW_GCMP256=$((1 << 27))                # 0x8000000
PW_CCMP256=$((1 << 28))                # 0x10000000
AKM_1X=$((1 << 33))                    # 0x200000000
AKM_PSK=$((1 << 34))                   # 0x400000000
AKM_1X_FT=$((1 << 35))                 # 0x800000000
AKM_PSK_FT=$((1 << 36))                # 0x1000000000
AKM_1X_SHA256=$((1 << 37))             # 0x2000000000
AKM_PSK_SHA256=$((1 << 39))            # 0x8000000000
AKM_SAE=$((1 << 41))                   # 0x20000000000
AKM_SAE_FT=$((1 << 42))                # 0x40000000000
AKM_OWE=$((1 << 51))                   # 0x8000000000000
AKM_PSK_SHA384=$((1 << 53))            # 0x20000000000000

# Helper: 0 if any of the listed bits are set, else 1
has_any() {
    local bit
    for bit in "$@"; do
        if (( (ENC & bit) != 0 )); then return 0; fi
    done
    return 1
}

# Helper: 0 only if every listed bit is set, else 1
has_all() {
    local bit
    for bit in "$@"; do
        if (( (ENC & bit) == 0 )); then return 1; fi
    done
    return 0
}

# Decide PMF status from AKM-suite presence
if has_any "$AKM_OWE" "$AKM_SAE" "$AKM_SAE_FT"; then
    PMF_STATUS="REQUIRED"
elif has_any "$AKM_PSK_SHA256" "$AKM_PSK_SHA384" "$AKM_1X_SHA256"; then
    PMF_STATUS="CAPABLE"
else
    PMF_STATUS="NOT INDICATED"
fi

# Pick a pairwise cipher label
if   has_any "$PW_CCMP256";              then CIPHER="CCMP256"
elif has_any "$PW_GCMP256";              then CIPHER="GCMP256"
elif has_any "$PW_GCMP128";              then CIPHER="GCMP128"
elif has_all "$PW_TKIP" "$PW_CCMP128";   then CIPHER="TKIP+CCMP128"
elif has_any "$PW_TKIP";                 then CIPHER="TKIP"
elif has_any "$PW_CCMP128";              then CIPHER="CCMP128"
else                                          CIPHER="CCMP128"
fi

# Build security-type label (priority order)
if has_any "$WEP"; then
    SEC_TYPE="WEP"
    PMF_STATUS="N/A"
elif has_any "$WPA2" "$WPA3" "$AKM_PSK" "$AKM_SAE" \
     && has_any "$WPA2" && has_any "$WPA3" && has_any "$AKM_PSK" && has_any "$AKM_SAE"; then
    SEC_TYPE="WPA2/WPA3 transition (PSK+SAE, ${CIPHER})"
elif has_any "$AKM_OWE"; then
    SEC_TYPE="OWE (${CIPHER})"
elif has_any "$WPA3" && has_any "$AKM_SAE"; then
    SEC_TYPE="WPA3-SAE (${CIPHER})"
elif has_any "$WPA3" && has_any "$AKM_SAE_FT"; then
    SEC_TYPE="WPA3-SAE-FT (${CIPHER})"
elif has_any "$WPA2" && has_any "$AKM_PSK"; then
    if   has_any "$AKM_PSK_FT";          then SEC_TYPE="WPA2-PSK-FT (${CIPHER})"
    elif has_any "$AKM_PSK_SHA256" "$AKM_PSK_SHA384"; then
                                          SEC_TYPE="WPA2-PSK (SHA256/384, ${CIPHER})"
    else                                  SEC_TYPE="WPA2-PSK (${CIPHER})"
    fi
elif has_any "$WPA2" && has_any "$AKM_1X"; then
    if   has_any "$AKM_1X_FT";           then SEC_TYPE="WPA2-Enterprise-FT (${CIPHER})"
    elif has_any "$AKM_1X_SHA256";       then SEC_TYPE="WPA2-Enterprise (SHA256, ${CIPHER})"
    else                                  SEC_TYPE="WPA2-Enterprise (1X, ${CIPHER})"
    fi
elif has_any "$WPA2"; then
    SEC_TYPE="WPA2 / Standard (${CIPHER})"
else
    SEC_TYPE="Unknown (${CIPHER})"
fi

# 4. Print results using Pager LOG helpers
LOG "Security: $SEC_TYPE"

case "$PMF_STATUS" in
    REQUIRED)
        LOG green "PMF/MFP: REQUIRED (Protected)"
        ;;
    CAPABLE)
        LOG green "PMF/MFP: CAPABLE (Protected when negotiated)"
        ;;
    "NOT INDICATED")
        LOG yellow "PMF/MFP: NOT INDICATED (likely disabled on consumer APs)"
        ;;
    "N/A")
        LOG yellow "PMF/MFP: N/A (Open Network)"
        ;;
    *)
        LOG yellow "PMF/MFP: $PMF_STATUS"
        ;;
esac
