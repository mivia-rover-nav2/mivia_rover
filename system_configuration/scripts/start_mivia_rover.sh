#!/usr/bin/env bash
################################################################################
#
#  MIVIA Rover - Bringup Startup Script
#  File: start_mivia_rover.sh
#  Version: 1.0
#  Last Updated: January 2026
#
################################################################################
#
#  DESCRIPTION
#  -----------
#  Entry point for MIVIA Rover platform bringup. Manages environment setup,
#  ROS 2 configuration, and launch of the rover's main control system.
#
#  FUNCTIONALITY
#  ----------
#  • Loads runtime environment variables from /etc/mivia_rover/env/mivia_rover.env
#  • Validates prerequisites (workspace, ROS installation, required commands)
#  • Sources ROS 2 underlay from /opt/ros/<ROS_DISTRO>/setup.bash
#  • Sources ROS 2 overlay from workspace install/setup.bash
#  • Configures ROS environment variables (ROS_DOMAIN_ID, RMW_IMPLEMENTATION)
#  • Launches rover bringup package via ros2 launch command
#  • Passes visualization enablement flag based on MIVIA_ENABLE_VIZ variable
#
#  EXECUTION CONTEXTS
#  ------------------
#  1. Via systemd: Environment already loaded, works seamlessly
#  2. Manual execution: Auto-sources environment file from default location
#
#  USAGE
#  -----
#  # Via systemd (automatic at boot)
#  systemctl start mivia-rover-platform.service
#
#  # Manual execution
#  /etc/mivia_rover/scripts/start_mivia_rover.sh
#
#  ENVIRONMENT VARIABLES
#  ---------------------
#  Required:
#    MIVIA_ROVER_WS_PATH       - Absolute path to ROS workspace
#    MIVIA_BRINGUP_PACKAGE     - ROS 2 package name for bringup
#    MIVIA_BRINGUP_LAUNCH      - Launch file name (e.g., launch.py)
#    ROS_DISTRO                - ROS 2 distribution name (humble, iron, etc.)
#
#  Optional:
#    ROS_DOMAIN_ID             - ROS domain identifier (default: 0)
#    RMW_IMPLEMENTATION        - DDS implementation (cyclonedds, fastdds, etc.)
#    MIVIA_ENABLE_VIZ          - Visualization flag (true/false, default: false)
#
#  EXIT CODES
#  ----------
#  0 - Rover running (normal systemd behavior: exec replaces process)
#  1 - Initialization error (validation failed, missing dependencies, etc.)
#
################################################################################

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_ENV_FILE="/etc/mivia_rover/env/mivia_rover.env"

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

safe_source() {
  # Source scripts that may reference unset vars (colcon/ament can do this).
  # shellcheck disable=SC1090
  set +u
  # shellcheck disable=SC1090
  source "$1"
  set -u
}

normalize_bool() {
  local in="${1:-}"
  local lc
  lc="$(printf '%s' "$in" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    1|true|yes|y|on) printf '%s' "true" ;;
    0|false|no|n|off|"") printf '%s' "false" ;;
    *) die "Invalid boolean value '${in}' for MIVIA_ENABLE_VIZ (expected true/false, 1/0, yes/no, on/off)." ;;
  esac
}

source_env_if_needed() {
  if [ -z "${MIVIA_ROVER_WS_PATH:-}" ] || \
     [ -z "${MIVIA_BRINGUP_PACKAGE:-}" ] || \
     [ -z "${MIVIA_BRINGUP_LAUNCH:-}" ]; then

    [ -f "${DEFAULT_ENV_FILE}" ] || die "Missing env file at: ${DEFAULT_ENV_FILE}"

    set -a
    # shellcheck disable=SC1090
    source "${DEFAULT_ENV_FILE}"
    set +a
    log "Sourced env file: ${DEFAULT_ENV_FILE}"
  fi
}

source_ros_environment() {
  # Underlay
  if [ -n "${ROS_DISTRO:-}" ]; then
    local underlay="/opt/ros/${ROS_DISTRO}/setup.bash"
    [ -f "${underlay}" ] || die "ROS underlay not found: ${underlay}"
    safe_source "${underlay}"
  else
    # Fallback: try to pick the first /opt/ros/* (useful if single distro installed)
    local first_ros_dir
    first_ros_dir="$(ls -1d /opt/ros/* 2>/dev/null | head -n 1 || true)"
    [ -n "${first_ros_dir}" ] || die "ROS_DISTRO not set and no /opt/ros/<distro> found."
    [ -f "${first_ros_dir}/setup.bash" ] || die "ROS underlay not found: ${first_ros_dir}/setup.bash"
    safe_source "${first_ros_dir}/setup.bash"
  fi

  # Overlay
  local setup_file="${MIVIA_ROVER_WS_PATH}/install/setup.bash"
  [ -f "${setup_file}" ] || die "ROS 2 overlay not found: ${setup_file}. Did you build with colcon?"
  safe_source "${setup_file}"
}

main() {
  source_env_if_needed

  [ -n "${MIVIA_ROVER_WS_PATH:-}" ] || die "MIVIA_ROVER_WS_PATH is not set."
  [ -d "${MIVIA_ROVER_WS_PATH}" ] || die "Workspace path does not exist: ${MIVIA_ROVER_WS_PATH}"

  # Optional ROS environment knobs from env
  if [ -n "${ROS_DOMAIN_ID:-}" ]; then
    export ROS_DOMAIN_ID
  fi
  if [ -n "${RMW_IMPLEMENTATION:-}" ]; then
    export RMW_IMPLEMENTATION
  fi

  # Bringup parameters
  local bringup_pkg="${MIVIA_BRINGUP_PACKAGE}"
  local bringup_launch="${MIVIA_BRINGUP_LAUNCH}"
  local viz_bool
  viz_bool="$(normalize_bool "${MIVIA_ENABLE_VIZ:-false}")"

  cd "${MIVIA_ROVER_WS_PATH}"

  # Source ROS underlay+overlay BEFORE checking ros2
  source_ros_environment

  if ! command_exists ros2; then
    die "'ros2' command not found even after sourcing ROS underlay/overlay."
  fi

  log "Launching bringup: pkg='${bringup_pkg}', launch='${bringup_launch}', enable_mivia_rover_visualization:=${viz_bool}"
  exec ros2 launch "${bringup_pkg}" "${bringup_launch}" "enable_mivia_rover_visualization:=${viz_bool}"
}

main "$@"
