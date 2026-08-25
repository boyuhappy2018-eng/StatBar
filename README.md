# StatBar

StatBar is a native macOS menu bar system monitor for Apple Silicon and macOS 14+. It displays temperature and fan speeds in the menu bar and provides a complete system dashboard.

## Features

- Total and per-core CPU usage, 1/5/15-minute load averages, uptime, active processes, and history
- GPU utilization and memory when the hardware exposes matching IORegistry data
- Memory usage, pressure, wired memory, compression, cache, and swap
- Capacity for all mounted volumes, system-drive S.M.A.R.T. status, and live physical-disk I/O
- Active network interface, Wi-Fi name, private IP, live and cumulative throughput, and history
- Internal battery charge, state, remaining time, health, cycles, voltage, current, power, and compatible Bluetooth-device batteries
- AppleSMC temperature, power, voltage, and current sensors
- Every exposed fan, individual manual RPM, individual or global automatic mode, and a three-point temperature curve
- Hardware minimum/maximum RPM limits, low-speed rejection at 95°C, and a 45-second failsafe watchdog
- Multi-time-zone clocks, seven days of local calendar events, Open-Meteo hourly and weekly weather, sunrise, sunset, and moon phase
- Optional public IP lookup, disabled by default and limited to ipify.org
- CPU, temperature, low-battery, low-disk, and connectivity alerts
- Local settings only, with no analytics, ads, or telemetry

## Build and Run

Requirements:

- Apple Silicon Mac running macOS 14 or later
- Xcode Command Line Tools or Xcode with a compatible macOS SDK
- A macOS 26 SDK only if you want the optional Control Center launcher

`build.sh` selects an installed compatible SDK, builds the native app and helper, and includes the Control Center extension when a macOS 26 SDK is available. Advanced users can override SDK paths with `STATBAR_SDK_PATH` and `STATBAR_CONTROLS_SDK_PATH`.

```sh
git clone https://github.com/boyuhappy2018-eng/StatBar.git
cd StatBar
./build.sh
open build/StatBar.app
```

To install it in the current user's Applications folder and launch it:

```sh
./install.sh
```

On macOS 26, if StatBar does not appear after its first launch, allow it under System Settings → Menu Bar.

## Fan Control

Reading SMC data does not require administrator privileges. The first attempt to enable fan writes asks for macOS administrator authorization and installs:

- `/Library/PrivilegedHelperTools/com.statbar.SMCHelper`
- `/Library/LaunchDaemons/com.statbar.fan-watchdog.plist`

The helper accepts only constrained fan commands; it cannot execute arbitrary paths or write arbitrary SMC keys. Quitting StatBar restores automatic control. The launchd watchdog also restores automatic control after a crash or more than 45 seconds without a heartbeat. The helper can be removed from Settings.

Fan control always carries hardware risk. Apple does not expose a supported third-party fan-write API, and some chips or firmware may reject SMC writes. StatBar never bypasses the RPM range reported by the hardware.

## Data Accuracy

CPU, memory, disk, network, and battery metrics use macOS system interfaces. Fan and thermal telemetry use AppleSMC and Apple Silicon HID interfaces, which Apple does not publicly document as a stable third-party API. StatBar filters calibration and limit values, labels raw sensor sources, and refreshes live values at the configured interval, but model-specific differences are still possible.

Memory Use excludes reclaimable inactive file cache and displays the macOS memory-pressure state separately. Fan RPM is reported exactly as AppleSMC returns it; `0 RPM` can be valid on models that support fan stop.

## Known Limitations

- Wi-Fi SSID access may require Location Services on newer macOS versions.
- GPU metrics, frequencies, and some sensors depend on what each model exposes through IORegistry or AppleSMC.
- Per-app network/disk traffic, exact CPU/GPU frequency, and a signed and notarized updater are not included in version 1.0.
- Current builds use local ad-hoc signing. Public distribution requires an Apple Developer ID signature and notarization.

## Security

The privileged helper is optional and required only for fan writes. It accepts a constrained command set, validates administrator membership and hardware RPM limits, rejects unsafe low-speed writes at 95°C, and uses a 45-second watchdog to restore automatic control. See `SECURITY.md` before enabling or modifying fan control.

The original StatBar code is published without an additional project license. Third-party portions retain their respective licenses.

The AppleSMC compatibility layer includes adapted code from the MIT-licensed Stats project. See `THIRD_PARTY_NOTICES.md`.
