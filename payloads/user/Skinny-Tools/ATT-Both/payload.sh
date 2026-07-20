#!/bin/sh
# ATT-Both — start the v28 orchestrator in 'both' mode (pseudonym
# first, then connection) + live display helper. Live display pushes
# every RADIUS hit to the Pager UI as it arrives.

set -u

ORCH=/mmc/root/payloads/user/Skinny-Tools/ATT/v28_run.sh
DISPLAY=/mmc/root/payloads/user/Skinny-Tools/ATT/v28_live_display.py
LOG_DIR=/mmc/root/loot/att-hotspot2-tracker

"$ORCH" --mode both --phase1-duration 60 &
ORCH_PID=$!

trap 'kill $ORCH_PID 2>/dev/null; \
      killall -KILL v28_live_display.py 2>/dev/null; \
      wait 2>/dev/null; \
      exit' INT TERM EXIT

LATEST_RADIUS=""
LATEST_RUN=""
for i in $(seq 1 30); do
    LATEST_RADIUS=$(ls -t "$LOG_DIR"/run-*/radius.log 2>/dev/null | head -1)
    LATEST_RUN=$(ls -t "$LOG_DIR"/run-*/run.log 2>/dev/null | head -1)
    if [ -n "$LATEST_RADIUS" ] && [ -n "$LATEST_RUN" ]; then
        break
    fi
    sleep 1
done

if [ -z "$LATEST_RADIUS" ] || [ -z "$LATEST_RUN" ]; then
    echo "[att-both] orchestrator didn't create logs in 30s; check ATT-Status"
    kill $ORCH_PID 2>/dev/null
    exit 1
fi

python3 "$DISPLAY" "$LATEST_RADIUS" --mirror /tmp/v28-live-hits.log &
DISPLAY_PID=$!

echo "[att-both] tailing:"
echo "  RADIUS: $LATEST_RADIUS"
echo "  orchestrator: $LATEST_RUN"
echo "  live hits:    /tmp/v28-live-hits.log"
echo "  (Ctrl-C to stop)"
echo ""
tail -F "$LATEST_RADIUS" "$LATEST_RUN"
