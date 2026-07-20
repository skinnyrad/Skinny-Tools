#!/bin/sh
# ATT-Dryrun — sub-payload shim. Read-only env sanity check (no changes).
# Useful to verify the Pager is ready before a real run.

exec /mmc/root/payloads/user/Skinny-Tools/ATT/payload.sh dryrun
