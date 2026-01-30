#!/usr/bin/env bash
################################################################################
#
#  MIVIA Rover - System Configuration Installation Script
#  File: reload_services.sh
#  Version: 1.0
#  Last Updated: January 2026
#
################################################################################
#
#  DESCRIPTION
#  -----------
#  Installation and update script for MIVIA Rover systemd services and runtime
#  configuration. Automates deployment of all system integration components.
#
#  FUNCTIONALITY
#  ----------
#  • Creates and manages /etc/mivia_rover directory structure
#  • Installs environment configuration with user-specific variables
#  • Deploys runtime scripts for rover bringup and network configuration
#  • Registers and enables systemd services (mivia-rover-platform, set-network)
#  • Performs systemd daemon reload and service restart
#  • Configures environment variables:
#      - MIVIA_ROVER_WS_PATH: Absolute workspace path
#      - MIVIA_ROVER_USER: Service execution user
#      - MIVIA_ROVER_HOME: User home directory
#      - ROS_DOMAIN_ID: ROS 2 domain ID (from environment or default)
#
#  USAGE
#  -----
#  ./reload_services.sh
#
#  PRIVILEGES
#  ----------
#  Executable without sudo; requests sudoers elevation at runtime via sudo.
#  User must have sudoers privileges for system directories.
#
#  DEPENDENCIES
#  -----------
#  • bash 4.0+
#  • systemctl (systemd)
#  • Standard Unix utilities (install, mkdir, rm, etc.)
#
#  EXIT CODES
#  ----------
#  0 - Successful installation/update
#  1 - Error during installation (see logs for details)
#
################################################################################

set -euo pipefail
IFS=$'\n\t'

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"

readonly INSTALL_ROOT="/etc/mivia_rover"
readonly INSTALL_ENV_DIR="${INSTALL_ROOT}/env"
readonly INSTALL_SCRIPTS_DIR="${INSTALL_ROOT}/scripts"
readonly INSTALL_ENV_FILE="${INSTALL_ENV_DIR}/mivia_rover.env"

readonly SRC_ENV_FILE="${SCRIPT_DIR}/env/mivia_rover.env"
readonly SRC_SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
readonly SRC_SYSTEMD_DIR="${SCRIPT_DIR}/systemd"

readonly SYSTEMD_TARGET_DIR="/etc/systemd/system"

readonly SERVICES=(
  "mivia-rover-platform.service"
  "set-network.service"
)

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

ensure_root_with_sudo() {
  # If not root, re-exec via sudo while preserving the identity of the invoking user.
  # Also preserve ROS_DOMAIN_ID if exported by the invoking user.
  if [ "${EUID}" -ne 0 ]; then
    if ! command_exists sudo; then
      die "sudo not found. Please install sudo or run this script as root."
    fi

    # Capture the invoking identity BEFORE elevation
    local inv_user
    inv_user="$(id -un)"

    # HOME should exist for interactive users, but be defensive
    local inv_home="${HOME:-}"
    if [ -z "${inv_home}" ]; then
      inv_home="$(getent passwd "${inv_user}" | awk -F: '{print $6}')"
    fi

    if [ -z "${inv_home}" ]; then
      die "Unable to determine HOME for user '${inv_user}'."
    fi

    export INVOKING_USER="${inv_user}"
    export INVOKING_HOME="${inv_home}"

    log "Requesting sudo elevation (invoking user: ${INVOKING_USER})..."
    exec sudo --preserve-env=INVOKING_USER,INVOKING_HOME,ROS_DOMAIN_ID bash "${SCRIPT_PATH}" "$@"
  fi
}

get_invoking_identity() {
  # When elevated, sudo sets SUDO_USER. However we prefer the variables preserved above.
  local inv_user="${INVOKING_USER:-}"
  local inv_home="${INVOKING_HOME:-}"

  if [ -z "${inv_user}" ]; then
    if [ -n "${SUDO_USER:-}" ]; then
      inv_user="${SUDO_USER}"
    else
      inv_user="root"
    fi
  fi

  if [ -z "${inv_home}" ]; then
    inv_home="$(getent passwd "${inv_user}" | awk -F: '{print $6}')"
  fi

  if [ -z "${inv_home}" ]; then
    die "Unable to determine HOME for invoking user '${inv_user}'."
  fi

  printf '%s\n%s\n' "${inv_user}" "${inv_home}"
}

find_workspace_root() {
  # Walk up from SCRIPT_DIR until basename == "mivia_rover"
  local cur="${SCRIPT_DIR}"
  while true; do
    if [ "$(basename "${cur}")" = "mivia_rover" ]; then
      printf '%s\n' "${cur}"
      return 0
    fi
    if [ "${cur}" = "/" ]; then
      break
    fi
    cur="$(dirname "${cur}")"
  done
  return 1
}

safe_rm_rf() {
  local path="$1"
  if [ -z "${path}" ] || [ "${path}" = "/" ] || [ "${path}" = "/etc" ]; then
    die "Refusing to delete unsafe path: '${path}'"
  fi
  rm -rf --one-file-system "${path}"
}

install_env() {
  [ -f "${SRC_ENV_FILE}" ] || die "Base env file not found: ${SRC_ENV_FILE}"

  local ws_root="$1"
  local inv_user="$2"
  local inv_home="$3"

  mkdir -p "${INSTALL_ENV_DIR}"
  cp -f "${SRC_ENV_FILE}" "${INSTALL_ENV_FILE}"

  # Ensure trailing newline
  if [ -s "${INSTALL_ENV_FILE}" ] && [ "$(tail -c 1 "${INSTALL_ENV_FILE}" | wc -c)" -ne 0 ]; then
    printf '\n' >> "${INSTALL_ENV_FILE}"
  fi

  # Helper: upsert KEY=VALUE (POSIX-ish)
  upsert_env_kv() {
    local key="$1"
    local val="$2"
    if grep -qE "^[[:space:]]*${key}=" "${INSTALL_ENV_FILE}"; then
      sed -i -E "s|^[[:space:]]*${key}=.*$|${key}=${val}|" "${INSTALL_ENV_FILE}"
    else
      printf '%s=%s\n' "${key}" "${val}" >> "${INSTALL_ENV_FILE}"
    fi
  }

  upsert_env_kv "MIVIA_ROVER_WS_PATH" "${ws_root}"
  upsert_env_kv "MIVIA_ROVER_USER" "${inv_user}"
  upsert_env_kv "MIVIA_ROVER_HOME" "${inv_home}"

  # ROS_DOMAIN_ID: capture from invoking environment if exported, else default to 0.
  # Accept only unsigned integer values to prevent unexpected content.
  if [ -n "${ROS_DOMAIN_ID:-}" ] && printf '%s' "${ROS_DOMAIN_ID}" | grep -qE '^[0-9]+$'; then
    upsert_env_kv "ROS_DOMAIN_ID" "${ROS_DOMAIN_ID}"
    log "Captured ROS_DOMAIN_ID=${ROS_DOMAIN_ID} from invoking environment."
  else
    upsert_env_kv "ROS_DOMAIN_ID" "0"
    log "ROS_DOMAIN_ID not exported/invalid in invoking environment. Defaulting to ROS_DOMAIN_ID=0."
  fi

  chmod 0644 "${INSTALL_ENV_FILE}"
  log "Installed env: ${INSTALL_ENV_FILE}"
}

install_scripts() {
  [ -d "${SRC_SCRIPTS_DIR}" ] || die "Scripts dir not found: ${SRC_SCRIPTS_DIR}"

  mkdir -p "${INSTALL_SCRIPTS_DIR}"
  cp -f "${SRC_SCRIPTS_DIR}/"*.sh "${INSTALL_SCRIPTS_DIR}/"

  chmod 0755 "${INSTALL_SCRIPTS_DIR}/"*.sh
  log "Installed scripts: ${INSTALL_SCRIPTS_DIR}"
}

render_unit_template() {
  # Renders a systemd unit template with @PLACEHOLDERS@
  local src="$1"
  local dst="$2"
  local ws_root="$3"
  local inv_user="$4"
  local inv_home="$5"

  # Basic validation: avoid empty substitutions
  [ -n "${ws_root}" ] || die "ws_root is empty"
  [ -n "${inv_user}" ] || die "inv_user is empty"
  [ -n "${inv_home}" ] || die "inv_home is empty"

  # Use sed with a delimiter unlikely to appear in paths
  sed \
    -e "s|@MIVIA_ROVER_WS_PATH@|${ws_root}|g" \
    -e "s|@MIVIA_ROVER_USER@|${inv_user}|g" \
    -e "s|@MIVIA_ROVER_HOME@|${inv_home}|g" \
    "${src}" > "${dst}"
}

install_systemd_units() {
  [ -d "${SRC_SYSTEMD_DIR}" ] || die "systemd dir not found: ${SRC_SYSTEMD_DIR}"

  if ! command_exists systemctl; then
    die "systemctl not found: systemd is required to manage services."
  fi

  for svc in "${SERVICES[@]}"; do
    local src="${SRC_SYSTEMD_DIR}/${svc}"
    local dst="${SYSTEMD_TARGET_DIR}/${svc}"

    [ -f "${src}" ] || die "Service unit not found: ${src}"

    # If the unit contains placeholders, render it; otherwise copy as-is.
    if grep -q "@MIVIA_ROVER_" "${src}"; then
      render_unit_template "${src}" "${dst}" "${WS_ROOT}" "${INV_USER}" "${INV_HOME}"
    else
      cp -f "${src}" "${dst}"
    fi

    chmod 0644 "${dst}"
    log "Installed unit: ${dst}"
  done

  systemctl daemon-reload

  for svc in "${SERVICES[@]}"; do
    systemctl enable "${svc}" >/dev/null
  done

  for svc in "${SERVICES[@]}"; do
    systemctl restart "${svc}"
    log "Restarted service: ${svc}"
  done
}

main() {
  ensure_root_with_sudo "$@"

  # We are root here
  local ident
  ident="$(get_invoking_identity)"
  INV_USER="$(printf '%s\n' "${ident}" | sed -n '1p')"
  INV_HOME="$(printf '%s\n' "${ident}" | sed -n '2p')"

  log "Invoking user detected: ${INV_USER}"
  log "Invoking home detected: ${INV_HOME}"

  if ! WS_ROOT="$(find_workspace_root)"; then
    die "Unable to locate workspace root named 'mivia_rover' by walking up from: ${SCRIPT_DIR}"
  fi
  log "Workspace root detected: ${WS_ROOT}"

  if [ -d "${INSTALL_ENV_DIR}" ]; then
    log "Removing previous env dir: ${INSTALL_ENV_DIR}"
    safe_rm_rf "${INSTALL_ENV_DIR}"
  fi

  if [ -d "${INSTALL_SCRIPTS_DIR}" ]; then
    log "Removing previous scripts dir: ${INSTALL_SCRIPTS_DIR}"
    safe_rm_rf "${INSTALL_SCRIPTS_DIR}"
  fi

  install_env "${WS_ROOT}" "${INV_USER}" "${INV_HOME}"
  install_scripts
  install_systemd_units

  log "Done."
}

main "$@"