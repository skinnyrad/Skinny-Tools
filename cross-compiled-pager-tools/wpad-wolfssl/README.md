# wpad binaries — Hak5 basic-mbedtls + OpenWrt wpad-wolfssl

Cached wpad builds for the Hak5 WiFi Pineapple Pager (`mipsel_24kc`,
OpenWrt 24.10.1). Both binaries live side-by-side on the Pager
(`/usr/sbin/wpad-basic-mbedtls` and `/usr/sbin/wpad-wolfssl`); the
active binary is selected by the symlink at `/usr/sbin/wpad`.

## Files

| File | Bytes | SHA-256 | Source |
|---|---|---|---|
| `wpad-basic-mbedtls` | 790920 | `810d224e...81317` | Hak5 stock build, Apr 13 2025 |
| `wpad-wolfssl` | 1394311 | `ed6c3385...2763a` | OpenWrt 24.10.1 base/wpad-wolfssl 2024.09.15~5ace39b0-r2 |
| `libwolfssl.so.5.9.1.e624513f` | 1388527 | `51d37fa9...b980` | OpenWrt 24.10.1 base/libwolfssl5.9.1.e624513f 5.9.1-r1 |
| `wpad-wolfssl_2024.09.15~5ace39b0-r2_mipsel_24kc.ipk` | 760163 | `b0952522...3edb` | OpenWrt 24.10.1 base feed |
| `libwolfssl5.9.1.e624513f_5.9.1-r1_mipsel_24kc.ipk` | 605383 | `a0bb8d1d...3388` | OpenWrt 24.10.1 base feed |

Full shas in `SHA256SUMS` (`shasum -a 256 -c SHA256SUMS` to verify).

## Why both binaries

Hak5's stock `wpad-basic-mbedtls` (790 KB) strips Passpoint / HS2.0 /
EAP-AKA' / Interworking support — fine for the Pager's normal use
(pineAP + management AP + wpa_supplicant for `wlan0cli`), but blocks
any v28 ATT-Hotspot2-Tracker mode that needs Passpoint.

`wpad-wolfssl` (1.39 MB) is the OpenWrt build with wolfssl crypto —
it has Passpoint/HS2.0/EAP-AKA' compiled in. The v28 orchestrator
needs it for `pseudonym`, `both`, and `hybrid` modes.

The Pager is happiest when the symlink at `/usr/sbin/wpad` flips
between the two without removing either binary, so the hotswap script
`v28_wpad.sh basic|wolfssl` can flip in <2s without opkg churn.

## Hotswap layout (target state on the Pager)

```
/usr/sbin/wpad                  -> symlink to wpad-basic-mbedtls (Hak5 default)
/usr/sbin/wpad-basic-mbedtls    = 790920 bytes, sha 810d224e (Hak5)
/usr/sbin/wpad-wolfssl          = 1394311 bytes, sha ed6c3385 (wolfssl)
/usr/sbin/hostapd               -> symlink to wpad
/usr/sbin/wpa_supplicant        -> symlink to wpad
/usr/lib/libwolfssl.so.5.9.1.e624513f  = 1388527 bytes, sha 51d37fa9
/mmc/root/wpad-basic-mbedtls.backup   = same as wpad-basic-mbedtls (fallback)
```

`v28_wpad.sh status` should show both candidates present and the symlink
pointing to whichever is currently active.

## Offline install (when the Pager has no internet)

```sh
# On the Pager, with this folder scp'd to /tmp/wpad-wolfssl/:
cd /tmp/wpad-wolfssl
opkg install libwolfssl5.9.1.e624513f_5.9.1-r1_mipsel_24kc.ipk
opkg install wpad-wolfssl_2024.09.15~5ace39b0-r2_mipsel_24kc.ipk

# Then set up the hotswap layout (cp wpad -> wpad-wolfssl, symlink wpad -> basic):
cp /usr/sbin/wpad /usr/sbin/wpad-wolfssl
cp /usr/sbin/wpad-basic-mbedtls /usr/sbin/wpad-basic-mbedtls  # if needed
rm /usr/sbin/wpad
ln -s wpad-basic-mbedtls /usr/sbin/wpad
ln -sf wpad /usr/sbin/hostapd
ln -sf wpad /usr/sbin/wpa_supplicant
```

## Provenance

- `wpad-basic-mbedtls`, `wpad-wolfssl`, `libwolfssl.so.5.9.1.e624513f`:
  pulled live from a Hak5 Pineapple Pager (root@172.16.52.1) on
  2026-07-19 via `scp` (binary-safe, no PTY translation).
- `wpad-wolfssl.control`, `wpad-wolfssl.list`: pulled from
  `/usr/lib/opkg/info/` on the Pager.
- `*.ipk`: downloaded from `https://downloads.openwrt.org/releases/24.10.1/`
  for offline reinstall.

## Future integration

The plan is to fold these offline `.ipk` files into
`v28_wpad_install.sh install` so the script can:
1. Detect no-internet and fall back to `opkg install /tmp/*.ipk`
2. Set up the hotswap layout (cp wpad -> wpad-wolfssl, symlink -> basic)
3. Skip the `opkg update` + remote-fetch path when the files are present
