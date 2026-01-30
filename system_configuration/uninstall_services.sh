#!/usr/bin/env bash
################################################################################
#
#  MIVIA Rover - System Configuration Uninstallation Script
#  File: uninstall_services.sh
#  Version: 1.0
#  Last Updated: January 2026
#
################################################################################
#
#  DESCRIPTION
#  -----------
#  Cleanup and removal script for MIVIA Rover systemd services and runtime
#  configuration. Safely removes all installed system components.
#
#  FUNCTIONALITY
#  ----------
#  • Gracefully stops running systemd services
#  • Disables service autostart at boot
#  • Removes service unit files from /etc/systemd/system
#  • Deletes runtime configuration directory (/etc/mivia_rover/env)
#  • Deletes runtime scripts directory (/etc/mivia_rover/scripts)
#  • Performs systemd daemon reload
#  • Includes safeguards against dangerous filesystem operations
#
#  USAGE
#  -----
#  sudo ./uninstall_services.sh
#
#  PRIVILEGES
#  ----------
#  MUST be executed with sudo/root privileges. Script enforces this check.
#  Operating on system directories requires administrative access.
#
#  DEPENDENCIES
#  -----------
#  • bash 4.0+
#  • systemctl (systemd)
#  • Standard Unix utilities (rm, rmdir, etc.)
#  • Root/sudo access
#
#  EXIT CODES
#  ----------
#  0 - Successful uninstallation
#  1 - Error during uninstallation (permission denied, invalid path, etc.)
#
#  SAFETY
#  ------
#  • Validates all removal paths before deletion
#  • Refuses to delete critical system directories (/, /etc, etc.)
#  • Uses rm --one-file-system to prevent cross-filesystem accidents
#  • Logs all operations with timestamps
#
################################################################################

set -euo pipefail
IFS=$'\n\t'

readonly INSTALL_ROOT="/etc/mivia_rover"
readonly INSTALL_ENV_DIR="${INSTALL_ROOT}/env"
readonly INSTALL_SCRIPTS_DIR="${INSTALL_ROOT}/scripts"
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

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    die "This script must be run as root (use sudo)."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

safe_rm_rf() {
  local path="$1"
  if [ -z "$path" ] || [ "$path" = "/" ] || [ "$path" = "/etc" ]; then
    die "Refusing to delete unsafe path: '$path'"
  fi
  rm -rf --one-file-system "$path"
}

remove_systemd_units() {
  if command_exists systemctl; then
    for svc in "${SERVICES[@]}"; do
      # Stop/disable gracefully even if not installed
      systemctl stop "$svc" >/dev/null 2>&1 || true
      systemctl disable "$svc" >/dev/null 2>&1 || true
      log "Stopped/disabled service (if present): $svc"
    done
  fi

  for svc in "${SERVICES[@]}"; do
    local dst="${SYSTEMD_TARGET_DIR}/${svc}"
    if [ -f "$dst" ]; then
      rm -f "$dst"
      log "Removed unit: $dst"
    fi
  done

  if command_exists systemctl; then
    systemctl daemon-reload
  fi
}

main() {
  require_root

  remove_systemd_units

  if [ -d "$INSTALL_ENV_DIR" ]; then
    safe_rm_rf "$INSTALL_ENV_DIR"
    log "Removed: $INSTALL_ENV_DIR"
  fi

  if [ -d "$INSTALL_SCRIPTS_DIR" ]; then
    safe_rm_rf "$INSTALL_SCRIPTS_DIR"
    log "Removed: $INSTALL_SCRIPTS_DIR"
  fi

  # Optionally remove the root directory if empty
  if [ -d "$INSTALL_ROOT" ] && [ -z "$(ls -A "$INSTALL_ROOT" 2>/dev/null || true)" ]; then
    rmdir "$INSTALL_ROOT" || true
    log "Removed empty dir: $INSTALL_ROOT"
  fi

  log "Done."
}

main "$@"