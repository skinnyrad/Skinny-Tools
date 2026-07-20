#!/bin/sh
# ATT-Connection — start the v28 orchestrator in connection mode and tail
# the run.log so every WISPr / DHCP / NAT event shows up in real time.
# All hits are shown (no filtering).
#
# Connection mode uses the open BSS (wlan0open) with WISPr captive
# portal — no RADIUS events, so we tail run.log instead of radius.log.

set -u

ORCH=/mmc/root/payloads/user/Skinny-Tools/ATT/v28_run.sh
LOG_DIR=/mmc/root/loot/att-hotspot2-tracker

# Start the orchestrator in the background
"$ORCH" --mode connection &
ORCH_PID=$!

trap 'kill $ORCH_PID 2>/dev/null; wait $ORCH_PID 2>/dev/null; exit' INT TERM EXIT

LATEST=""
for i in $(seq 1 30); do
    LATEST=$(ls -t "$LOG_DIR"/run-*/run.log 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        break
    fi
    sleep 1
done

if [ -z "$LATEST" ]; then
    echo "[att-connection] orchestrator didn't create a log in 30s; check ATT-Status"
    kill $ORCH_PID 2>/dev/null
    exit 1
fi

echo "[att-connection] tailing $LATEST (Ctrl-C to stop)"
echo ""
exec tail -F "$LATEST"
