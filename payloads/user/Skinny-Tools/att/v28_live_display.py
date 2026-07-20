#!/usr/bin/env python3
"""
v28_live_display.py — live Pager-screen display for the v28 orchestrator.

Tails a radius.log file (produced by radius-reject.py) and pushes each
new RADIUS Access-Request to the Pager UI so you can see hits without
having to SSH in:

  - LOG <color> "<msg>"  -> Pager UI logs tab (live feed, every hit)
  - LED <color> <pattern> -> visual indicator on the Pager hardware
  - ALERT "<msg>"  -> modal popup on the LCD (first hit only, to avoid
                       popup spam if many devices probe at once)

This script is a no-op when not running on a Pager (no ALERT/LOG/LED
binaries) so it's safe to run on a laptop for testing.

Mirrors every hit to stdout, so `tail -f` of the orchestrator's log or
running this directly over SSH both work.

Usage:
  v28_live_display.py <radius.log> [--no-alert] [--log-target PATH]

The process is intended to be killed (SIGTERM) when v28_run.py exits.
On EOF of the log file (radius-reject.py exited), the display process
tails indefinitely waiting for new data; the parent is responsible for
killing it.
"""

import argparse
import os
import re
import sys
import time

# ---- Pager UI tools (graceful no-op when not on a Pager) ------------------

def _have(cmd):
    return os.path.exists(f"/usr/bin/{cmd}")

def _run(cmd):
    try:
        return os.system(f"{cmd} >/dev/null 2>&1")
    except Exception:
        return -1

def alert(msg):
    if not _have("ALERT"): return
    safe = msg.replace("'", "'\\''")
    _run(f"ALERT '{safe}'")

def log(msg, color="yellow"):
    if not _have("LOG"): return
    safe = msg.replace("'", "'\\''")
    _run(f"LOG {color} '{safe}'")

def led(color, pattern="SINGLE"):
    if not _have("LED"): return
    _run(f"LED {color} {pattern}")


# ---- radius.log parser -----------------------------------------------------

# RECV line format (from radius-reject.py):
#   [2026-07-20 00:04:55] RECV  code=Access-Request  ident=  1
#       src=127.0.0.1:54321  len= 200  attrs=  5  eap=Y
#       username='0123456789@att.net'  mac=aa:bb:cc:dd:ee:ff
#       ap=00:13:37:95:1e:b0  ...
USERNAME_RE = re.compile(r"username='([^']*)'")
MAC_RE      = re.compile(r"mac=([0-9A-Fa-f:]{17})")
RECV_RE     = re.compile(r"\bRECV\b")

def parse_recv(line):
    if not RECV_RE.search(line):
        return None, None
    um = USERNAME_RE.search(line)
    mm = MAC_RE.search(line)
    pseudonym = um.group(1) if um else ""
    mac = mm.group(1) if mm else ""
    if "@" in pseudonym:
        pseudonym = pseudonym.split("@", 1)[0]
    return pseudonym, mac


# ---- main loop -------------------------------------------------------------

def main():
    p = argparse.ArgumentParser()
    p.add_argument("log_file", nargs="?",
                   help="radius.log to tail (default: auto-detect from "
                        "/mmc/root/loot/att-hotspot2-tracker/run-*/radius.log)")
    p.add_argument("--no-alert", action="store_true",
                   help="skip ALERT popups (LOG + LED still fire)")
    p.add_argument("--mirror", metavar="PATH",
                   help="also append every hit to this file (for tail -f)")
    p.add_argument("--log-dir", default="/mmc/root/loot/att-hotspot2-tracker",
                   help="dir to scan for radius.log when log_file is "
                        "omitted or the file disappears")
    args = p.parse_args()

    if not args.log_file:
        args.log_file = _find_latest_log(args.log_dir)

    first_hit = True
    current_log = None
    seen_lines_at = {}  # path -> last byte position we read up to
    while True:
        # Pick the most recent radius.log on every outer-loop iteration.
        # The orchestrator's wifi reload can rotate to a new run-dir mid-
        # run; we need to follow the latest path even if our current one
        # is still being written to.
        latest = _find_latest_log(args.log_dir)
        if latest and latest != current_log:
            current_log = latest
            seen_lines_at[current_log] = 0  # we haven't read anything here yet
            print(f"[v28-live] tailing {current_log}", flush=True)
            log(f"[v28] tailing {current_log}", "green")
        if not current_log:
            time.sleep(0.5)
            continue

        last_pos = seen_lines_at.get(current_log, 0)
        try:
            with open(current_log, "r") as f:
                f.seek(last_pos)
                while True:
                    line = f.readline()
                    if not line:
                        # EOF — back off and re-evaluate which log to
                        # follow on the next outer iteration
                        seen_lines_at[current_log] = f.tell()
                        break
                    pseudonym, mac = parse_recv(line)
                    if not pseudonym and not mac:
                        continue

                    bits = []
                    if mac:       bits.append(f"mac={mac}")
                    if pseudonym: bits.append(f"pseudonym={pseudonym}")
                    summary = "  ".join(bits)

                    ts = time.strftime("%H:%M:%S", time.localtime())
                    line_out = f"[{ts}] {summary}"
                    print(f"[v28-live] {line_out}", flush=True)
                    log(f"[v28] {line_out}", "yellow")
                    if args.mirror:
                        try:
                            with open(args.mirror, "a") as mf:
                                mf.write(f"[{ts}] {line_out}\n")
                        except OSError:
                            pass
                    led("Y" if pseudonym else "C", "SINGLE")
                    if not args.no_alert and first_hit:
                        if pseudonym:
                            alert(f"HIT  {pseudonym}")
                        else:
                            alert(f"HIT  {mac}")
                        first_hit = False
        except OSError as e:
            print(f"[v28-live] error reading {current_log}: {e}", flush=True)
            time.sleep(0.5)

        # Brief pause before re-evaluating which log to follow
        time.sleep(0.3)


def _find_latest_log(log_dir):
    """Return the radius.log in the most recently created run-NNN dir.
    We key on the run-dir's mtime (not the file's) so we pick up newly
    created run dirs even before the orchestrator has written to the
    radius.log yet."""
    try:
        candidates = []
        for entry in os.listdir(log_dir):
            if not entry.startswith("run-"):
                continue
            run_dir = os.path.join(log_dir, entry)
            if not os.path.isdir(run_dir):
                continue
            full = os.path.join(run_dir, "radius.log")
            if os.path.exists(full):
                candidates.append((os.path.getmtime(run_dir), full))
        if not candidates:
            return None
        candidates.sort(reverse=True)
        return candidates[0][1]
    except OSError:
        return None


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        pass
