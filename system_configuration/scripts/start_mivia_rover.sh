#!/usr/bin/env bash
# ==============================================================================
# start_mivia_rover.sh
#
# Entry point for MIVIA Rover platform bringup.
# Designed to be executed by systemd (EnvironmentFile already loaded),
# but also runnable manually (will source /etc/mivia_rover/env/mivia_rover.env).
# ==============================================================================

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
