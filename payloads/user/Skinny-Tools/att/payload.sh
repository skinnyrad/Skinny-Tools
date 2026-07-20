#!/bin/sh
# Title: ATT-Hotspot2-Tracker
# Description: Single entry point for the v28 Passpoint/HS2.0 IMSI-pseudonym
#              capture tool. Pick a mode (pseudonym / connection / both /
#              hybrid) and this script handles the pre-flight (install
#              wpad-wolfssl if needed, flip /usr/sbin/wpad to the right
#              binary, configure wireless) and launches v28_run.py. Status,
#              swap, revert, and other subcommands are also available.
# Version: 2
# Author: Jeff Benson (erg0Proxy) - Skinny R&D
#
# Usage:
#   payload.sh                       interactive mode menu
#   payload.sh <pseudonym|connection|both|hybrid>
#                                   pre-flight + run that mode
#   payload.sh status                show wpad + process state
#   payload.sh setup                 one-time install wpad-wolfssl (hotswap)
#   payload.sh swap <wolfssl|basic>  manual symlink flip
#   payload.sh revert                flip wpad back to Hak5 (preserves hotswap)
#   payload.sh stop                  kill orchestrator + helpers
#   payload.sh dryrun                env sanity check (no changes)
#   payload.sh uninstall             DESTRUCTIVE: rm + opkg remove wpad-wolfssl
#   payload.sh help                  this message
#
# Companion scripts (called via this entry point — don't run directly):
#   v28_run.py         orchestrator (pseudonym/connection/both/hybrid modes)
#   v28_wpad_install.sh  install/uninstall/purge the wpad-wolfssl hotswap layout
#   v28_wpad.sh        in-tool wpad hotswap driver (basic|wolfssl)
#   v28_dryrun.sh      read-only env sanity check
#   v28_run.sh         exec wrapper for v28_run.py
#   v28_dhcpd.py       DHCP server for br-att (192.168.99.0/24)
#   v28_ie221.py       IE-221 OUI injector (connection mode)
#   v28_wispr.py       stdlib WISPr HTTP server
#   v28_isolate.sh     bridge create/destroy for br-att
#   v28_nat.sh         UCI firewall zone + forwarding
#   radius-reject.py   stdlib RADIUS server
#
# Mode pre-flight logic:
#   - pseudonym / both / hybrid  need wpad-wolfssl:
#       if /usr/sbin/wpad-wolfssl missing -> run `setup`
#       if /usr/sbin/wpad not pointing at wpad-wolfssl -> `swap wolfssl`
#   - connection  prefers Hak5 basic-mbedtls (for pineape_* extensions):
#       if /usr/sbin/wpad not pointing at wpad-basic-mbedtls -> `swap basic`

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Log file (Pager UI hides stdout, so we log everything here for inspection)
LOG_DIR="/mmc/root/loot/v28"
LOG_FILE="$LOG_DIR/payload.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

log()   { printf '[att] %s\n' "$*"; printf '[%s] [att] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE" 2>/dev/null; }
err()   { printf '[att] ERROR: %s\n' "$*" >&2; printf '[%s] [att] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE" 2>/dev/null; }
log_only() { printf '[%s] [att] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE" 2>/dev/null; }

# ---------------------------------------------------------------------------
# subcommand handlers
# ---------------------------------------------------------------------------

cmd_status() {
    "$SCRIPT_DIR/v28_wpad_install.sh" status
    echo
    if pgrep -f 'v28_run\.py' >/dev/null 2>&1; then
        log "orchestrator RUNNING:"
        pgrep -fa 'v28_run\.py|radius-reject\.py|v28_dhcpd\.py|v28_wispr\.py|v28_ie221\.py' 2>&1
    else
        log "orchestrator not running"
    fi
}

cmd_setup() {
    if [ ! -t 0 ] && ! printf '%s\n' "$*" | grep -q -- '--yes'; then
        set -- --yes "$@"
    fi
    "$SCRIPT_DIR/v28_wpad_install.sh" install "$@"
}

cmd_revert() {
    if [ ! -t 0 ] && ! printf '%s\n' "$*" | grep -q -- '--yes'; then
        set -- --yes "$@"
    fi
    "$SCRIPT_DIR/v28_wpad_install.sh" uninstall "$@"
}

cmd_uninstall() {
    if [ ! -t 0 ] && ! printf '%s\n' "$*" | grep -q -- '--yes'; then
        set -- --yes "$@"
    fi
    "$SCRIPT_DIR/v28_wpad_install.sh" uninstall --purge "$@"
}

cmd_dryrun() {
    "$SCRIPT_DIR/v28_dryrun.sh"
}

cmd_stop() {
    log "killing orchestrator + helpers..."
    for p in v28_run.py radius-reject.py v28_dhcpd.py v28_wispr.py v28_ie221.py; do
        pid=$(pgrep -f "$p" 2>/dev/null) || continue
        [ -n "$pid" ] && kill -KILL $pid 2>/dev/null
    done
    sleep 1
    leftover=$(pgrep -fa 'v28_run\.py|radius-reject\.py|v28_dhcpd\.py|v28_wispr\.py|v28_ie221\.py' 2>/dev/null)
    if [ -z "$leftover" ]; then
        log "stopped (no v28 processes left)"
    else
        log "WARN: still running:"
        echo "$leftover"
    fi
    # Manual kill -KILL skips the orchestrator's cleanup() which would have
    # flipped wpad back to Hak5. Do it ourselves.
    if [ -L /usr/sbin/wpad ] && [ "$(readlink /usr/sbin/wpad)" = "wpad-wolfssl" ]; then
        log "flipping wpad back to Hak5 (orchestrator cleanup was skipped)"
        "$SCRIPT_DIR/v28_wpad.sh" basic >/dev/null 2>&1
    fi
}

cmd_swap() {
    case "${1:-}" in
        wolfssl|basic|b|w)
            "$SCRIPT_DIR/v28_wpad.sh" "$1"
            ;;
        *)
            err "usage: payload.sh swap <wolfssl|basic>"
            return 1
            ;;
    esac
}

cmd_help() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    echo
    cat <<'USAGE'

Files in this folder (don't run these directly — go through payload.sh):
  payload.sh         this entry point
  v28_run.py         orchestrator
  v28_wpad_install.sh  one-time wpad install / uninstall / purge
  v28_wpad.sh        in-tool wpad hotswap driver
  v28_run.sh         exec wrapper for v28_run.py
  v28_dryrun.sh      read-only env sanity check
  v28_dhcpd.py       DHCP server for br-att
  v28_ie221.py       IE-221 OUI injector
  v28_wispr.py       stdlib WISPr HTTP server
  v28_isolate.sh     bridge create/destroy for br-att
  v28_nat.sh         UCI firewall zone + forwarding
  radius-reject.py   stdlib RADIUS server
  README.md          design + theory + troubleshooting

Default state on a Hak5 Pager that has run `setup`:
  /usr/sbin/wpad              -> symlink to wpad-basic-mbedtls (Hak5)
  /usr/sbin/wpad-basic-mbedtls = Hak5 ELF (790 KB, sha 810d224e)
  /usr/sbin/wpad-wolfssl       = wolfssl ELF (1.39 MB, sha ed6c3385)
USAGE
}

# ---------------------------------------------------------------------------
# pre-flight + run a mode
# ---------------------------------------------------------------------------

wpad_target() {
    # Echoes the symlink target of /usr/sbin/wpad if it's a symlink, else
    # the empty string. Used to detect "is wpad currently wolfssl?".
    if [ -L /usr/sbin/wpad ]; then
        readlink /usr/sbin/wpad
    else
        printf ''
    fi
}

preflight_for_mode() {
    mode="$1"
    case "$mode" in
        pseudonym|both|hybrid)
            # Need wpad-wolfssl
            if [ ! -f /usr/sbin/wpad-wolfssl ]; then
                log "wpad-wolfssl not installed; running setup..."
                cmd_setup || { err "setup failed"; return 1; }
            fi
            if [ "$(wpad_target)" != "wpad-wolfssl" ]; then
                log "flipping wpad -> wpad-wolfssl"
                cmd_swap wolfssl >/dev/null 2>&1 || { err "swap to wolfssl failed"; return 1; }
            fi
            ;;
        connection)
            # Prefer Hak5 basic-mbedtls (for pineape_* extensions per v28_wpad.sh comments)
            if [ "$(wpad_target)" != "wpad-basic-mbedtls" ]; then
                log "flipping wpad -> wpad-basic-mbedtls (Hak5)"
                cmd_swap basic >/dev/null 2>&1 || { err "swap to basic failed"; return 1; }
            fi
            ;;
        *)
            err "unknown mode: $mode (expected: pseudonym|connection|both|hybrid)"
            return 1
            ;;
    esac
    return 0
}

run_mode() {
    mode="$1"
    shift
    log "starting v28_run.py --mode $mode $*"
    "$SCRIPT_DIR/v28_run.sh" --mode "$mode" "$@"
    rc=$?
    log "v28_run.py exited (rc=$rc)"
    return $rc
}

# ---------------------------------------------------------------------------
# interactive menu
# ---------------------------------------------------------------------------

show_menu() {
    printf '\n'
    printf '============================================================\n'
    printf '  ATT-Hotspot2-Tracker v28\n'
    printf '============================================================\n'
    printf '\n'
    printf '  wpad: '
    if [ -L /usr/sbin/wpad ]; then
        printf '/usr/sbin/wpad -> %s\n' "$(readlink /usr/sbin/wpad)"
    elif [ -f /usr/sbin/wpad ]; then
        printf '/usr/sbin/wpad (sha %s...)\n' \
            "$(sha256sum /usr/sbin/wpad 2>/dev/null | awk '{print substr($1,1,12)}')"
    else
        printf 'MISSING\n'
    fi
    if pgrep -f 'v28_run\.py' >/dev/null 2>&1; then
        printf '  orchestrator: RUNNING\n'
    else
        printf '  orchestrator: stopped\n'
    fi
    printf '\n'
    printf '  --- pick a mode (auto-pre-flight: install wolfssl, flip wpad) ---\n'
    printf '\n'
    printf '    1) pseudonym    Passpoint EAP-AKA'\'' on wlan0wpa (needs wolfssl)\n'
    printf '    2) connection   Open AP wlan0open + WISPr captive portal\n'
    printf '    3) both         pseudonym -> swap -> connection (sequenced)\n'
    printf '    4) hybrid       both BSSs up simultaneously\n'
    printf '\n'
    printf '  --- maintenance ---\n'
    printf '\n'
    printf '    5) status       show full wpad + process state\n'
    printf '    6) swap         flip wpad wolfssl<->Hak5 manually\n'
    printf '    7) revert       flip wpad -> Hak5 + stop orchestrator\n'
    printf '    8) setup        one-time install wpad-wolfssl (no run)\n'
    printf '    9) stop         kill orchestrator + helpers\n'
    printf '   10) dryrun       env sanity check\n'
    printf '   11) uninstall    DESTRUCTIVE: rm + opkg remove wpad-wolfssl\n'
    printf '   12) help\n'
    printf '    q) quit\n'
    printf '\n'
    printf '  select [1-12/q]: '
}

pick_mode() {
    # If stdin isn't usable for input (Pager UI click — the LCD menu doesn't
    # pipe stdin to payloads), return empty so the caller falls through to
    # the no-TTY smart default. SSH / serial users get the real menu.
    if [ ! -r /dev/stdin ] 2>/dev/null; then
        log_only "stdin not readable (Pager UI click); falling through to smart default"
        printf ''
        return 0
    fi
    read -r choice
    case "$choice" in
        1|p|pseudonym)   printf 'pseudonym' ;;
        2|c|connection)  printf 'connection' ;;
        3|b|both)        printf 'both' ;;
        4|h|hybrid)      printf 'hybrid' ;;
        5|s|status)      printf 'status' ;;
        6|swap)          printf 'swap' ;;
        7|revert)        printf 'revert' ;;
        8|setup)         printf 'setup' ;;
        9|stop)          printf 'stop' ;;
        10|dryrun)       printf 'dryrun' ;;
        11|uninstall)    printf 'uninstall' ;;
        12|\?|h|help)    printf 'help' ;;
        q|Q)             printf 'quit' ;;
        *)               printf '' ;;
    esac
}

# Default mode when Pager UI click triggers a no-stdin payload run.
# Persisted to /tmp/v28-default-mode so a sequence of clicks doesn't
# re-run setup unnecessarily.
DEFAULT_MODE_FILE="/tmp/v28-default-mode"
DEFAULT_MODE="${ATT_DEFAULT_MODE:-pseudonym}"
[ -f "$DEFAULT_MODE_FILE" ] && DEFAULT_MODE="$(cat "$DEFAULT_MODE_FILE" 2>/dev/null)"

smart_default() {
    # Called when the user clicked ATT from the Pager UI and no stdin is
    # available. The Pager UI hides stdout, so this just does the most
    # useful thing: make sure the orchestrator is running in the default
    # mode (whichever the user set last; defaults to 'pseudonym').
    log "Pager UI click — running smart default (mode=$DEFAULT_MODE)"
    log "log file: $LOG_FILE"
    log "(for interactive mode selection, SSH in and run: payload.sh)"
    if pgrep -f 'v28_run\.py' >/dev/null 2>&1; then
        log "orchestrator already running; nothing to do"
        log "  SSH in and run 'payload.sh status' or 'payload.sh stop'"
        return 0
    fi
    if preflight_for_mode "$DEFAULT_MODE"; then
        log "starting v28_run.py --mode $DEFAULT_MODE"
        # Run the orchestrator in the foreground. It will block until it
        # exits (or the user SSHes in to send a signal). The Pager UI
        # continues to show 'running' until the orchestrator exits.
        run_mode "$DEFAULT_MODE"
    else
        err "preflight failed; check $LOG_FILE"
        return 1
    fi
}

interactive() {
    while true; do
        show_menu
        action=$(pick_mode)
        case "$action" in
            "")
                # No input (Pager UI click). Do the smart default and exit.
                smart_default
                return $?
                ;;
            pseudonym|connection|both|hybrid)
                if preflight_for_mode "$action"; then
                    run_mode "$action"
                fi
                ;;
            status)        cmd_status ;;
            swap)
                printf 'flip to [w]olfssl or [b]asic? '
                read -r which
                case "$which" in
                    w|wolfssl) cmd_swap wolfssl ;;
                    b|basic)   cmd_swap basic ;;
                    *) log "swap cancelled" ;;
                esac
                ;;
            revert)        cmd_revert ;;
            setup)         cmd_setup ;;
            stop)          cmd_stop ;;
            dryrun)        cmd_dryrun ;;
            uninstall)     cmd_uninstall ;;
            help)          cmd_help ;;
            quit)          printf '\n'; exit 0 ;;
            *)
                log "invalid choice"
                continue
                ;;
        esac
        # After the action, pause briefly so the user can read output before
        # the menu redraws. Skip the pause if stdin is gone (Pager UI).
        if [ -r /dev/stdin ] 2>/dev/null; then
            printf '\n[att] press Enter to return to menu (q to quit)... '
            read -r cont
            case "$cont" in
                q|Q) exit 0 ;;
            esac
        else
            exit 0
        fi
    done
}

# ---------------------------------------------------------------------------
# argument dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
    "")
        interactive
        ;;
    pseudonym|connection|both|hybrid)
        mode="$1"; shift
        if preflight_for_mode "$mode"; then
            run_mode "$mode" "$@"
        else
            exit 1
        fi
        ;;
    status)         cmd_status ;;
    setup)          shift; cmd_setup "$@" ;;
    revert)         shift; cmd_revert "$@" ;;
    uninstall)      shift; cmd_uninstall "$@" ;;
    dryrun)         cmd_dryrun ;;
    stop)           cmd_stop ;;
    swap)           shift; cmd_swap "$@" ;;
    run)            shift
        # `payload.sh run <mode>` is shorthand for `payload.sh <mode>`
        if [ $# -gt 0 ]; then
            case "$1" in
                pseudonym|connection|both|hybrid)
                    mode="$1"; shift
                    if preflight_for_mode "$mode"; then
                        run_mode "$mode" "$@"
                    else
                        exit 1
                    fi
                    ;;
                *)
                    err "usage: payload.sh run <pseudonym|connection|both|hybrid>"
                    exit 1
                    ;;
            esac
        else
            # No mode given — show menu
            interactive
        fi
        ;;
    help|--help|-h) cmd_help ;;
    *)
        err "unknown command: $1"
        echo
        cmd_help
        exit 1
        ;;
esac
