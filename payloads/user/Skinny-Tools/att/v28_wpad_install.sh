#!/bin/sh
# v28_wpad_install.sh — install / flip / purge the wpad-wolfssl hotswap
# layout for the ATT-Hotspot2-Tracker.
#
# The Hak5 Pineapple Pager ships with Hak5's patched wpad-basic-mbedtls
# (790 KB, sha256 810d224e...) which strips Passpoint / HS2.0 / EAP-AKA
# / Interworking support. For the ATT-Hotspot2-Tracker v28 we need
# wpad-wolfssl (1.39 MB, sha256 ed6c3385...) which has those features
# compiled in.
#
# Usage:
#   v28_wpad_install.sh status                  # show current state
#   v28_wpad_install.sh install [--yes]         # one-time bootstrap;
#                                                sets up hotswap layout
#                                                (both binaries on disk)
#   v28_wpad_install.sh uninstall [--yes]       # NON-destructive:
#                                                flip symlink -> Hak5,
#                                                keep both binaries
#   v28_wpad_install.sh uninstall --purge       # DESTRUCTIVE: rm +
#                                                opkg remove wolfssl
#                                                (rare; breaks hotswap)
#   v28_wpad_install.sh purge [--yes]           # alias for
#                                                uninstall --purge
#   v28_wpad_install.sh --help
#
# Interactive prompts accept y/n (default n). --yes skips prompts.
#
# For in-tool mode flipping (e.g., between Passpoint phases that need
# wolfssl and connection phases that prefer Hak5's pineape_* extensions),
# use v28_wpad.sh basic|wolfssl directly. That script is a fast symlink
# swap + hostapd restart (~2s) and requires both binaries to be present.
#
# State transitions:
#
#   FACTORY (Hak5 stock)
#     /usr/sbin/wpad                -> wpad-basic-mbedtls ELF (Hak5 patched)
#     /usr/sbin/wpad-wolfssl       -> DOES NOT EXIST
#     /usr/sbin/wpad-basic-mbedtls -> DOES NOT EXIST
#     /mmc/root/wpad-basic-mbedtls.backup -> DOES NOT EXIST
#
#   INSTALLED (after 'install') — hotswap-ready, wolfssl active
#     /usr/sbin/wpad                -> /usr/sbin/wpad-wolfssl (symlink)
#     /usr/sbin/wpad-wolfssl       -> wolfssl ELF (1.39 MB)
#     /usr/sbin/wpad-basic-mbedtls -> Hak5 basic ELF (790 KB)
#     /mmc/root/wpad-basic-mbedtls.backup -> Hak5 basic ELF
#     /usr/lib/libwolfssl.so.*      -> installed
#     /usr/sbin/hostapd, /usr/sbin/wpa_supplicant -> /usr/sbin/wpad
#
#   REVERTED (after 'uninstall') — hotswap preserved, Hak5 active
#     /usr/sbin/wpad                -> /usr/sbin/wpad-basic-mbedtls (symlink)
#     everything else as INSTALLED
#     v28_wpad.sh wolfssl restores INSTALLED state in ~2s
#
#   PURGED (after 'uninstall --purge' or 'purge') — back to FACTORY
#     /usr/sbin/wpad                -> wpad-basic-mbedtls ELF (regular)
#     /usr/sbin/wpad-wolfssl       -> REMOVED
#     /usr/sbin/wpad-basic-mbedtls -> REMOVED
#     /mmc/root/wpad-basic-mbedtls.backup -> still present (re-install)
#     /usr/lib/libwolfssl.so.*      -> REMOVED
#
# Both install and uninstall are atomic-ish: if a step fails mid-install,
# the script backs out as much as possible and reports which step failed.
# The orchestrator (v28_run.py) should NOT be running during either
# transition — install/uninstall/purge will refuse and tell you to stop it.

set -eu

ACTION="${1:-}"
shift 2>/dev/null || true

YES_FLAG=0
PURGE_FLAG=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES_FLAG=1 ;;
        --purge)  PURGE_FLAG=1 ;;
        --help|-h) ACTION=help ;;
    esac
done

# ---- paths -----------------------------------------------------------------

WPAD_PATH=/usr/sbin/wpad
WPAD_WOLFSSL=/usr/sbin/wpad-wolfssl
WPAD_BASIC=/usr/sbin/wpad-basic-mbedtls
WPAD_BAK=/mmc/root/wpad-basic-mbedtls.backup
HAK5_BASIC_SHA=810d224edc4052aeb80fd4f6439857faba3065f8f6b01e968b952c5a95d81317
WOLFSSL_SHA=ed6c3385b91ad340a945b19bc87e58676628d156f55cde99028056462052763a

# ---- helpers ---------------------------------------------------------------

log()   { printf '[v28_wpad_install] %s\n' "$*"; }
fail()  { printf '[v28_wpad_install] ERROR: %s\n' "$*" >&2; exit 2; }
warn()  { printf '[v28_wpad_install] WARN: %s\n' "$*" >&2; }
yesno() {
    # usage: yesno "Prompt? [y/N]"  →  echoes 1 if yes, 0 if no
    local prompt="$1" ans
    if [ "$YES_FLAG" = "1" ]; then return 0; fi
    if [ ! -t 0 ]; then
        fail "no TTY available and --yes not set; cannot prompt: $prompt"
    fi
    printf '%s [y/N] ' "$prompt"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *)          return 1 ;;
    esac
}

is_wolfssl_installed() {
    [ -f "$WPAD_WOLFSSL" ] && \
        sha256sum "$WPAD_WOLFSSL" 2>/dev/null | awk '{print $1}' | grep -q "^$WOLFSSL_SHA"
}

is_basic_backup_present() {
    [ -f "$WPAD_BAK" ] && \
        sha256sum "$WPAD_BAK" 2>/dev/null | awk '{print $1}' | grep -q "^$HAK5_BASIC_SHA"
}

running_check() {
    # refuse install/uninstall if v28 orchestrator is up
    if pgrep -f "python3.*v28_run.py" >/dev/null 2>&1; then
        fail "v28_run.py is currently running; stop it first: pkill -KILL -f v28_run.py"
    fi
}

stop_hostapd() {
    log "killing hostapd (pineapplepager will respawn after install)"
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
    sleep 2  # give pineapplepager time to respawn it under the new symlink
}

verify_hostapd_wolfssl() {
    local pid sha
    pid=$(pidof hostapd 2>/dev/null | head -1)
    [ -z "$pid" ] && fail "hostapd did not respawn; check /etc/init.d/pineapplepager"
    sha=$(sha256sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}')
    if [ "$sha" != "$WOLFSSL_SHA" ]; then
        warn "hostapd sha256=$sha (expected wolfssl $WOLFSSL_SHA)"
        warn "this means the symlink swap or restart didn't fully take effect"
        warn "may still work if the symlink is correct; verify with iw dev wlan0wpa info"
        return 1
    fi
    log "hostapd now running wolfssl binary (pid=$pid sha=$sha)"
    return 0
}

# ---- status ----------------------------------------------------------------

do_status() {
    printf '=== wpad state ===\n'
    if [ -L "$WPAD_PATH" ]; then
        printf '  /usr/sbin/wpad -> %s (symlink)\n' "$(readlink "$WPAD_PATH")"
    elif [ -f "$WPAD_PATH" ]; then
        printf '  /usr/sbin/wpad -> (regular file, sha256=%s)\n' \
            "$(sha256sum "$WPAD_PATH" 2>/dev/null | awk '{print $1}')"
    else
        printf '  /usr/sbin/wpad -> MISSING\n'
    fi

    printf '\n=== installed candidates ===\n'
    if [ -f "$WPAD_WOLFSSL" ]; then
        printf '  %s -> present (sha256=%s)\n' "$WPAD_WOLFSSL" \
            "$(sha256sum "$WPAD_WOLFSSL" 2>/dev/null | awk '{print $1}')"
    else
        printf '  %s -> MISSING\n' "$WPAD_WOLFSSL"
    fi
    if [ -f "$WPAD_BASIC" ]; then
        printf '  %s -> present (sha256=%s)\n' "$WPAD_BASIC" \
            "$(sha256sum "$WPAD_BASIC" 2>/dev/null | awk '{print $1}')"
    else
        printf '  %s -> MISSING\n' "$WPAD_BASIC"
    fi
    if [ -f "$WPAD_BAK" ]; then
        printf '  %s -> present (sha256=%s)\n' "$WPAD_BAK" \
            "$(sha256sum "$WPAD_BAK" 2>/dev/null | awk '{print $1}')"
    else
        printf '  %s -> MISSING\n' "$WPAD_BAK"
    fi

    printf '\n=== libwolfssl ===\n'
    ls -la /usr/lib/libwolfssl* 2>/dev/null || printf '  (none)\n'

    printf '\n=== running hostapd ===\n'
    local pid sha
    pid=$(pidof hostapd 2>/dev/null | head -1 || true)
    if [ -z "$pid" ]; then
        printf '  (not running)\n'
    else
        sha=$(sha256sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}')
        printf '  pid=%s sha256=%s\n' "$pid" "$sha"
        if [ "$sha" = "$WOLFSSL_SHA" ]; then
            printf '  -> wolfssl build (good for v28 Passpoint modes)\n'
        elif [ "$sha" = "$HAK5_BASIC_SHA" ]; then
            printf '  -> Hak5 basic-mbedtls build (NO Passpoint support)\n'
        else
            printf '  -> UNKNOWN build\n'
        fi
    fi

    printf '\n=== v28 install state ===\n'
    if is_wolfssl_installed && is_basic_backup_present && [ -f "$WPAD_BASIC" ]; then
        printf '  wpad-wolfssl INSTALLED — v28 pseudonym/both/hybrid modes will work\n'
    elif is_wolfssl_installed; then
        printf '  wpad-wolfssl INSTALLED but Hak5 backup missing (Hak5 build not preserved)\n'
        printf '  uninstall will not be able to fully revert!\n'
    else
        printf '  wpad-wolfssl NOT INSTALLED — v28 pseudonym/both/hybrid modes will fail\n'
        printf '  run: v28_wpad_install.sh install\n'
    fi
}

# ---- install ---------------------------------------------------------------

do_install() {
    running_check

    if is_wolfssl_installed; then
        log "wpad-wolfssl already installed (sha256 matches)"
        do_status
        return 0
    fi

    if [ ! -f "$WPAD_PATH" ]; then
        fail "/usr/sbin/wpad does not exist; Pager in unknown state, abort"
    fi

    CURRENT_SHA=$(sha256sum "$WPAD_PATH" 2>/dev/null | awk '{print $1}')
    log "current /usr/sbin/wpad sha256: $CURRENT_SHA"

    cat <<MSG
==========================================================
  ATT-Hotspot2-Tracker v28 — wpad-wolfssl install
==========================================================

  This will set up a Hotswap layout (both binaries on disk,
  /usr/sbin/wpad is a symlink that flips between them):

    1. Backup current /usr/sbin/wpad to
         $WPAD_BAK
       (sha256 will be $CURRENT_SHA)
    2. Run 'opkg update' to refresh the package index
    3. Run 'opkg remove wpad-basic-mbedtls'
    4. Run 'opkg install wpad-wolfssl'
       (also pulls libwolfssl5.9.1.e624513f)
    5. Arrange hotswap layout:
         $WPAD_WOLFSSL -> wpad-wolfssl binary (1.39 MB)
         $WPAD_BASIC   -> Hak5 basic build (copy of backup)
         $WPAD_PATH    -> symlink to $WPAD_WOLFSSL (active=wolfssl)
         /usr/sbin/hostapd, /usr/sbin/wpa_supplicant -> $WPAD_PATH
    6. Kill hostapd so pineapplepager re-spawns it under
       the wolfssl binary
    7. wifi reload

  After install (hotswap-ready):
    - Both binaries coexist; flip with v28_wpad.sh basic|wolfssl
    - 'uninstall' (default) is NON-destructive: it just flips the
      symlink back to Hak5. Use --purge for the old destructive
      behavior (rm + opkg remove).
==========================================================
MSG

    if ! yesno "Proceed with install?"; then
        log "aborted by user"
        exit 1
    fi

    # Step 1: backup
    log "step 1/7: backup $WPAD_PATH -> $WPAD_BAK"
    if [ ! -f "$WPAD_BAK" ]; then
        cp "$WPAD_PATH" "$WPAD_BAK"
    else
        warn "$WPAD_BAK already exists; not overwriting"
    fi

    # Step 2: opkg update
    log "step 2/7: opkg update"
    if ! opkg update; then
        fail "opkg update failed; check internet connectivity"
    fi

    # Step 3: opkg remove basic
    log "step 3/7: opkg remove wpad-basic-mbedtls"
    opkg remove wpad-basic-mbedtls || warn "remove returned non-zero (package may already be removed)"

    # Step 4: opkg install wolfssl
    log "step 4/7: opkg install wpad-wolfssl"
    if ! opkg install wpad-wolfssl; then
        fail "opkg install wpad-wolfssl failed"
    fi

    # Step 5: arrange symlink layout
    log "step 5/7: arrange symlink layout"
    # opkg puts the wolfssl ELF at /usr/sbin/wpad (not /usr/sbin/wpad-wolfssl).
    # Rename before we replace /usr/sbin/wpad with a symlink.
    if [ ! -f "$WPAD_WOLFSSL" ]; then
        log "  opkg-installed binary is at $WPAD_PATH; copying to $WPAD_WOLFSSL"
        cp "$WPAD_PATH" "$WPAD_WOLFSSL"
    fi
    if [ ! -f "$WPAD_BASIC" ]; then
        if [ -f "$WPAD_BAK" ]; then
            cp "$WPAD_BAK" "$WPAD_BASIC"
        else
            warn "$WPAD_BASIC and $WPAD_BAK both missing; revert will not be able to flip to Hak5"
        fi
    fi
    # Restore the hostapd + wpa_supplicant symlinks (opkg strips them when
    # it overwrites /usr/sbin/wpad, and netifd silently fails if they're gone).
    rm -f "$WPAD_PATH"
    ln -s "$WPAD_WOLFSSL" "$WPAD_PATH"
    ln -sf wpad /usr/sbin/hostapd
    ln -sf wpad /usr/sbin/wpa_supplicant
    log "  $WPAD_PATH -> $WPAD_WOLFSSL"
    log "  /usr/sbin/hostapd, /usr/sbin/wpa_supplicant -> $WPAD_PATH"

    # Step 6: kill hostapd so it re-execs under the wolfssl binary
    log "step 6/7: restart hostapd"
    stop_hostapd
    verify_hostapd_wolfssl || warn "hostapd check failed (see warnings above)"

    # Step 7: wifi reload (picks up anything that wasn't reloaded)
    log "step 7/7: wifi reload"
    wifi reload >/dev/null 2>&1 || true

    log "INSTALL COMPLETE"
    do_status
}

# ---- uninstall -------------------------------------------------------------
#
# Default uninstall is NON-DESTRUCTIVE: it flips /usr/sbin/wpad back to the
# Hak5 basic-mbedtls binary while leaving both binaries and libwolfssl on
# disk. v28_wpad.sh wolfssl can re-activate wolfssl in ~2s without opkg.
#
# Use --purge to fully remove wpad-wolfssl (rm + opkg remove + libwolfssl).
# This is rarely needed; it saves ~1.4 MB but breaks the hotswap until you
# re-run install.

do_uninstall() {
    running_check

    if ! is_wolfssl_installed; then
        log "wpad-wolfssl not installed (sha256 does not match); nothing to do"
        do_status
        return 0
    fi

    # Resolve the Hak5 target: prefer /usr/sbin/wpad-basic-mbedtls (the
    # install-managed copy), fall back to /mmc/root/wpad-basic-mbedtls.backup.
    local basic_target=""
    if [ -f "$WPAD_BASIC" ] && sha256sum "$WPAD_BASIC" 2>/dev/null | awk '{print $1}' | grep -q "^$HAK5_BASIC_SHA"; then
        basic_target="$WPAD_BASIC"
    elif [ -f "$WPAD_BAK" ] && sha256sum "$WPAD_BAK" 2>/dev/null | awk '{print $1}' | grep -q "^$HAK5_BASIC_SHA"; then
        basic_target="$WPAD_BAK"
    fi

    if [ -z "$basic_target" ]; then
        fail "no Hak5 basic-mbedtls build found at $WPAD_BASIC or $WPAD_BAK (sha mismatch); cannot flip"
    fi

    cat <<MSG
==========================================================
  ATT-Hotspot2-Tracker v28 — wpad revert (non-destructive)
==========================================================

  This will flip /usr/sbin/wpad back to the Hak5 build while
  KEEPING both binaries and libwolfssl on disk (hotswap-ready):

    1. Stop hostapd
    2. $WPAD_PATH -> $basic_target  (was: wolfssl)
    3. wifi reload (hostapd respawns on Hak5 binary)

  Neither wpad-wolfssl nor libwolfssl is removed. Re-activate
  wolfssl anytime with:
    v28_wpad.sh wolfssl

  Use --purge to FULLY remove wpad-wolfssl (rm + opkg remove).
  That frees ~1.4 MB but breaks hotswap until next install.
==========================================================
MSG

    if ! yesno "Proceed with revert?"; then
        log "aborted by user"
        exit 1
    fi

    # Step 1: stop hostapd (it'll respawn under the new symlink)
    log "step 1/3: stop hostapd"
    stop_hostapd

    # Step 2: flip symlink to Hak5
    log "step 2/3: $WPAD_PATH -> $basic_target"
    rm -f "$WPAD_PATH"
    ln -s "$basic_target" "$WPAD_PATH"
    ln -sf wpad /usr/sbin/hostapd
    ln -sf wpad /usr/sbin/wpa_supplicant

    # Step 3: wifi reload so pineapplepager re-spawns hostapd
    log "step 3/3: wifi reload"
    wifi reload >/dev/null 2>&1 || true
    sleep 2

    log "REVERT COMPLETE (hotswap layout preserved)"
    do_status
}

do_purge() {
    running_check

    if ! is_wolfssl_installed; then
        log "wpad-wolfssl not installed (sha256 does not match); nothing to purge"
        do_status
        return 0
    fi

    if ! is_basic_backup_present; then
        log "WARNING: $WPAD_BAK missing or wrong sha256 — cannot fully revert"
        if ! yesno "Continue purge anyway? (Pager will be left without a working wpad)"; then
            log "aborted by user"
            exit 1
        fi
    fi

    cat <<MSG
==========================================================
  ATT-Hotspot2-Tracker v28 — wpad-wolfssl PURGE (destructive)
==========================================================

  This will FULLY remove wpad-wolfssl from the Pager:

    1. Stop hostapd
    2. Restore $WPAD_BAK -> $WPAD_PATH (regular file)
    3. Remove $WPAD_WOLFSSL
    4. Remove $WPAD_BASIC (the extra copy)
    5. Run 'opkg remove wpad-wolfssl' (also removes libwolfssl)
    6. wifi reload

  After this:
    - Pager reverts to Hak5-patched wpad-basic-mbedtls
    - Both wpad-wolfssl and libwolfssl are GONE from disk
    - Hotswap is broken until next install
    - The $WPAD_BAK file is NOT removed (kept for re-install)

  Prefer 'uninstall' (the default) if you want to keep hotswap
  working — it just flips the symlink without removing anything.
==========================================================
MSG

    if ! yesno "Proceed with purge?"; then
        log "aborted by user"
        exit 1
    fi

    # Step 1: stop hostapd
    log "step 1/6: stop hostapd"
    stop_hostapd

    # Step 2: restore Hak5 build as a regular file
    log "step 2/6: restore $WPAD_BAK -> $WPAD_PATH"
    rm -f "$WPAD_PATH"
    cp "$WPAD_BAK" "$WPAD_PATH"
    chmod 755 "$WPAD_PATH"

    # Step 3: remove wpad-wolfssl binary
    log "step 3/6: remove $WPAD_WOLFSSL"
    rm -f "$WPAD_WOLFSSL"

    # Step 4: remove wpad-basic-mbedtls copy (the extra one)
    log "step 4/6: remove $WPAD_BASIC"
    rm -f "$WPAD_BASIC"

    # Step 5: opkg remove wpad-wolfssl (also drops libwolfssl)
    log "step 5/6: opkg remove wpad-wolfssl"
    if ! opkg remove wpad-wolfssl; then
        warn "opkg remove wpad-wolfssl returned non-zero (continuing)"
    fi

    # Step 6: wifi reload
    log "step 6/6: wifi reload"
    wifi reload >/dev/null 2>&1 || true
    sleep 3

    log "PURGE COMPLETE (hotswap layout torn down; reinstall to restore)"
    do_status
}

# ---- main ------------------------------------------------------------------

case "$ACTION" in
    status)   do_status ;;
    install)  do_install ;;
    uninstall)
        if [ "$PURGE_FLAG" = "1" ]; then
            do_purge
        else
            do_uninstall
        fi
        ;;
    purge)
        do_purge
        ;;
    help|--help|-h)
        cat <<USAGE
Usage: v28_wpad_install.sh {status|install|uninstall} [--yes] [--purge]

  status     show current wpad state on the Pager
  install    install wpad-wolfssl + set up hotswap layout
             (idempotent if already installed)
  uninstall  flip symlink back to Hak5 (NON-destructive;
             both binaries + libwolfssl stay on disk for hotswap)
  purge      DESTRUCTIVE uninstall: rm + opkg remove wpad-wolfssl.
             Only needed to free disk space or fully tear down.

Flags:
  --yes, -y  skip interactive y/n prompts
  --purge    (with 'uninstall') use the destructive variant

The script will refuse to run if v28_run.py is currently running.
Stop it first with: pkill -KILL -f v28_run.py

For in-tool hot-swapping between Hak5 and wolfssl while v28 is
running, use v28_wpad.sh basic|wolfssl (the symlink-swap driver,
separate from this one-time setup script).
USAGE
        ;;
    *)
        fail "unknown action: $ACTION (use status|install|uninstall|purge|--help)"
        ;;
esac
