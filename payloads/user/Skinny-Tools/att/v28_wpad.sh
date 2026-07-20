#!/bin/sh
# v28_wpad.sh — symlink-swap driver for the ATT-Hotspot2-Tracker.
#
# Usage:
#   v28_wpad.sh wolfssl    # swap /usr/sbin/wpad -> wpad-wolfssl + wifi reload
#   v28_wpad.sh basic      # swap /usr/sbin/wpad -> wpad-basic-mbedtls + wifi reload
#   v28_wpad.sh status     # report current symlink target + sha256
#
# This is the "alias swap" pattern: both binaries live side-by-side, and
# /usr/sbin/wpad is a symlink that we flip per-mode. hostapd.sh and PineAP
# resolve /usr/sbin/wpad at runtime, so flipping the symlink + wifi reload
# is the entire activation cost. No service-name collision, no
# update-alternatives dependency.
#
# IMPORTANT: never call this while SSH'd over wlan0cli. The wifi reload
# drops the radio for 5-15s and you will be disconnected. Use Ethernet,
# serial console, or on-Pager tmux.
#
# State assumption (per Phase-0 snapshot 2026-07-19):
#   - /usr/sbin/wpad-wolfssl       present after Phase 3 opkg install
#   - /mmc/root/wpad-basic-mbedtls.backup  present after Phase 3 opkg install
#   - /usr/sbin/wpad               symlink to one of the above

set -eu

ACTION="${1:-}"
WPAD_PATH=/usr/sbin/wpad
WPAD_DIR=/usr/sbin
WPAD_BAK=/mmc/root/wpad-basic-mbedtls.backup

log() { printf '[v28_wpad] %s\n' "$*"; }
fail() { printf '[v28_wpad] ERROR: %s\n' "$*" >&2; exit 2; }

current_link() {
    if [ -L "$WPAD_PATH" ]; then
        readlink "$WPAD_PATH"
    elif [ -f "$WPAD_PATH" ]; then
        printf '(not a symlink, raw ELF)\n'
    else
        printf '(missing)\n'
    fi
}

wolfssl_target() {
    if [ -f "$WPAD_DIR/wpad-wolfssl" ]; then
        printf '%s/wpad-wolfssl' "$WPAD_DIR"
        return 0
    fi
    return 1
}

basic_target() {
    if [ -f "$WPAD_DIR/wpad-basic-mbedtls" ]; then
        printf '%s/wpad-basic-mbedtls' "$WPAD_DIR"
        return 0
    fi
    if [ -f "$WPAD_BAK" ]; then
        printf '%s' "$WPAD_BAK"
        return 0
    fi
    return 1
}

restart_hostapd() {
    # CRITICAL: the Pineapple Go backend launches hostapd once at boot. A
    # `wifi reload` only sends a new config via ubus; it does NOT re-exec
    # the hostapd binary. So if we swapped the symlink AFTER hostapd
    # started, the running process is still the OLD binary in memory
    # and will reject any newly-supported IEs as "unknown configuration".
    # We must kill hostapd; pineapplepager / wpad.sh restart logic will
    # re-spawn it under the new symlink target.
    log "killing running hostapd so it re-execs under the new symlink..."
    local pid
    pid=$(pidof hostapd 2>/dev/null || true)
    if [ -n "$pid" ]; then
        kill -TERM $pid 2>/dev/null || true
        sleep 3
        pid=$(pidof hostapd 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill -KILL $pid 2>/dev/null || true
            sleep 1
        fi
    fi
    # Confirm new hostapd is up under the right binary
    local new_pid new_sha
    new_pid=$(pidof hostapd 2>/dev/null || true)
    if [ -n "$new_pid" ]; then
        new_sha=$(sha256sum "/proc/$new_pid/exe" 2>/dev/null | awk '{print $1}')
        log "hostapd respawned: pid=$new_pid sha256=$new_sha"
    else
        log "WARN: hostapd did not respawn; check /etc/init.d/pineapplepager"
    fi
}

do_swap() {
    local tgt="$1"
    local cur
    cur=$(current_link)
    if [ "$cur" = "$tgt" ]; then
        log "already linked to $tgt (no-op)"
        return 0
    fi
    log "swapping symlink: $cur -> $tgt"
    ln -sfn "$tgt" "$WPAD_PATH"
    log "wifi reload..."
    wifi reload >/dev/null 2>&1 || true
    sleep 3
    restart_hostapd
    "$0" status
}

case "$ACTION" in
    wolfssl)
        tgt=$(wolfssl_target) || fail "wpad-wolfssl not found at $WPAD_DIR/wpad-wolfssl (Phase 3 opkg install required)"
        do_swap "$tgt"
        ;;
    basic)
        tgt=$(basic_target) || fail "no basic wpad available: missing $WPAD_DIR/wpad-basic-mbedtls AND $WPAD_BAK"
        do_swap "$tgt"
        ;;
    status)
        printf 'v28_wpad: /usr/sbin/wpad -> %s\n' "$(current_link)"
        if [ -f "$WPAD_PATH" ]; then
            sha256sum "$WPAD_PATH" 2>/dev/null || true
            file "$WPAD_PATH" 2>/dev/null || true
        fi
        printf '\n--- candidates ---\n'
        ls -la "$WPAD_DIR"/wpad* 2>/dev/null || true
        [ -f "$WPAD_BAK" ] && ls -la "$WPAD_BAK"
        ;;
    *)
        fail "usage: $0 {wolfssl|basic|status}"
        ;;
esac
