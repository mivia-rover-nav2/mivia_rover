## Source Tree Structure

The project is organized into the following packages, each responsible for a specific subsystem:

- **mivia_rover_bringup**  
  Provides the main entrypoint for launching the entire system and coordinating all subsystems.

- **mivia_rover_description**  
  Contains the physical and kinematic description of the rover, including its URDF/Xacro models.

- **mivia_rover_localization**  
  Implements the rover localization pipeline and provides the necessary TF transformations.

- **mivia_rover_mapping**  
  Stores map assets and launches the mapping server, exposing the `/map` service.

- **mivia_rover_platform**  
  Provides the rover control layer, including low-level platform interfaces and motion control.

- **mivia_rover_sensing**  
  Contains the sensing stack and its subpackages, responsible for acquiring and publishing data from the rover’s sensors.
