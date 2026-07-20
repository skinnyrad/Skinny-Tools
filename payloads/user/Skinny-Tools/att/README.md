# ATT-Hotspot2-Tracker (v28) — README

> **Goal:** find AT&T iPhones that are hidden in secure facilities and
> shouldn't be there. The tool uses two parallel attack paths against the
> carrier-managed `attwifi` open SSID + the Passpoint RADIUS-controlled
> enterprise variant, both of which iPhones provisioned by AT&T
> automatically probe for.

The tool runs on a Hak5 WiFi Pineapple Pager (`mipsel_24kc`, OpenWrt
24.10.1) with `wpad-wolfssl` installed alongside the Hak5-patched
`wpad-basic-mbedtls`. See `knowledge/plans/V28_PLAN_20260719-215200.md`
for the full design rationale and `knowledge/snapshot/PAGER-FACTORY-*`
for the byte-identical pre-install Pager state.

---

## Quick start

**Use `payload.sh` as the single entry point.** It wraps every v28 helper
script and gives the Pager UI one menu instead of nine scripts to remember.

```sh
ssh root@172.16.52.1
cd /mmc/root/payloads/user/Skinny-Tools/ATT

# Pager UI launcher (interactive menu)
./payload.sh

# Or pass a subcommand directly:
./payload.sh status           # show wpad state + processes
./payload.sh setup            # one-time install wpad-wolfssl
./payload.sh swap wolfssl     # flip active wpad -> wolfssl (~2s)
./payload.sh run              # start orchestrator (interactive mode picker)
./payload.sh stop             # kill orchestrator + flip wpad back to Hak5
./payload.sh revert           # flip wpad -> Hak5 (preserves hotswap layout)
./payload.sh uninstall        # DESTRUCTIVE: rm + opkg remove wpad-wolfssl
./payload.sh help             # full subcommand list
```

The companion scripts (`v28_run.py`, `v28_wpad.sh`, `v28_wpad_install.sh`,
etc.) can still be invoked directly if you know which one you want — but
for normal use `payload.sh <cmd>` is the recommended path.

### Equivalent direct calls (for reference)

```sh
ssh root@172.16.52.1
cd /mmc/root/payloads/user/Skinny-Tools/ATT

# ONE-TIME: install wpad-wolfssl (Pager ships with Hak5 build which lacks
# Passpoint / HS2.0 / EAP-AKA support)
./v28_wpad_install.sh status              # confirm not yet installed
./v28_wpad_install.sh install --yes      # non-interactive

# Pseudonym mode (default — captures IMSI pseudonym, dense RSSI)
./v28_run.py --mode pseudonym --no-rotate

# Open AP / WISPr connection mode (TCP path — see section 3)
./v28_run.py --mode connection

# Pseudo + connection sequenced (pseudonym first → swap → connection)
./v28_run.py --mode both --phase1-duration 60

# Hybrid (both BSSs up simultaneously, concurrent sniffer streams)
./v28_run.py --mode hybrid

# REVERT (non-destructive — preserves hotswap layout, both binaries stay on disk)
./v28_wpad_install.sh uninstall --yes

# FULL PURGE (destructive — removes wpad-wolfssl + libwolfssl; breaks hotswap)
./v28_wpad_install.sh uninstall --purge --yes
```

> **SSH source check:** the orchestrator refuses to run if SSH source is
> `wlan0cli` (wifi reload drops the session). Use Ethernet, USB-C
> tether, or on-Pager tmux. Override with `ATT_FORCE_WLAN0CLI=1`.

> **Install/uninstall safety:** `v28_wpad_install.sh` refuses to run
> while `v28_run.py` is active (kills + symlink swap would race with
> the running orchestrator). Stop the orchestrator first with
> `pkill -KILL -f v28_run.py`.

---

## 1. The `pseudonym` mode (Passpoint + RADIUS reject)

### 1.1 What it does

`v28_run.py --mode pseudonym` brings up the Pager's `wlan0wpa` as a
Passpoint-class WPA-Enterprise BSS advertising the SSID `attwifi` with
the full 802.11u / Hotspot 2.0 IE set (Interworking, Roaming
Consortium, NAI realm `att.net`, 3GPP PLMN 310/410, HS2.0 Indication).
The BSS points its `auth_server` at `127.0.0.1:1812`, where our
`radius-reject.py` binds.

When the iPhone sees this BSS, its Passpoint state machine enters
**row 4** of the four-state table (see `knowledge/PASSPOINT_BEHAVIOR_DEEP_DIVE.md` §3a):

1. **Sees** the Interworking IE with matching Roaming Consortium OI `310410`
2. **Reads** NAI realm `att.net` matches its carrier profile
3. **Sends** directed probe for `attwifi` to our BSSID
4. **Triggers** EAP-AKA' auth flow against our RADIUS

Our RADIUS server receives the EAP-Identity (which contains the
iPhone's **IMSI pseudonym** — a temporary identifier the iPhone
rotates per-network, bound to the SIM, not the device MAC) and
processes it according to the configured RADIUS mode.

### 1.2 The IMSI pseudonym — what we actually capture

From the iPhone's `EAP-Response/Identity` (RADIUS attribute 1, type 79
`EAP-Message`, value is the EAP payload), our server logs:

```
RECV  code=Access-Request  ident=0  src=127.0.0.1:33372  len=333  attrs=18  eap=Y
      username='2PqQSlC/V6g5cIqTxEuCNZY@wlan.mnc280.mcc310.3gppnetwork.org'
      mac=08-C7-B5-3B-6D-DA  ap=02-13-37-AC-AF-24:attwifi  nas=021337acaf24
```

The `username=` field is the **3GPP NAI** (Network Access Identifier):

| Component | Value | Meaning |
|---|---|---|
| `2PqQSlC/V6g5cIqTxEuCNZY` | fast-reauth pseudonym | temporary, scoped to this BSSID's domain, rotated only on successful full auth |
| `@wlan.mnc280.mcc310.3gppnetwork.org` | NAI realm | AT&T US (MCC 310), carrier MNCMCC pair identifying the SIM's home network |

Why this matters:

1. **The pseudonym is bound to the SIM, not the device.** iOS rotates
   link-layer MACs per-SSID (Private Wi-Fi Address), per-attempt, and
   periodically — every "device" you see on the sniffer could be the
   same physical iPhone with a different MAC. The pseudonym doesn't
   rotate on failed auths (it would only be re-issued by a real HSS
   after a successful full EAP-AKA' run), so all the iPhone's
   randomized-MAC appearances get collapsed to one identity.
2. **mcc310** is the AT&T US mobile country code. Other carriers would
   show different mcc values (e.g. mcc302 for Canada). Filters on
   `mcc310` automatically scope to AT&T-provisioned devices.
3. **The format `0\fastauth<PSEUDO>`** is the 3GPP standard for
   fast-reauthentication identities (RFC 4187 §4.1.1.7). A real IMSI
   (`<15-digit-IMSI>@wlan.mnc<mnc>.mcc<mcc>.3gppnetwork.org`) only
   appears if the HSS requests full authentication via `AT_FULLAUTH_ID_REQ`,
   which never happens against our rejecting RADIUS.

### 1.3 RADIUS modes (the `--radius-mode` flag)

The orchestrator passes `--radius-mode <MODE>` to `radius-reject.py`,
which controls how we respond to the iPhone's EAP-AKA' identity. Each
mode is a different trade-off between **capture density** and
**iPhone-backing-off** behavior:

| Mode | What we send | iPhone retry rate | RECV/min | Auto-join | Blacklist |
|---|---|---|---|---|---|
| `broken` **(default)** | Malformed Access-Reject (length=200, actual=20 bytes) | **every 1-5s** | **~14** | **stays on** | **never increments** |
| `log-only` | (nothing — UDP socket silently receives) | every ~14s | ~4 | stays on | never increments |
| `reject` | Clean EAP-Failure (with Message-Authenticator) | every 30-60s | ~2 | stays on | increments |
| `accept` | Access-Accept (4-way handshake fails at MIC) | once then gives up | 1 | turns off | increments |
| `sweep` | Alternate reject / accept | variable | variable | unstable | unstable |

### 1.4 Why `broken` mode is the right default for this tool

This is the central design decision. Three orthogonal properties of the
iPhone's Passpoint behavior make `broken` strictly better than
`reject` (the "obvious" choice) for our use case:

#### 1.4.1 The iPhone's BSSID blacklist is keyed on clean EAP-Failure

Per `knowledge/RADIUS-Step-By-Step.txt` (lines 674-687) and confirmed
empirically: iOS puts a BSSID on a temporary auto-join blacklist for
**5-10 minutes** after **2-3 rapid failed auth attempts** — but the
counter only ticks up when the iPhone receives a **clean EAP-Failure**
(an EAP code 4 frame terminating the conversation). If the conversation
stalls before EAP-Failure is delivered (timeout, malformed frame, etc.),
the counter doesn't increment.

`broken` mode takes advantage of this: we send a packet that **looks
like** Access-Reject (Code 3, Ident matches) but the Length field
claims 200 bytes when only 20 are present. hostapd's RADIUS client
fails to parse it (`RADIUS: Parsing incoming frame failed` in
syslog), drops the reply without converting it to EAP-Failure, and the
iPhone's auth exchange just... hangs. The iPhone waits the auth
timeout (5-10 seconds), then retries.

Net result: **the iPhone's BSSID blacklist counter never increments
because it never receives a clean failure**, so auto-join stays
enabled indefinitely.

#### 1.4.2 `broken` mode gives ~7× more pseudonym captures per minute

Because the iPhone retries much more aggressively when its auth
exchange stalls than when it gets a clean failure, the capture rate
is dramatically higher. Measured on the same iPhone (MAC
`08:c7:b5:3b:6d:da`, pseudonym `2PqQSlC/V6g5cIqTxEuCNZY@wlan.mnc280.mcc310.3gppnetwork.org`):

| Mode | RECV in 60s | RECV/min | iPhone retry interval |
|---|---|---|---|
| `broken` | 14 (verified) | **~14** | **1-5s** (sub-second when hostapd retries internally) |
| `log-only` | ~4 (verified) | 4 | ~14s |
| `reject` (with Message-Authenticator) | ~2 (verified) | 2 | 30-60s |
| earlier broken-state run (v25-era Reply-Message length bug) | 28 in 146s | ~11.5 | 1-3s |

The 14/min figure is the floor; under load it can hit 28/min as
hostapd internally retransmits and we capture each.

For RSSI-based geolocation (the eventual downstream use of this
tool), more captures per minute = more RSSI samples per minute =
better trilateration resolution. At a stationary rate of 14
samples/min, a moving target can be tracked with sub-second
granularity over 5-minute windows.

#### 1.4.3 The iPhone's UI stays in the "spinning-circle" state — no detection risk

In `broken` mode, the iPhone's Wi-Fi settings UI shows the network
attempting to connect with a continuously spinning circle — never
resolving to a green checkmark (success) or red X (failure). The
user sees this as "the network is having trouble" rather than "the
network rejected my phone", which is operationally desirable in
adversarial environments: a user who notices a stuck spinner is more
likely to ignore it than one who sees their phone repeatedly being
rejected.

In `reject` mode, the user sees the network briefly connect, fail,
disconnect, and the circle-spinner is replaced by a brief "wrong
password" or "unable to join" message that cycles each retry. This
is a more obvious indicator that something is wrong.

### 1.5 Why not `accept`?

`accept` mode sends a valid Access-Accept with a fake MSK. hostapd
attempts the 4-way handshake, the iPhone rejects Message 2 because
its computed PTK doesn't match hostapd's (different PMK — the iPhone
computes from the SIM's Ki via AKA', our RADIUS just made one up),
and the iPhone's behavior after that depends on which message fails
the MIC check. In practice this gets a **single** auth attempt before
the iPhone adds this BSSID to its hard blacklist (no auto-join, no
further attempts until manual toggle). Not useful for sustained
capture.

### 1.6 Why not just use the iPhone's known `attwifi` profile directly?

The iPhone has `attwifi` provisioned as a Passpoint network in its
AT&T carrier profile. It auto-joins `attwifi` whenever it sees a
matching BSSID. If we broadcast `attwifi` as a plain **open** BSS (no
802.11u / HS2.0 IEs), the iPhone does *not* auto-join — modern iOS
treats open `attwifi` as an Evil Twin attempt (per the
`EAP-SUCCESS+Bridging.txt` reference: "iOS assumes it is a hostile
'Evil Twin' attempting to intercept data or force a fake captive
portal. The phone silently filters it out."). The iPhone's
background scan does emit `<broadcast>` probes for `attwifi`, but
they're generic SSID probes that don't trigger the Passpoint EAP-AKA'
flow — so we only get broadcast probe requests, not EAP-Identity
frames, in radius.log.

The 802.11u IE set + HS2.0 Indication + WPA-Enterprise is what tells
iOS "this is a real AT&T Passpoint AP" — only then does it kick off
the full EAP-AKA' conversation that exposes the IMSI pseudonym.

### 1.7 What we do *not* capture

- **Real IMSI.** Only fast-reauth pseudonyms. To capture the real IMSI,
  our RADIUS would need to issue `AT_FULLAUTH_ID_REQ` to the iPhone,
  which the iPhone answers with the real IMSI. We never do this
  because we don't have a real HSS to validate against.
- **4-way handshake completion.** Without the right PMK, we can't
  derive the same PTK as the iPhone, so the 4-way handshake always
  fails. We never see encryption keys.
- **Data traffic.** The iPhone never gets an IP, never sends DHCP,
  never routes user traffic through us. The pseudonym + RSSI is the
  entire payoff.

### 1.8 Per-run logs

```
/mmc/root/loot/att-hotspot2-tracker/run-YYYYMMDD-HHMMSS/
├── radius.log        # every RECV/BROKEN/REJECT line; pseudonym + MAC + BSSID
├── sniffer.log       # (not used in pseudonym mode; reserved for connection)
├── sniffer-raw.log   # (not used in pseudonym mode)
├── run.log           # orchestrator mode transitions, wpad swaps, UCI changes
├── dhcpd.log         # (not used in pseudonym mode)
├── wispr.log         # (not used in pseudonym mode)
└── summary.log       # (not used in pseudonym mode)
```

### 1.9 Pseudonym → device correlation

Once you have the pseudonym, the iPhone's link-layer MAC (from
`Calling-Station-Id`) and BSSID (from `Called-Station-Id`) are recorded
alongside every RECV. The MAC rotates per-SSID/per-attempt on
modern iOS (Private Wi-Fi Address, AKA "Wi-Fi MAC address
randomization"), but the pseudonym does not rotate on failed
attempts, so:

- **5 MACs seen across 5 separate background-scan cycles** = probably
  1 device (the same iPhone rotated its MAC 5 times but the
  pseudonym stayed `2PqQSlC/V6g5cIqTxEuCNZY…`).
- **5 MACs with 5 different pseudonyms** = 5 separate iPhones.

The runtime correlate tool (`v28_run.py` will integrate this in v29)
joins MAC and pseudonym histories to deduplicate device counts.

### 1.10 Quick diagnostic (when no RECVs are happening)

```sh
ssh root@172.16.52.1

# BSS up?
iw dev wlan0wpa info | head -8
# expect: type AP, ssid attwifi

# wpad is the wolfssl binary?
sha256sum /proc/$(pidof hostapd | head -1)/exe
# expect: ed6c3385b91ad340a945b19bc87e58676628d156f55cde99028056462052763a (wolfssl)
# NOT:    810d224edc4052aeb80fd4f6439857faba3065f8f6b01e968b952c5a95d81317 (basic-mbedtls)

# RADIUS bound?
netstat -uln | grep 1812
# expect: ONE listener (multiple = zombie processes binding port)

# Last 10 RADIUS events
tail -10 /mmc/root/loot/att-hotspot2-tracker/latest/radius.log

# Live hostapd EAP activity
logread | grep -iE "hostapd.*(eap|frame|dropped|08:c7)" | tail -10
# expect: CTRL-EVENT-EAP-STARTED + "RADIUS: Parsing incoming frame failed"
```

If the iPhone is associated but no RECVs are appearing, the most
likely cause is **multiple processes bound to 1812** (zombie
radius-reject.py from a prior crashed run). Run the orchestrator's
built-in defensive kill:

```sh
pkill -KILL -f "python3.*radius-reject.py"
pkill -KILL -f "python3.*v28_run.py"
sleep 2
# Then restart:
cd /mmc/root/payloads/user/Skinny-Tools/ATT
setsid python3 -u v28_run.py --mode pseudonym --no-rotate \
    > /tmp/v28/run.log 2>&1 < /dev/null &
```

---

## 2. The `connection` mode (open AP + WISPr Apple Success + DHCP + NAT)

_TBD — section pending implementation test._

This mode imitates an AT&T legacy `attwifi` open SSID with the right
IE-221 vendor OUIs (Cisco `00:40:96`, Aruba `00:1a:1e`, Ruckus
`00:1b:0d`) so iOS's Evil-Twin filter lets the BSS through. Then
the captive-portal check `captive.apple.com` is DNAT'd to a local
HTTP server returning Apple's exact `<HTML><HEAD><TITLE>Success>...
</BODY></HTML>` body (per `EAP-SUCCESS+Bridging.txt` §"Phase 1").
iOS marks the network as online, DHCP hands out an IP via the
stdlib `v28_dhcpd.py`, and the iPhone gets full TCP connectivity.
Used when the goal is to confirm the device is fully present (not
just probing) and to read RSSI continuously from the TCP data path
(ping/arp).

---

## 3. The `both` mode (pseudonym → swap → connection)

_TBD — section pending implementation test._

Phase 1: `pseudonym` mode for `--phase1-duration` seconds (default
300). Captures the IMSI pseudonym.

Phase 2: wpad swap `wolfssl → basic`, bring up `wlan0open` with
WISPr + DHCP + NAT. iPhone re-associates against the open BSS
(gets IP, gets captive-portal trust).

Combines both proofs: **"this device probed our Passpoint and
showed up as IMSI pseudonym X" + "this same device then fully
connected to our open BSS as MAC Y with IP 192.168.99.Z"**.

---

## 4. The `hybrid` mode (parallel BSSs)

_TBD — section pending implementation test._

Both `wlan0wpa` (Passpoint) and `wlan0open` (open) up
simultaneously. iPhones with Passpoint profile go to `wlan0wpa`
(EAP-AKA' rejects, pseudonym captured). iPhones without Passpoint
profile but with `attwifi` open provisioning go to `wlan0open`
(TCP connect). Two parallel sniffer streams log which device went
to which BSS.

---

## 5. Architecture notes

### 5.1 The `wpad` symlink-swap

The Pager ships with Hak5's patched `wpad-basic-mbedtls` (790 KB,
sha256 `810d224e…`), which lacks Interworking/HS2.0/EAP-AKA
support. Passpoint mode needs `wpad-wolfssl` (1.39 MB, sha256
`ed6c3385…`). Use `v28_wpad_install.sh` for the swap:

```sh
# check current state
v28_wpad_install.sh status

# install (interactive y/n prompt — backs up the Hak5 build first)
v28_wpad_install.sh install
v28_wpad_install.sh install --yes    # non-interactive

# revert to Hak5 stock
v28_wpad_install.sh uninstall
v28_wpad_install.sh uninstall --yes  # non-interactive
```

The script handles the full state transition atomically-ish:
1. Backs up `/usr/sbin/wpad` (the current Hak5 build) to
   `/mmc/root/wpad-basic-mbedtls.backup` and `/usr/sbin/wpad-basic-mbedtls`
2. `opkg remove wpad-basic-mbedtls` + `opkg install wpad-wolfssl`
   (pulls `libwolfssl5.9.1.e624513f`)
3. Arranges symlinks: `/usr/sbin/wpad → /usr/sbin/wpad-wolfssl`
4. Kills hostapd so pineapplepager re-spawns it under the wolfssl
   binary (hostapd does NOT re-exec itself on `wifi reload` — it
   just receives new config via ubus)
5. `wifi reload`

`v28_wpad.sh` flips the symlink for in-tool mode changes (passpoint
needs wolfssl, connection mode prefers Hak5-patched to keep `pineape_*`
hostapd_cli extensions).

**CRITICAL**: the running hostapd process must be killed when the
symlink flips, because hostapd does NOT re-exec itself on `wifi
reload` — it just receives a new config via ubus. v28_wpad.sh
includes a `restart_hostapd()` step that kills hostapd and lets
pineapplepager re-spawn it under the new symlink target. Without
this, the running hostapd is the OLD binary in memory and
silently rejects the new IEs as "unknown configuration item" (28+
errors in syslog).

To revert (non-destructive — preserves hotswap layout, both binaries stay
on disk for `v28_wpad.sh wolfssl` re-entry):
`v28_wpad_install.sh uninstall` flips `/usr/sbin/wpad` back to
`/usr/sbin/wpad-basic-mbedtls` and `wifi reload`. Nothing is removed.

For the old destructive behavior (rm + `opkg remove wpad-wolfssl`,
frees ~1.4 MB but breaks hotswap until next install):
`v28_wpad_install.sh uninstall --purge`.

The `/mmc/root/wpad-basic-mbedtls.backup` file is preserved across
both variants so re-install is idempotent.

### 5.2 The BSSID pinning — universally-administered only

iOS silently filters BSSIDs whose first octet has bit 1 set
(locally-administered, e.g. `02:13:37:xx:xx:xx` or wpa_supplicant's
randomized `0a:13:37:xx:xx:xx`). The Pager's stock radio MAC is
`00:13:37:ac:af:24` (universally-administered) and that's what
`v28_run.py` pins into `wireless.wlan0wpa.bssid` (and
`wireless.wlan0open.bssid` in connection mode). Even though iOS
Passpoint auth keys on the Interworking IE rather than the BSSID,
a locally-administered BSSID is one of the things iOS uses as an
"Evil Twin" hint and may suppress the connection attempt entirely.

Note: the running `iw dev wlan0wpa info` may still show a
`02:13:37:ac:af:24` BSSID — that's because hostapd.sh on this
Pager build doesn't honor per-BSS `bssid` UCI for AP mode and
falls back to the per-phy default MAC (which wpa_supplicant
randomized when it brought up `wlan0cli`). The UCI pinning is
preserved for correctness even when hostapd ignores it.

### 5.3 SSH source check

`v28_run.py` refuses to run if its SSH source is `wlan0cli`:

```python
def assert_safe_shell():
    src = shell_out("ip route get 172.16.52.0/24 2>/dev/null | head -1")
    if "dev wlan0cli" in src and not os.environ.get("ATT_FORCE_WLAN0CLI"):
        sys.stderr.write("FATAL: SSH source is wlan0cli. ...\n")
        sys.exit(2)
```

The wifi reload that happens as part of any mode entry drops the
`wlan0cli` uplink for 5-15 seconds. If your SSH session is over
that uplink, the session drops mid-radio-mutation and the
orchestrator's signal handler can't run cleanup() → the radio MAC
stays randomized, the wpad symlink stays flipped, and the next
SSH connection (if you have any way to make one) finds a Pager in
a half-applied state.

Use Ethernet (`172.16.52.1` over USB-C), the Pager's own tmux
session, or set `ATT_FORCE_WLAN0CLI=1` if you accept the risk.

### 5.4 Defensive zombie-kill on startup

```python
shell_out("pkill -KILL -f 'radius-reject.py' 2>/dev/null; true")
shell_out("pkill -KILL -f 'v28_dhcpd.py' 2>/dev/null; true")
shell_out("pkill -KILL -f 'v28_wispr.py' 2>/dev/null; true")
time.sleep(1)
```

UDP's `SO_REUSEADDR` lets multiple processes bind to the same port
simultaneously. Only the FIRST bound socket receives incoming
packets. Without this defensive kill, a crashed-prior-run
radius-reject.py can hold the port and silently swallow every
Access-Request, making radius.log look empty even though hostapd
is logging "Connection refused" and the iPhone is sending
EAP-Identity frames every 5 seconds.

---

## 6. Files

```
/mmc/root/payloads/user/Skinny-Tools/ATT/
├── v28_run.py            # orchestrator (mode picker, UCI, signal handling)
├── v28_run.sh            # shell wrapper that execs v28_run.py
├── v28_dryrun.sh         # read-only sanity checker (run before any live mode)
├── v28_wpad.sh           # in-tool symlink swap driver (wolfssl ↔ basic-mbedtls)
├── v28_wpad_install.sh   # smart installer/uninstaller for wpad-wolfssl
│                         # (interactive prompts; safe refuse if v28_run.py running)
├── v28_dhcpd.py          # stdlib DHCP server for connection mode
├── v28_ie221.py          # IE-221 vendor OUI injector (Cisco/Aruba/Ruckus)
├── v28_wispr.py          # Apple Success / WISPr HTTP server
├── v28_isolate.sh        # br-att bridge create/destroy
├── v28_nat.sh            # firewall zone + forwarding (replaced by wan zone MASQ)
└── radius-reject.py     # RADIUS server with broken / log-only / reject modes
```

Source-of-truth copies in `knowledge/scripts/v28/` (Mac-side) and
byte-identical snapshot in `knowledge/scripts/versions/v28-20260719-215200/`.
SHA256 verified at deploy time.

---

## 7. Related docs

- `knowledge/plans/V28_PLAN_20260719-215200.md` — design rationale
- `knowledge/TROUBLESHOOTING.md` — past breakages + how they were fixed
- `knowledge/PAGER_ANQP_RSSI_TRACKER_SETUP.md` — full ANQP/Passpoint
  background (why wpad-wolfssl, why EAP-AKA', etc.)
- `knowledge/PASSPOINT_BEHAVIOR_DEEP_DIVE.md` — iOS four-state table,
  ANQP/HS2.0 wire format
- `knowledge/RADIUS-Step-By-Step.txt` — RADIUS protocol + iOS blacklist
  behavior
- `knowledge/EAP-SUCCESS+Bridging.txt` — Apple captive-portal
  trust chain (for connection mode)
- `knowledge/snapshot/PAGER-FACTORY-20260719-213352/` — pre-install
  byte-identical Pager state for full revert
