#!/usr/bin/env bash
# Minimal CAN setup script (classic CAN @ 1Mbps, FD off)
# Edit IFACES and BITRATE as needed.

set -euo pipefail

# --- User-editable defaults ---
IFACES=("can0" "can1")   # <- change if needed
BITRATE="1000000"       # 1 Mbps
FD="off"                # "off" (classic CAN) or "on" (CAN FD)

# MTU can be set by uncommenting and setting a value:
# MTU="6000"

# Try to locate ip binary (fallback to /sbin/ip)
IP_BIN="$(command -v ip || true)"
if [ -z "${IP_BIN}" ] && [ -x /sbin/ip ]; then
  IP_BIN="/sbin/ip"
fi
if [ -z "${IP_BIN}" ]; then
  echo "ERROR: 'ip' command not found (iproute2 missing?)." >&2
  exit 127
fi

for IFACE in "${IFACES[@]}"; do
  # Bring interface down (ignore if absent)
  "${IP_BIN}" link set "${IFACE}" down || true

  if [ "${FD}" = "on" ]; then
    # Example FD line (adjust dbitrate if you enable FD)
    "${IP_BIN}" link set "${IFACE}" type can bitrate "${BITRATE}" dbitrate 2000000 fd on
  else
    # Classic CAN
    "${IP_BIN}" link set "${IFACE}" type can bitrate "${BITRATE}"
  fi

  "${IP_BIN}" link set "${IFACE}" up
  echo "Configured ${IFACE}: bitrate=${BITRATE}, FD=${FD}"
done
