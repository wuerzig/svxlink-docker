#!/bin/sh
# ---------------------------------------------------------------------------
# djspot-set-freq.sh
#
# Programs the DJspot HAT's SA818-class module (Beken 81BK clone) over its
# CH341 UART, so the radio is tuned to the right frequency before svxlink
# starts. The module is "sticky" (it keeps the last programmed frequency
# across power cycles), so this only needs to run once at container start.
#
# svxlink itself has no driver for this module; it only drives the CM108B
# (ALSA audio + HID PTT/COS). This script fills the one remaining gap.
#
# The DJspot exposes TWO identical CH341 UARTs (VID:PID 1a86:7522) that are
# indistinguishable by VID/PID, so we auto-detect the SA818 port by sending
# AT+DMOCONNECT and keeping the one that replies "+DMOCONNECT:0".
#
# Failure here is non-fatal: svxlink is still started, and the module keeps
# whatever frequency it was last programmed with.
# ---------------------------------------------------------------------------
set -u

# --- Configuration (all overridable via environment / docker-compose) -------
# Frequencies in MHz; formatted to 4 decimals (e.g. 440.0250) before sending.
DJSPOT_TX_FREQ="${DJSPOT_TX_FREQ:-433.1250}"
DJSPOT_RX_FREQ="${DJSPOT_RX_FREQ:-433.1250}"
# Bandwidth: 0 = 12.5 kHz (narrow), 1 = 25 kHz (wide).
# The 81BK SA818 clone on the DJspot is 12.5 kHz only and NAKs wide (GBW=1).
DJSPOT_BW="${DJSPOT_BW:-0}"
# CTCSS index as a PLAIN integer in this clone's dialect (e.g. 18); 0 = no tone.
# NOT the classic SA818 zero-padded "0000" form, which this module NAKs.
DJSPOT_TX_CTCSS="${DJSPOT_TX_CTCSS:-0}"
DJSPOT_RX_CTCSS="${DJSPOT_RX_CTCSS:-0}"
# Squelch level 0-8. NOTE: 0 = monitor/always-open on this clone; use >=1.
DJSPOT_SQL="${DJSPOT_SQL:-4}"
# 7th DMOSETGROUP field used by this clone's dialect (per AT-Radio.txt),
# reportedly TX power 1=high/0=low. Leave EMPTY only to fall back to a plain
# 6-field command.
DJSPOT_POWER="${DJSPOT_POWER:-1}"
# Optional audio seeds; leave empty to skip. VOLUME 1-8.
DJSPOT_VOLUME="${DJSPOT_VOLUME:-}"
# Candidate serial ports; override to pin a device and skip the glob.
DJSPOT_SERIAL="${DJSPOT_SERIAL:-}"

log() { echo "[$(date -Iseconds)] djspot-set-freq: $*"; }

# Configure a port for the module: 9600 8N1, no flow control, raw, with a
# ~1s read timeout (min 0 time 10) so reads return instead of blocking.
configure_port() {
  stty -F "$1" 9600 cs8 -cstopb -parenb -icanon -echo -onlcr -icrnl \
       -ixon -ixoff -crtscts min 0 time 10 2>/dev/null
}

# query <dev> <command> <wait_seconds> -> prints collected response
# Opens the port read/write on fd 3, writes "<cmd>\r\n", then reads for up to
# <wait_seconds> (cat is killed by timeout, printing whatever it received).
query() {
  _dev="$1"; _cmd="$2"; _wait="${3:-2}"
  { exec 3<>"$_dev"; } 2>/dev/null || return 1
  printf '%s\r\n' "$_cmd" >&3
  _resp="$(timeout "$_wait" cat <&3 2>/dev/null)"
  exec 3>&- 3<&- 2>/dev/null || true
  printf '%s' "$_resp"
}

# --- Find the SA818 port -----------------------------------------------------
if [ -n "$DJSPOT_SERIAL" ]; then
  candidates="$DJSPOT_SERIAL"
else
  candidates="$(ls /dev/ttyUSB* 2>/dev/null)"
fi

if [ -z "$candidates" ]; then
  log "no CH341 serial ports found (mapped into the container?); skipping."
  exit 0
fi

SA818_DEV=""
for dev in $candidates; do
  [ -c "$dev" ] || continue
  configure_port "$dev" || continue
  resp="$(query "$dev" "AT+DMOCONNECT" 2)"
  case "$resp" in
    *DMOCONNECT:0*)
      SA818_DEV="$dev"
      log "SA818 detected on $dev"
      break
      ;;
    *)
      log "no SA818 handshake on $dev (ignored)"
      ;;
  esac
done

if [ -z "$SA818_DEV" ]; then
  log "no SA818 responded to AT+DMOCONNECT; leaving module at last (sticky) setting."
  exit 0
fi

# --- Program frequency -------------------------------------------------------
TXF="$(printf '%.4f' "$DJSPOT_TX_FREQ")"
RXF="$(printf '%.4f' "$DJSPOT_RX_FREQ")"
GROUP="AT+DMOSETGROUP=${DJSPOT_BW},${TXF},${RXF},${DJSPOT_TX_CTCSS},${DJSPOT_SQL},${DJSPOT_RX_CTCSS}"
# Append the optional 7th field only when explicitly requested.
[ -n "$DJSPOT_POWER" ] && GROUP="${GROUP},${DJSPOT_POWER}"

log "sending: $GROUP"
# PLL retune can take ~2s on this clone, so allow 3s for the reply.
resp="$(query "$SA818_DEV" "$GROUP" 3)"
case "$resp" in
  *DMOSETGROUP:0*)
    log "frequency programmed OK (tx=$TXF rx=$RXF bw=$DJSPOT_BW sql=$DJSPOT_SQL power=$DJSPOT_POWER)."
    ;;
  *DMOSETGROUP:1*)
    log "module REJECTED the setting (DMOSETGROUP:1) - check freq/band limits. resp=[$resp]"
    ;;
  *)
    log "no/unexpected ack for DMOSETGROUP: resp=[$resp]"
    ;;
esac

# --- Optional audio seeds ----------------------------------------------------
if [ -n "$DJSPOT_VOLUME" ]; then
  vresp="$(query "$SA818_DEV" "AT+DMOSETVOLUME=${DJSPOT_VOLUME}" 2)"
  log "DMOSETVOLUME=${DJSPOT_VOLUME} -> [$vresp]"
fi

exit 0
