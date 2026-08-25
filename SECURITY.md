# Security

## Fan-control warning

StatBar can install an optional setuid helper to write fan targets through AppleSMC. Fan control is inherently hardware-sensitive and relies on interfaces that Apple does not document as a supported third-party API.

The helper accepts only fan-list, constrained RPM, automatic-mode, heartbeat, watchdog, and version commands. It verifies local administrator membership, clamps targets to hardware-reported ranges, rejects unsafe low-speed requests at 95°C, and restores automatic control after 45 seconds without a heartbeat.

Do not remove these safeguards or run modified fan-control code on hardware you cannot recover. Monitoring remains read-only when the helper is not installed.

## Reporting a vulnerability

Please report security-sensitive problems privately through the repository owner's GitHub profile rather than opening a public issue. Include the macOS version, Mac model, StatBar commit, and steps to reproduce. Do not include passwords, authorization dialogs, or personal sensor logs unless they are required and redacted.
