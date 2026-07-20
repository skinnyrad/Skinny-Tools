#!/bin/sh
# ATT-Revert — sub-payload shim. Flips wpad back to Hak5 basic-mbedtls
# (non-destructive; both binaries stay on disk for hotswap re-entry).

exec /mmc/root/payloads/user/Skinny-Tools/ATT/payload.sh revert
