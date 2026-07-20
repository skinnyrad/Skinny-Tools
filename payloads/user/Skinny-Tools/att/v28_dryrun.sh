#!/bin/sh
# v28_dryrun.sh — read-only sanity check for v28_run.py.
#
# Runs every UCI / bridge / firewall / dnsmasq probe the orchestrator would
# run, but in dry-run mode: it just reports what it WOULD do. No mutations.
#
# Exit codes:
#   0  -> all checks pass; orchestrator run would be safe
#   1  -> some pre-condition fails; orchestrator would refuse to run
#   2  -> critical environment problem (no wpad swap candidate, etc.)

set -u

PASS=0
FAIL=0
WARN=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }

hr() { printf '\n=== %s ===\n' "$*"; }

# 1. SSH source check (we can't reliably check from the Pager side; this
#    checks instead that the script's caller can be identified)
hr "1. SSH source / connection source"
SRC_IF=$(ip route get 172.16.52.0/24 2>/dev/null | head -1)
if echo "$SRC_IF" | grep -q "dev wlan0cli"; then
    fail "SSH source is wlan0cli — wifi reload will drop the session"
    fail "Reconnect over Ethernet or run from on-Pager tmux"
    fail "Set ATT_FORCE_WLAN0CLI=1 to override (NOT recommended)"
else
    pass "SSH source is not wlan0cli: $(echo "$SRC_IF" | head -c 80)"
fi

# 2. wpad swap candidates
hr "2. wpad swap candidates"
if [ -L /usr/sbin/wpad ]; then
    cur=$(readlink /usr/sbin/wpad)
    pass "/usr/sbin/wpad is a symlink -> $cur"
else
    warn "/usr/sbin/wpad is not a symlink ($(file /usr/sbin/wpad | cut -d: -f2))"
fi

if [ -f /usr/sbin/wpad-wolfssl ]; then
    pass "/usr/sbin/wpad-wolfssl present (sha256 $(sha256sum /usr/sbin/wpad-wolfssl | cut -d' ' -f1))"
else
    fail "/usr/sbin/wpad-wolfssl MISSING — Phase 3 opkg install needed before any pseudonym/both/hybrid mode"
fi

if [ -f /usr/sbin/wpad-basic-mbedtls ] || [ -f /mmc/root/wpad-basic-mbedtls.backup ]; then
    which_one="/usr/sbin/wpad-basic-mbedtls"
    [ ! -f "$which_one" ] && which_one="/mmc/root/wpad-basic-mbedtls.backup"
    pass "basic wpad backup present ($which_one)"
else
    fail "no basic wpad backup present — Phase 3 opkg install + backup step required"
fi

# 3. Radio state
hr "3. Radio state"
radio_mac=$(cat /sys/class/ieee80211/phy0/macaddress 2>/dev/null || echo MISSING)
if [ "$radio_mac" = "MISSING" ]; then
    fail "cannot read /sys/class/ieee80211/phy0/macaddress"
else
    first=$(echo "$radio_mac" | cut -d: -f1)
    if [ $((0x$first & 0x02)) -ne 0 ]; then
        fail "radio MAC $radio_mac is locally-administered (first octet $first); iOS will filter BSSID"
    else
        pass "radio MAC $radio_mac is universally-administered (first octet $first)"
    fi
fi

# 4. UCI check: wlan0open / wlan0wpa config
hr "4. UCI: wlan0open / wlan0wpa"
wlan0open_disabled=$(uci -q get wireless.wlan0open.disabled)
wlan0wpa_disabled=$(uci -q get wireless.wlan0wpa.disabled)
wlan0wpa_auth=$(uci -q get wireless.wlan0wpa.auth_server)
wlan0wpa_iw=$(uci -q get wireless.wlan0wpa.iw_enabled)
wlan0wpa_hs20=$(uci -q get wireless.wlan0wpa.hs20)

if [ "$wlan0open_disabled" = "0" ]; then
    pass "wlan0open is enabled in UCI"
else
    warn "wlan0open is disabled in UCI (orchestrator will enable)"
fi
if [ "$wlan0wpa_disabled" = "0" ]; then
    pass "wlan0wpa is enabled in UCI"
else
    warn "wlan0wpa is disabled in UCI (orchestrator will enable for pseudonym/both/hybrid modes)"
fi
if [ -n "$wlan0wpa_auth" ]; then
    pass "wlan0wpa auth_server is set: $wlan0wpa_auth"
else
    warn "wlan0wpa auth_server is empty (pseudonym mode will set 127.0.0.1:1812)"
fi
if [ "$wlan0wpa_iw" = "1" ]; then
    pass "wlan0wpa iw_enabled=1"
else
    warn "wlan0wpa iw_enabled is not 1 (orchestrator will set)"
fi
if [ "$wlan0wpa_hs20" = "1" ]; then
    pass "wlan0wpa hs20=1"
else
    warn "wlan0wpa hs20 is not 1 (orchestrator will set)"
fi

# 5. DNS / DHCP
hr "5. dnsmasq / odhcpd"
dnsmasq_local=$(uci -q get dhcp.@dnsmasq[0].localise_queries)
if [ "$dnsmasq_local" = "1" ]; then
    pass "dnsmasq has localise_queries=1 (bind-dynamic local-service equivalent)"
else
    warn "dnsmasq localise_queries is $dnsmasq_local (orchestrator will use address=/ override)"
fi
odhcpd_main=$(uci -q get dhcp.@odhcpd[0].maindhcp)
if [ "$odhcpd_main" = "0" ]; then
    pass "odhcpd maindhcp=0 (dnsmasq is the main DHCP server)"
else
    warn "odhcpd maindhcp=$odhcpd_main (orchestrator uses v28_dhcpd.py on 192.168.99.1)"
fi

# 6. Firewall state
hr "6. Firewall"
wan_masq=$(uci -q get firewall.@zone[1].masq)
if [ "$wan_masq" = "1" ]; then
    pass "firewall wan zone has masq=1 (NAT automatic for wlan0open/wlan0wpa members)"
else
    fail "firewall wan zone has masq='$wan_masq' — connection-mode internet bridging will fail"
fi

# 7. Bridge state
hr "7. Bridge state"
brlan_ports=$(uci -q get network.brlan.ports)
if echo "$brlan_ports" | grep -q wlan0open && echo "$brlan_ports" | grep -q wlan0wpa; then
    pass "br-lan includes wlan0open + wlan0wpa"
else
    warn "br-lan ports: $brlan_ports"
fi

# 8. v28 scripts present
hr "8. v28 deployment"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for s in v28_run.py v28_run.sh v28_wpad.sh v28_dryrun.sh v28_dhcpd.py \
         v28_ie221.py v28_wispr.py v28_isolate.sh radius-reject.py; do
    if [ -f "$SCRIPT_DIR/$s" ]; then
        pass "$s present"
    else
        fail "$s MISSING"
    fi
done

# Summary
hr "Summary"
printf '  PASS: %d   FAIL: %d   WARN: %d\n\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -gt 0 ]; then
    printf 'DRYRUN FAIL: %d blocking issue(s). Resolve before running v28_run.py.\n' "$FAIL"
    exit 1
fi
if [ "$WARN" -gt 0 ]; then
    printf 'DRYRUN OK (with %d warning(s)). Orchestrator will auto-fix warnings on entry.\n' "$WARN"
    exit 0
fi
printf 'DRYRUN OK. Ready to run.\n'
exit 0
