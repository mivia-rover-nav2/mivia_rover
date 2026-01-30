#!/usr/bin/env bash
################################################################################
#
#  MIVIA Rover - CAN Network Configuration Script
#  File: set_network.sh
#  Version: 1.0
#  Last Updated: January 2026
#
################################################################################
#
#  DESCRIPTION
#  -----------
#  Configures CAN (Controller Area Network) interfaces for rover hardware
#  communication. Handles interface setup, bitrate configuration, and startup.
#
#  FUNCTIONALITY
#  ----------
#  • Detects and configures multiple CAN interfaces
#  • Sets CAN bitrate (default: 1 Mbps classic CAN)
#  • Optionally enables CAN FD mode with dual bitrates
#  • Brings interfaces down, configures, and brings them back up
#  • Validates iproute2 availability (ip command)
#  • Gracefully handles missing interfaces without failure
#
#  CONFIGURABLE PARAMETERS
#  -----------------------
#  IFACES=("can0" "can1")  - CAN interfaces to configure (edit as needed)
#  BITRATE="1000000"       - Bitrate in bps (1 Mbps default for classic CAN)
#  FD="off"                - CAN FD mode: "off" (classic) or "on" (CAN FD)
#  MTU=<value>             - (Optional) Maximum transmission unit override
#
#  USAGE
#  -----
#  # Via systemd (automatic during boot)
#  systemctl start set-network.service
#
#  # Manual execution (with sudo)
#  sudo /etc/mivia_rover/scripts/set_network.sh
#
#  EXECUTION CONTEXT
#  -----------------
#  Typically runs as oneshot systemd service before rover bringup.
#  Can be executed manually for testing or reconfiguration.
#  Failures are non-critical (rover can run without CAN if not needed).
#
#  DEPENDENCIES
#  -----------
#  • bash 4.0+
#  • iproute2 package (ip command)
#  • Linux kernel with CAN support
#  • CAN hardware/virtual interfaces on system
#
#  EXIT CODES
#  ----------
#  0 - All configured interfaces set up successfully
#  1 - Critical error (ip binary not found, invalid configuration, etc.)
#
################################################################################

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
