#! bin/bash

source install/setup.bash
colcon build --symlink-install
ros2 launch mivia_rover_bringup launch.py

