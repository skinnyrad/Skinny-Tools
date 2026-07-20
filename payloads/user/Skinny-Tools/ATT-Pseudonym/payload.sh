#!/bin/sh
# ATT-Pseudonym — start the v28 orchestrator in pseudonym mode + live
# display helper. The helper tails radius.log and pushes every RADIUS
# Access-Request to the Pager UI (LOG + LED + first-hit ALERT) so you
# see hits on the Pager without SSHing in.
#
# SSH for a richer view:
#   /mmc/root/payloads/user/Skinny-Tools/ATT-Pseudonym/payload.sh
# Or click ATT-Pseudonym from the Pager UI (output is hidden by the
# Pager UI, but the LOG/LED/ALERT events still fire on the device).
#
# Ctrl-C kills both the orchestrator and the display helper.

set -u

ORCH=/mmc/root/payloads/user/Skinny-Tools/ATT/v28_run.sh
DISPLAY=/mmc/root/payloads/user/Skinny-Tools/ATT/v28_live_display.py
LOG_DIR=/mmc/root/loot/att-hotspot2-tracker

# Start the orchestrator in the background
"$ORCH" --mode pseudonym --no-rotate &
ORCH_PID=$!

# Cleanup on exit: kill orchestrator + display helper
trap 'kill $ORCH_PID 2>/dev/null; \
      killall -KILL v28_live_display.py 2>/dev/null; \
      wait 2>/dev/null; \
      exit' INT TERM EXIT

# Start the live display helper — it auto-discovers radius.log under
# $LOG_DIR and re-picks the latest one if the orchestrator rotates.
python3 "$DISPLAY" --log-dir "$LOG_DIR" --mirror /tmp/v28-live-hits.log &
DISPLAY_PID=$!

echo "[att-pseudonym] orchestrator PID=$ORCH_PID  display PID=$DISPLAY_PID"
echo "[att-pseudonym] mirror:  /tmp/v28-live-hits.log"
echo ""
# Block in the foreground tail so the user sees the raw feed too.
# Wait for at least one radius.log to exist.
for i in $(seq 1 30); do
    LATEST=$(ls -t "$LOG_DIR"/run-*/radius.log 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        break
    fi
    sleep 1
done
if [ -z "$LATEST" ]; then
    echo "[att-pseudonym] no radius.log appeared in 30s; check ATT-Status"
    kill $ORCH_PID 2>/dev/null
    exit 1
fi
tail -F "$LATEST"
