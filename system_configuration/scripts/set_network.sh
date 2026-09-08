#!/usr/bin/env bash
################################################################################
#
#  MIVIA Rover - Network Configuration Script
#  File: set_network.sh
#  Version: 1.3
#  Last Updated: September 2026
#
################################################################################

set -euo pipefail
IFS=$'\n\t'

################################################################################
# Logging / utilities
################################################################################

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
  lc="$(printf '%s' "${in}" | tr '[:upper:]' '[:lower:]')"
  case "${lc}" in
    1|true|yes|y|on)         printf '%s' "true" ;;
    0|false|no|n|off|"")     printf '%s' "false" ;;
    *) die "Invalid boolean value '${in}' (expected true/false, 1/0, yes/no, on/off)." ;;
  esac
}

is_uint() {
  # returns 0 if $1 is a non-empty string of digits
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

################################################################################
# CAN configuration
################################################################################

_can_get_ip_bin() {
  local ip_bin
  ip_bin="$(command -v ip || true)"
  if [ -z "${ip_bin}" ] && [ -x /sbin/ip ]; then
    ip_bin="/sbin/ip"
  fi
  [ -n "${ip_bin}" ] || die "'ip' command not found (iproute2 missing?)."
  printf '%s' "${ip_bin}"
}

_can_iface_exists() {
  # Check existence in sysfs; iproute2 "link show" can also work but is noisier.
  local iface="${1:-}"
  [ -n "${iface}" ] || return 1
  [ -d "/sys/class/net/${iface}" ]
}

configure_can() {
  local enable_can
  enable_can="$(normalize_bool "${ENABLE_CAN_BUS:-false}")"
  if [ "${enable_can}" != "true" ]; then
    log "CAN bringup disabled (ENABLE_CAN_BUS=false). Skipping CAN configuration."
    return 0
  fi

  local ip_bin
  ip_bin="$(_can_get_ip_bin)"

  # Defaults (override via env if needed)
  local ifaces_csv="${CAN_IFACES:-can0,can1}"
  local bitrate="${CAN_BITRATE:-1000000}"  # 1 Mbps
  local fd="${CAN_FD:-off}"               # off|on
  local dbitrate="${CAN_DBITRATE:-2000000}" # only used if fd=on

  is_uint "${bitrate}" || die "CAN_BITRATE must be an unsigned integer (got '${bitrate}')."
  if [ "${fd}" != "on" ] && [ "${fd}" != "off" ]; then
    die "CAN_FD must be 'on' or 'off' (got '${fd}')."
  fi
  if [ "${fd}" = "on" ]; then
    is_uint "${dbitrate}" || die "CAN_DBITRATE must be an unsigned integer (got '${dbitrate}')."
  fi

  log "Configuring CAN: ifaces='${ifaces_csv}', bitrate=${bitrate}, fd=${fd}"

  # Parse CSV without relying on global IFS
  local IFS_LOCAL=','
  local -a ifaces=()
  # shellcheck disable=SC2162
  IFS="${IFS_LOCAL}" read -r -a ifaces <<< "${ifaces_csv}"

  local iface
  for iface in "${ifaces[@]}"; do
    # Trim possible spaces around tokens (defensive)
    iface="$(printf '%s' "${iface}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "${iface}" ] || continue

    if ! _can_iface_exists "${iface}"; then
      log "CAN iface '${iface}' not found in /sys/class/net. Skipping."
      continue
    fi

    # Bring interface down (ignore failures)
    "${ip_bin}" link set "${iface}" down >/dev/null 2>&1 || true

    if [ "${fd}" = "on" ]; then
      "${ip_bin}" link set "${iface}" type can bitrate "${bitrate}" dbitrate "${dbitrate}" fd on
    else
      "${ip_bin}" link set "${iface}" type can bitrate "${bitrate}"
    fi

    "${ip_bin}" link set "${iface}" up
    log "Configured ${iface}: bitrate=${bitrate}, fd=${fd}"
  done
}

################################################################################
# Velodyne VLP-16 LiDAR wired network
################################################################################

configure_lidar_net() {
  # The VLP-16 is an Ethernet sensor: it streams UDP from a fixed IP
  # (LIDAR_DEVICE_IP, factory default 192.168.1.201) and the host NIC it is
  # wired to must carry a static address in the same subnet. We install a
  # persistent NetworkManager profile ("mivia-lidar") so the address survives
  # reboots and link flaps, mirroring how WiFi is handled below.
  local enable_lidar
  enable_lidar="$(normalize_bool "${ENABLE_LIDAR_NET:-false}")"
  if [ "${enable_lidar}" != "true" ]; then
    log "LiDAR network disabled (ENABLE_LIDAR_NET=false). Skipping LiDAR network configuration."
    return 0
  fi

  local iface="${LIDAR_IFACE:-eth0}"
  local host_ip="${LIDAR_HOST_IP:-192.168.1.100/24}"
  local con_name="${LIDAR_CONNECTION_NAME:-mivia-lidar}"

  # host_ip must be CIDR (addr/prefix) - nmcli ipv4.addresses wants the prefix.
  case "${host_ip}" in
    */[0-9]*) : ;;
    *) die "LIDAR_HOST_IP must be in CIDR notation (e.g. 192.168.1.100/24), got '${host_ip}'." ;;
  esac

  command_exists nmcli || die "nmcli not found. NetworkManager is required for LiDAR network configuration."

  if [ ! -d "/sys/class/net/${iface}" ]; then
    log "LiDAR iface '${iface}' not found in /sys/class/net. Skipping LiDAR network configuration."
    return 0
  fi

  log "Configuring LiDAR network: iface='${iface}', host_ip='${host_ip}', profile='${con_name}'"

  # The Jetson AGX Orin's Aquantia AQR113C PHY (10G, no phy_mode in the device
  # tree) does not auto-negotiate a link with the 100 Mbit/s VLP-16 on the
  # first try: the interface stays NO-CARRIER until it is bounced. Kick it and
  # wait (best effort) for the carrier before handing over to NetworkManager.
  local ip_bin
  ip_bin="$(_can_get_ip_bin)"
  "${ip_bin}" link set "${iface}" down >/dev/null 2>&1 || true
  sleep 1
  "${ip_bin}" link set "${iface}" up >/dev/null 2>&1 || true

  local waited=0
  while [ "${waited}" -lt 15 ]; do
    if [ "$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)" = "1" ]; then
      log "LiDAR iface '${iface}' link is up after ${waited}s."
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)" != "1" ]; then
    log "LiDAR iface '${iface}' still NO-CARRIER after ${waited}s (sensor off/unplugged?). Applying config anyway; NM will connect when the link comes up."
  fi

  if nmcli -t -f NAME con show 2>/dev/null | grep -Fqx "${con_name}"; then
    nmcli con mod "${con_name}" \
      connection.interface-name "${iface}" \
      ipv4.method manual \
      ipv4.addresses "${host_ip}" \
      ipv4.gateway "" \
      ipv4.never-default yes \
      ipv6.method disabled
  else
    nmcli con add type ethernet con-name "${con_name}" ifname "${iface}" \
      ipv4.method manual \
      ipv4.addresses "${host_ip}" \
      ipv4.never-default yes \
      ipv6.method disabled \
      connection.autoconnect yes
  fi

  # (Re)activate so the address is live now, not only after the next boot.
  nmcli con up "${con_name}" ifname "${iface}" >/dev/null 2>&1 \
    || log "Could not bring up '${con_name}' now (is the LiDAR/cable connected?). It will auto-connect when the link is up."

  log "LiDAR network configured on ${iface} (${host_ip})."
}

################################################################################
# WiFi configuration via NetworkManager (nmcli)
################################################################################

wifi_is_connected() {
  # Predicate: device is in "connected" state
  local ifname="${1:-}"
  [ -n "${ifname}" ] || return 1
  nmcli -t -f GENERAL.STATE dev show "${ifname}" 2>/dev/null | grep -q '^GENERAL.STATE:100'
}

wifi_get_active_ssid() {
  # Returns the SSID currently ACTIVE on the given interface (empty if none).
  # This uses the WiFi scan list with ACTIVE flag; it is more robust than GENERAL.CONNECTION.
  local ifname="${1:-}"
  [ -n "${ifname}" ] || return 1

  nmcli -t -f ACTIVE,SSID dev wifi list ifname "${ifname}" 2>/dev/null \
    | awk -F: '$1=="yes"{print $2; exit 0}'
}

wifi_is_connected_to_ssid() {
  # Predicate: connected AND active SSID matches expected value.
  local ifname="${1:-}"
  local ssid="${2:-}"
  [ -n "${ifname}" ] || return 1
  [ -n "${ssid}" ] || return 1

  wifi_is_connected "${ifname}" || return 1

  local active_ssid
  active_ssid="$(wifi_get_active_ssid "${ifname}" || true)"
  [ -n "${active_ssid}" ] || return 1

  [ "${active_ssid}" = "${ssid}" ]
}

wifi_disconnect_if_wrong_ssid() {
  # Policy/action: if connected to a different SSID, disconnect.
  local ifname="${1:-}"
  local expected_ssid="${2:-}"
  [ -n "${ifname}" ] || return 1
  [ -n "${expected_ssid}" ] || return 1

  if ! wifi_is_connected "${ifname}"; then
    return 0
  fi

  local current_ssid
  current_ssid="$(wifi_get_active_ssid "${ifname}" || true)"
  if [ -n "${current_ssid}" ] && [ "${current_ssid}" != "${expected_ssid}" ]; then
    log "Connected to unexpected SSID '${current_ssid}' on ${ifname}. Disconnecting..."
    nmcli dev disconnect "${ifname}" >/dev/null 2>&1 || true
  fi

  return 0
}

wifi_try_up_profile() {
  # Deterministic path: bring up an existing NM connection profile.
  # Returns 0 if profile was activated (or already active), 1 otherwise.
  local con_name="${1:-}"
  local ifname="${2:-}"
  [ -n "${con_name}" ] || return 1
  [ -n "${ifname}" ] || return 1

  # If already active, success
  nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep -Fqx "${con_name}:${ifname}" && return 0

  # Try to activate (does not require password in command line if stored in profile)
  nmcli --wait 10 con up "${con_name}" ifname "${ifname}" >/dev/null 2>&1
}

wifi_try_connect_ssid() {
  # Pragmatic path: connect by SSID/password; may create/modify profiles.
  local ssid="${1:-}"
  local password="${2:-}"
  local ifname="${3:-}"
  [ -n "${ssid}" ] || return 1
  [ -n "${password}" ] || return 1
  [ -n "${ifname}" ] || return 1

  nmcli --wait 10 dev wifi connect "${ssid}" password "${password}" ifname "${ifname}" >/dev/null 2>&1
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

  # Optional: use a deterministic connection profile if provided
  # (Recommended in production: profile has stored PSK, priority, etc.)
  local con_name="${WIFI_CONNECTION_NAME:-}"

  [ -n "${ssid}" ] || die "WIFI_AUTO_CONNECT=true but WIFI_SSID is empty."
  # If profile name is provided, password may be unnecessary (stored in profile).
  if [ -z "${con_name}" ]; then
    [ -n "${password}" ] || die "WIFI_AUTO_CONNECT=true but WIFI_PASSWORD is empty (and WIFI_CONNECTION_NAME not set)."
  fi
  is_uint "${timeout}" || die "WIFI_TIMEOUT must be an unsigned integer (got '${timeout}')."

  log "WiFi auto-connect: ifname='${ifname}', ssid='${ssid}', timeout=${timeout}s"

  # Ensure WiFi radio enabled
  nmcli radio wifi on >/dev/null 2>&1 || true

  # Fast path
  if wifi_is_connected_to_ssid "${ifname}" "${ssid}"; then
    log "Already connected to '${ssid}' on ${ifname}"
    return 0
  fi

  # If connected to a different SSID, disconnect explicitly before attempts
  wifi_disconnect_if_wrong_ssid "${ifname}" "${ssid}"

  local elapsed=0
  local interval=2

  while [ "${elapsed}" -lt "${timeout}" ]; do
    if [ -n "${con_name}" ]; then
      if wifi_try_up_profile "${con_name}" "${ifname}"; then
        :
      else
        log "nmcli profile activation failed: connection='${con_name}', ifname='${ifname}'"
      fi
    else
      if wifi_try_connect_ssid "${ssid}" "${password}" "${ifname}"; then
        :
      else
        log "nmcli SSID connect attempt failed: ssid='${ssid}', ifname='${ifname}'"
      fi
    fi

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

################################################################################
# Main
################################################################################

main() {
  # Order: CAN first (fast), then LiDAR static IP, then WiFi (may block up to WIFI_TIMEOUT)
  configure_can
  configure_lidar_net
  connect_wifi
  log "Network bringup completed successfully."
}

main "$@"