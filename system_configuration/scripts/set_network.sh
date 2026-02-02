#!/usr/bin/env bash
################################################################################
#
#  MIVIA Rover - Network Configuration Script
#  File: set_network.sh
#  Version: 1.1
#  Last Updated: February 2026
#
################################################################################

set -euo pipefail
IFS=$'\n\t'

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

normalize_bool() {
  local in="${1:-}"
  local lc
  lc="$(printf '%s' "$in" | tr '[:upper:]' '[:lower:]')"
  case "${lc}" in
    1|true|yes|y|on)  printf '%s' "true" ;;
    0|false|no|n|off|"") printf '%s' "false" ;;
    *) die "Invalid boolean value '${in}' (expected true/false, 1/0, yes/no, on/off)." ;;
  esac
}

################################################################################
# CAN configuration
################################################################################

configure_can() {
  local enable_can
  enable_can="$(normalize_bool "${ENABLE_CAN_BUS:-false}")"
  if [ "${enable_can}" != "true" ]; then
    log "CAN bringup disabled (ENABLE_CAN_BUS=false). Skipping CAN configuration."
    return 0
  fi

  local ip_bin
  ip_bin="$(command -v ip || true)"
  if [ -z "${ip_bin}" ] && [ -x /sbin/ip ]; then
    ip_bin="/sbin/ip"
  fi
  [ -n "${ip_bin}" ] || die "'ip' command not found (iproute2 missing?)."

  # Defaults (override via env if needed)
  local ifaces_csv="${CAN_IFACES:-can0,can1}"
  local bitrate="${CAN_BITRATE:-1000000}"  # 1 Mbps
  local fd="${CAN_FD:-off}"               # off|on

  # Split CSV into array
  local -a ifaces=()
  IFS=',' read -r -a ifaces <<< "${ifaces_csv}"

  log "Configuring CAN: ifaces='${ifaces_csv}', bitrate=${bitrate}, fd=${fd}"

  local iface
  for iface in "${ifaces[@]}"; do
    # Bring interface down (ignore if absent)
    "${ip_bin}" link set "${iface}" down >/dev/null 2>&1 || true

    if [ "${fd}" = "on" ]; then
      # Example FD line (dbitrate can be overridden)
      local dbitrate="${CAN_DBITRATE:-2000000}"
      "${ip_bin}" link set "${iface}" type can bitrate "${bitrate}" dbitrate "${dbitrate}" fd on
    else
      "${ip_bin}" link set "${iface}" type can bitrate "${bitrate}"
    fi

    "${ip_bin}" link set "${iface}" up
    log "Configured ${iface}: bitrate=${bitrate}, fd=${fd}"
  done
}

################################################################################
# WiFi configuration via NetworkManager (nmcli)
################################################################################

wifi_is_connected_to_ssid() {
  local ifname="${1:-}"
  local ssid="${2:-}"
  [ -n "${ifname}" ] || return 1
  [ -n "${ssid}" ] || return 1

  nmcli -t -f GENERAL.STATE dev show "${ifname}" 2>/dev/null | grep -q '^GENERAL.STATE:100' || return 1

  local con
  con="$(nmcli -t -f GENERAL.CONNECTION dev show "${ifname}" 2>/dev/null | cut -d':' -f2- || true)"
  [ -n "${con}" ] || return 1

  # In molte installazioni, GENERAL.CONNECTION è proprio l'SSID (o il "connection name").
  [ "${con}" = "${ssid}" ]
}

connect_wifi() {
  local wifi_enabled
  wifi_enabled="$(normalize_bool "${WIFI_AUTO_CONNECT:-false}")"
  if [ "${wifi_enabled}" != "true" ]; then
    log "WiFi auto-connect disabled (WIFI_AUTO_CONNECT=false). Skipping WiFi."
    return 0
  fi

  command_exists nmcli || die "nmcli not found. NetworkManager is required for WiFi auto-connect."

  local ssid="${WIFI_SSID:-}"
  local password="${WIFI_PASSWORD:-}"
  local timeout="${WIFI_TIMEOUT:-60}"
  local ifname="${WIFI_IFNAME:-wlo1}"

  # Le tue variabili nel .env includono le virgolette; bash le gestisce correttamente.
  [ -n "${ssid}" ] || die "WIFI_AUTO_CONNECT=true but WIFI_SSID is empty."
  [ -n "${password}" ] || die "WIFI_AUTO_CONNECT=true but WIFI_PASSWORD is empty."

  log "WiFi auto-connect: ifname='${ifname}', ssid='${ssid}', timeout=${timeout}s"

  # Ensure WiFi radio enabled
  nmcli radio wifi on >/dev/null 2>&1 || true

  # Fast path: already connected
  if wifi_is_connected_to_ssid "${ifname}" "${ssid}"; then
    log "Already connected to '${ssid}' on ${ifname}"
    return 0
  fi

  # Retry connect until timeout
  local elapsed=0
  local interval=2

  while [ "${elapsed}" -lt "${timeout}" ]; do
    # Try connect
    local out
    out="$(nmcli --wait 10 dev wifi connect "${ssid}" password "${password}" ifname "${ifname}" 2>&1)" || {
      log "nmcli connect attempt failed: ${out}"
    }

    # Re-check
    if wifi_is_connected_to_ssid "${ifname}" "${ssid}"; then
      log "Connected to '${ssid}' on ${ifname}"
      return 0
    fi

    log "Waiting for WiFi connection... (${elapsed}/${timeout}s)"
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  die "Failed to connect to '${ssid}' within ${timeout} seconds"
}

main() {
  # Order: CAN first (fast), then WiFi (may block up to WIFI_TIMEOUT)
  configure_can
  connect_wifi

  log "Network bringup completed successfully."
}

main "$@"
