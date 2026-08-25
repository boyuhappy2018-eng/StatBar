import AppKit
import Foundation

@MainActor
final class FanController: ObservableObject {
    @Published private(set) var helperInstalled = false
    @Published private(set) var busy = false
    @Published var statusMessage = ""
    @Published var pendingRPM: [Int: Double] = [:]

    private let installedHelper = "/Library/PrivilegedHelperTools/com.statbar.SMCHelper"
    private let settings: SettingsStore
    private weak var monitor: SystemMonitor?
    private var heartbeatTimer: Timer?
    private var curveTimer: Timer?
    private var lastCurveRPM: [Int: Int] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
        refreshInstallStatus()
    }

    func attach(monitor: SystemMonitor) {
        self.monitor = monitor
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendHeartbeatIfNeeded() }
        }
        curveTimer?.invalidate()
        curveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyCurveIfNeeded() }
        }
    }

    func refreshInstallStatus() {
        helperInstalled = FileManager.default.isExecutableFile(atPath: installedHelper)
    }

    func installHelper() {
        guard !busy else { return }
        guard let bundledHelper = Bundle.main.path(forAuxiliaryExecutable: "StatBarSMCHelper")
                ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StatBarSMCHelper").path as String?,
              FileManager.default.fileExists(atPath: bundledHelper),
              let plist = Bundle.main.path(forResource: "com.statbar.fan-watchdog", ofType: "plist") else {
            statusMessage = "The helper is missing from the app bundle. Rebuild StatBar."
            return
        }
        busy = true
        let helperQ = Self.shellQuote(bundledHelper)
        let plistQ = Self.shellQuote(plist)
        let destinationQ = Self.shellQuote(installedHelper)
        let launchPlist = "/Library/LaunchDaemons/com.statbar.fan-watchdog.plist"
        let command = [
            "/usr/bin/install -o root -g wheel -m 4755 \(helperQ) \(destinationQ)",
            "/usr/bin/install -o root -g wheel -m 0644 \(plistQ) \(Self.shellQuote(launchPlist))",
            "/bin/launchctl bootout system/com.statbar.fan-watchdog >/dev/null 2>&1 || true",
            "/bin/launchctl bootstrap system \(Self.shellQuote(launchPlist))"
        ].joined(separator: " && ")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runAdministratorCommand(command)
            DispatchQueue.main.async {
                self?.busy = false
                self?.refreshInstallStatus()
                self?.statusMessage = result.success ? "The fan helper and failsafe watchdog are installed." : result.message
            }
        }
    }

    func uninstallHelper() {
        guard !busy else { return }
        busy = true
        let command = [
            "\(Self.shellQuote(installedHelper)) auto all >/dev/null 2>&1 || true",
            "/bin/launchctl bootout system/com.statbar.fan-watchdog >/dev/null 2>&1 || true",
            "/bin/rm -f /Library/LaunchDaemons/com.statbar.fan-watchdog.plist",
            "/bin/rm -f \(Self.shellQuote(installedHelper))",
            "/bin/rm -f /var/run/com.statbar.fan-heartbeat"
        ].joined(separator: " && ")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runAdministratorCommand(command)
            DispatchQueue.main.async {
                self?.busy = false
                self?.refreshInstallStatus()
                self?.statusMessage = result.success ? "The helper was removed and fans were restored to automatic control." : result.message
            }
        }
    }

    func setFan(_ fan: FanSample, rpm: Int) {
        guard helperInstalled, !busy else {
            statusMessage = "Install the fan helper first."
            return
        }
        let clamped = min(Int(fan.maximumRPM), max(Int(fan.minimumRPM), rpm))
        busy = true
        runHelper(["set", String(fan.id), String(clamped)]) { [weak self] success, message in
            self?.busy = false
            self?.statusMessage = success ? "\(fan.name) target set to \(clamped) RPM." : message
            self?.monitor?.sampleNow()
        }
    }

    func restoreAutomatic(fanID: Int? = nil) {
        guard helperInstalled, !busy else {
            statusMessage = helperInstalled ? "A fan operation is already in progress." : "Install the fan helper first."
            return
        }
        busy = true
        settings.value.curveEnabled = false
        runHelper(["auto", fanID.map(String.init) ?? "all"]) { [weak self] success, message in
            self?.busy = false
            self?.lastCurveRPM.removeAll()
            self?.statusMessage = success ? "Fans restored to automatic system control." : message
            self?.monitor?.sampleNow()
        }
    }

    func restoreOnExit() {
        guard helperInstalled else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: installedHelper)
        process.arguments = ["auto", "all"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func sendHeartbeatIfNeeded() {
        guard helperInstalled, monitor?.fans.contains(where: { $0.isForced }) == true else { return }
        runHelper(["heartbeat"], completion: nil)
    }

    private func applyCurveIfNeeded() {
        guard settings.value.curveEnabled, helperInstalled, !busy,
              let monitor, let temperature = monitor.hottestTemperature else { return }
        let points = settings.value.fanCurve.sorted { $0.temperature < $1.temperature }
        guard !points.isEmpty else { return }
        let percent = curvePercent(for: temperature, points: points)
        var arguments = ["set-all"]
        var changed = [(id: Int, rpm: Int)]()
        for fan in monitor.fans {
            let rpm = Int(fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * percent / 100)
            if abs((lastCurveRPM[fan.id] ?? -10_000) - rpm) >= 100 {
                arguments.append(contentsOf: [String(fan.id), String(rpm)])
                changed.append((fan.id, rpm))
            }
        }
        guard !changed.isEmpty else { return }
        busy = true
        runHelper(arguments) { [weak self] success, message in
            guard let self else { return }
            self.busy = false
            if success {
                for target in changed { self.lastCurveRPM[target.id] = target.rpm }
                self.statusMessage = "Fan curve applied to \(changed.count) fans."
            } else {
                self.lastCurveRPM.removeAll()
                self.statusMessage = message
            }
            self.monitor?.sampleNow()
        }
    }

    private func curvePercent(for temperature: Double, points: [FanCurvePoint]) -> Double {
        if temperature >= 90 { return 100 }
        if temperature <= points[0].temperature { return points[0].percent.clampedPercent }
        for pair in zip(points, points.dropFirst()) where temperature <= pair.1.temperature {
            let span = pair.1.temperature - pair.0.temperature
            let progress = span > 0 ? (temperature - pair.0.temperature) / span : 1
            return (pair.0.percent + (pair.1.percent - pair.0.percent) * progress).clampedPercent
        }
        return points.last?.percent.clampedPercent ?? 100
    }

    private func runHelper(_ arguments: [String], completion: ((Bool, String) -> Void)?) {
        DispatchQueue.global(qos: .utility).async { [installedHelper] in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: installedHelper)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
                process.waitUntilExit()
                let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async { completion?(process.terminationStatus == 0, errorText.isEmpty ? outputText : errorText) }
            } catch {
                DispatchQueue.main.async { completion?(false, error.localizedDescription) }
            }
        }
    }

    nonisolated private static func runAdministratorCommand(_ command: String) -> (success: Bool, message: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
        if let error {
            return (false, error[NSAppleScript.errorMessage] as? String ?? "Administrator authorization failed.")
        }
        return (true, "")
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
