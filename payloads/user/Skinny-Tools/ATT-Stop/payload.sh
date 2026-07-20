#!/bin/sh
# ATT-Stop — sub-payload shim. Kills v28_run.py + radius-reject.py +
# helpers. The orchestrator's cleanup() runs and flips wpad back to Hak5
# (per the v28_run.py fix).

exec /mmc/root/payloads/user/Skinny-Tools/ATT/payload.sh stop
