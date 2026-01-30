# MIVIA Rover System Configuration

This module manages the installation and configuration of the automatic startup system for the MIVIA Rover. It provides tools to install systemd services that manage network initialization and rover bringup software launch.

## System Overview

The configuration system automates two main tasks:

1. **CAN Network Configuration**: Initializes the CAN interfaces (`can0`, `can1`) with appropriate parameters
2. **Rover Bringup Launch**: Starts the rover's main control software as a systemd service

The system is designed to:
- Simplify deployment on a robotic system
- Automatically start the rover at boot
- Provide a clean and reproducible installation
- Manage required environment variables

## File Structure

```
system_configuration/
├── README.md                          # This file
├── reload_services.sh                 # Installation/update script
├── uninstall_services.sh              # Uninstallation script
├── env/
│   └── mivia_rover.env               # Environment configuration (variables)
├── scripts/
│   ├── start_mivia_rover.sh          # Bringup entry point
│   └── set_network.sh                # CAN configuration script
└── systemd/
    ├── mivia-rover-platform.service  # Bringup service
    └── set-network.service           # Network configuration service
```

## Configuration Files

### `env/mivia_rover.env`

Contains the environment variables for rover runtime:

```dotenv
ROS_DISTRO=humble                          # ROS 2 distribution (humble, iron, etc.)
MIVIA_ENABLE_VIZ=false                     # Enable/disable visualization
MIVIA_BRINGUP_PACKAGE=mivia_rover_bringup # ROS package to launch
MIVIA_BRINGUP_LAUNCH=launch.py             # Launch file to execute
# RMW_IMPLEMENTATION=rmw_cyclonedds_cpp   # (optional) ROS 2 middleware
```

During installation, these values are automatically augmented with:
- `MIVIA_ROVER_WS_PATH`: Absolute path to the ROS workspace
- `MIVIA_ROVER_USER`: User running the service
- `MIVIA_ROVER_HOME`: User's home directory
- `ROS_DOMAIN_ID`: ROS domain ID (taken from environment, default 0)

### `scripts/set_network.sh`

Configures CAN interfaces for communication with rover hardware.

**Configurable parameters:**
```bash
IFACES=("can0" "can1")  # CAN interfaces to configure
BITRATE="1000000"       # Bitrate in bps (1 Mbps)
FD="off"                # CAN FD enabled (on/off)
```

**Behavior:**
- Brings down CAN interfaces
- Configures bitrate and CAN parameters
- Brings up the interfaces

### `scripts/start_mivia_rover.sh`

Entry point script for launching rover bringup.

**Functions:**
- Loads environment variables from `/etc/mivia_rover/env/mivia_rover.env`
- Verifies prerequisites (ROS, workspace, commands)
- Configures ROS variables (`ROS_DOMAIN_ID`, `RMW_IMPLEMENTATION`)
- Executes `ros2 launch` with specified parameters

**Parameters passed to launch:**
```bash
enable_mivia_rover_visualization:=<true|false>  # Controlled by MIVIA_ENABLE_VIZ
```

## Systemd Services

### `mivia-rover-platform.service`

Main service that starts rover bringup.

**Properties:**
- **Type**: Simple (foreground process)
- **Dependencies**: `set-network.service` (started AFTER)
- **User**: Runs as the user who executed the installation
- **Working Directory**: ROS workspace root
- **Restart**: On failure (RestartSec=2s)
- **TimeoutStop**: 15 seconds (with SIGINT)
- **Target**: Launched at boot (WantedBy=multi-user.target)

### `set-network.service`

CAN network pre-configuration service.

**Properties:**
- **Type**: Oneshot (executes once and terminates)
- **Boot phase**: Before `network-online.target`
- **Restart**: On failure
- **RemainAfterExit**: Remains active after execution
- **Target**: Launched at boot (WantedBy=multi-user.target)

## Installation

### Prerequisites

- Linux system with systemd
- Sudoers access (elevation is handled automatically by the script)
- ROS 2 installed in `/opt/ros/<distro>`
- ROS workspace compiled (with `colcon build`)
- CAN interfaces available on the system (or the service will fail gracefully)

### Installation Procedure

```bash
cd /home/alexios/Projects/mivia_rover/system_configuration
./reload_services.sh
```

The script:
1. Requests sudoers elevation if necessary
2. Creates directories `/etc/mivia_rover/env` and `/etc/mivia_rover/scripts`
3. Installs the customized environment configuration file
4. Installs runtime scripts
5. Installs systemd services
6. Executes `systemctl daemon-reload` and `systemctl enable` for both services
7. Starts the services

### Expected Output

```
[2026-01-29T12:34:56Z] Creating directory: /etc/mivia_rover/env
[2026-01-29T12:34:56Z] Installing base env file from: system_configuration/env/mivia_rover.env
[2026-01-29T12:34:56Z] Appending user-specific vars to env file...
[2026-01-29T12:34:56Z] Creating directory: /etc/mivia_rover/scripts
[2026-01-29T12:34:56Z] Installed script: /etc/mivia_rover/scripts/set_network.sh
[2026-01-29T12:34:56Z] Installed script: /etc/mivia_rover/scripts/start_mivia_rover.sh
[2026-01-29T12:34:56Z] Installing systemd unit: set-network.service
[2026-01-29T12:34:56Z] Installing systemd unit: mivia-rover-platform.service
[2026-01-29T12:34:56Z] Systemd daemon reloaded
[2026-01-29T12:34:56Z] Enabled service: set-network.service
[2026-01-29T12:34:56Z] Restarted service: set-network.service
[2026-01-29T12:34:56Z] Enabled service: mivia-rover-platform.service
[2026-01-29T12:34:56Z] Restarted service: mivia-rover-platform.service
[2026-01-29T12:34:56Z] Done.
```

## Usage

### Check Service Status

```bash
# Network configuration service status
systemctl status set-network.service

# Bringup service status
systemctl status mivia-rover-platform.service

# Both services
systemctl status set-network.service mivia-rover-platform.service
```

### View Logs

```bash
# Real-time logs
journalctl -u mivia-rover-platform.service -f

# Logs with context
journalctl -u mivia-rover-platform.service -n 50

# Startup logs
journalctl -u set-network.service -n 20
```

### Manually Control Services

```bash
# Start/restart bringup service
sudo systemctl restart mivia-rover-platform.service

# Stop the rover
sudo systemctl stop mivia-rover-platform.service

# Disable automatic boot startup
sudo systemctl disable mivia-rover-platform.service

# Re-enable automatic boot startup
sudo systemctl enable mivia-rover-platform.service
```

### Manual Script Execution

If necessary, scripts can be executed manually:

```bash
# Configure CAN network manually
sudo /etc/mivia_rover/scripts/set_network.sh

# Start bringup manually (loads env file automatically)
/etc/mivia_rover/scripts/start_mivia_rover.sh
```

## Update

To update the configuration after modifying files in this directory:

```bash
./reload_services.sh
```

The script automatically reconfigures everything, preserving the workspace path and user, while updating:
- Environment configuration file
- Runtime scripts
- Systemd services

No need to uninstall first.

## Uninstallation

To completely remove the configuration:

```bash
sudo system_configuration/uninstall_services.sh
```

The script:
1. Stops the services
2. Disables the services
3. Removes unit files from `/etc/systemd/system`
4. Removes directories `/etc/mivia_rover/env` and `/etc/mivia_rover/scripts`
5. Executes `systemctl daemon-reload`

After uninstallation, the system will no longer automatically start the rover at boot.

## Troubleshooting

### Bringup service fails at startup

**Diagnostics:**
```bash
journalctl -u mivia-rover-platform.service -n 100
```

**Common Causes:**

1. **Workspace not compiled**
   ```
   ERROR: ROS 2 overlay not found: /path/to/workspace/install/setup.bash
   ```
   Solution: `cd /home/alexios/Projects/mivia_rover && colcon build`

2. **ROS not installed**
   ```
   ERROR: ROS underlay not found: /opt/ros/humble/setup.bash
   ```
   Solution: Install ROS 2 in the correct directory

3. **Bringup package not found**
   ```
   ERROR: Package 'mivia_rover_bringup' not found
   ```
   Solution: Verify that `MIVIA_BRINGUP_PACKAGE` in `env/mivia_rover.env` is correct

4. **CAN interfaces not available**
   - The `set-network.sh` service fails silently if interfaces don't exist
   - For debugging: manually run `sudo /etc/mivia_rover/scripts/set_network.sh`

### Rover doesn't start at boot

1. Verify that services are enabled:
   ```bash
   systemctl is-enabled mivia-rover-platform.service
   systemctl is-enabled set-network.service
   ```

2. Re-enable them if necessary:
   ```bash
   sudo systemctl enable mivia-rover-platform.service
   sudo systemctl enable set-network.service
   ```

3. Check logs after reboot:
   ```bash
   journalctl --boot -u mivia-rover-platform.service
   ```

### Rover starts but stops immediately

Possible causes:
- Errors in the bringup launch file
- Hardware components not available
- Missing rover configuration files

Check logs for specific details.

## Obligations and Guidelines

### For Developers

1. **Script Changes**: If you modify files in `scripts/`, run `./reload_services.sh` to apply changes
2. **Environment Changes**: Update `env/mivia_rover.env` then run `./reload_services.sh`
3. **Service Changes**: Modify files in `systemd/` then run `./reload_services.sh`

### For Maintainers

1. **Backup**: Before making changes, backup `/etc/mivia_rover`
2. **Testing**: Test changes locally before deploying
3. **Version Control**: Keep track of changes in the VCS

### For Operators

1. **Do not modify** files in `/etc/mivia_rover` directly
2. **Use `reload_services.sh`** for updates
3. **Check logs** if the rover doesn't behave as expected
4. **Do not disable services** unless intentional

## Final Environment Variables

After installation, the system will have the following variables available at runtime:

| Variable | Source | Description |
|----------|--------|-------------|
| `MIVIA_ROVER_WS_PATH` | reload_services.sh | Absolute workspace path |
| `MIVIA_ROVER_USER` | reload_services.sh | User running the service |
| `MIVIA_ROVER_HOME` | reload_services.sh | User's home directory |
| `ROS_DOMAIN_ID` | reload_services.sh | ROS domain ID |
| `ROS_DISTRO` | mivia_rover.env | ROS 2 version |
| `MIVIA_ENABLE_VIZ` | mivia_rover.env | Visualization enablement |
| `MIVIA_BRINGUP_PACKAGE` | mivia_rover.env | Launch package |
| `MIVIA_BRINGUP_LAUNCH` | mivia_rover.env | Launch file |
| `RMW_IMPLEMENTATION` | mivia_rover.env | ROS middleware (optional) |

## Security

- The installation script requires sudoers privileges
- Services run as the local user (not as root)
- Scripts include safeguards to prevent dangerous operations (`rm -rf` on critical paths)
- Installed directories have appropriate permissions

## Support

For issues or questions about system configuration, contact the MIVIA Rover development team.
