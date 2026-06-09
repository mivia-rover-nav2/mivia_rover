# MiviaRover — `src/`

This directory holds the **ROS 2 Humble source tree** of the MiviaRover stack —
the high-level software that runs on the onboard Jetson AGX Orin and talks to the
custom STM32 firmware over CAN.

It is **not version-controlled directly**: it is populated by `vcs import` from
the [`mivia_rover.repos`](../mivia_rover.repos) manifest, which references the
individual per-package repositories under the
[mivia-rover-nav2](https://github.com/mivia-rover-nav2) GitHub organization. Each
top-level entry below is therefore its own git repository, and a few of them are
**multi-package repos** that nest their ROS 2 packages under a further `src/`.

> For the full project overview, hardware description, build, and onboard
> (`systemd`) deployment instructions, see the [top-level README](../README.md).

---

## License

Released under the [Apache License 2.0](../LICENSE). Packages imported via
[`mivia_rover.repos`](../mivia_rover.repos) may carry their own license; refer to
the `LICENSE` file inside each package directory.
