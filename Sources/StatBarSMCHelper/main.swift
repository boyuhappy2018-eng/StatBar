import Foundation
import Darwin
import SMCCore

private let heartbeatPath = "/var/run/com.statbar.fan-heartbeat"

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func callerMayControlFans() -> Bool {
    if getuid() == 0 { return true }
    guard let admin = getgrnam("admin") else { return false }
    let adminID = admin.pointee.gr_gid
    let count = getgroups(0, nil)
    guard count > 0 else { return false }
    var groups = Array(repeating: gid_t(0), count: Int(count))
    let actual = groups.withUnsafeMutableBufferPointer { getgroups(count, $0.baseAddress) }
    return actual > 0 && groups.prefix(Int(actual)).contains(adminID)
}

private func requireRootAndAdmin() {
    guard geteuid() == 0 else { fail("Fan writes require the StatBar privileged helper.", code: 77) }
    guard callerMayControlFans() else { fail("Only a local administrator can control fans.", code: 77) }
}

private func touchHeartbeat() {
    let payload = "\(Date().timeIntervalSince1970)\n"
    guard FileManager.default.createFile(atPath: heartbeatPath, contents: Data(payload.utf8),
                                         attributes: [.posixPermissions: 0o600]) else {
        fail("Unable to write the fan safety heartbeat.")
    }
}

private func clearHeartbeat() {
    try? FileManager.default.removeItem(atPath: heartbeatPath)
}

private func hottestKnownTemperature(_ smc: SMC) -> Double {
    let common = ["TC0P", "TC0D", "TC0F", "TG0P", "TG0D", "Tp0P", "Ts0P", "Tm0P"]
    var keys = common
    for prefix in ["Tp", "Te", "Tg", "Tm", "Ts"] {
        for suffix in 0...31 { keys.append(String(format: "%@%02X", prefix, suffix)) }
    }
    return keys.compactMap { smc.value(for: $0) }
        .filter { $0 > 1 && $0 < 130 }
        .max() ?? 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("Usage: StatBarSMCHelper list | set FAN RPM | set-all FAN RPM [FAN RPM ...] | auto FAN|all | heartbeat | watchdog | version", code: 64)
}

let smc = SMC.shared
guard smc.isAvailable else { fail("Unable to connect to AppleSMC.", code: 69) }

switch command {
case "version":
    print("StatBarSMCHelper 1.0")

case "list":
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(smc.fans()) else { fail("Unable to encode fan data.") }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))

case "set":
    requireRootAndAdmin()
    guard arguments.count == 3,
          let fanID = Int(arguments[1]), let requested = Int(arguments[2]) else {
        fail("Usage: set FAN RPM", code: 64)
    }
    guard let fan = smc.fans().first(where: { $0.id == fanID }) else { fail("Fan not found.", code: 65) }
    guard requested >= Int(fan.minimumRPM), requested <= Int(fan.maximumRPM) else {
        fail("RPM must be within the hardware range \(Int(fan.minimumRPM))…\(Int(fan.maximumRPM)).", code: 65)
    }
    let hottest = hottestKnownTemperature(smc)
    if hottest >= 95, requested < Int(fan.maximumRPM * 0.8) {
        _ = smc.resetAllFans()
        clearHeartbeat()
        fail("Temperature reached \(Int(hottest))°C; low RPM was rejected and automatic control restored.", code: 70)
    }
    guard smc.setFan(id: fanID, rpm: requested) else { fail("SMC rejected the fan write.", code: 74) }
    touchHeartbeat()
    print("OK fan=\(fanID) rpm=\(requested)")

case "set-all":
    requireRootAndAdmin()
    guard arguments.count >= 3, arguments.count % 2 == 1 else {
        fail("Usage: set-all FAN RPM [FAN RPM ...]", code: 64)
    }
    let fans = smc.fans()
    var targets = [(fan: SMCFanInfo, rpm: Int)]()
    for index in stride(from: 1, to: arguments.count, by: 2) {
        guard let fanID = Int(arguments[index]), let requested = Int(arguments[index + 1]),
              let fan = fans.first(where: { $0.id == fanID }) else {
            fail("Invalid fan ID or RPM.", code: 65)
        }
        guard requested >= Int(fan.minimumRPM), requested <= Int(fan.maximumRPM) else {
            fail("Fan \(fanID) RPM must be within \(Int(fan.minimumRPM))…\(Int(fan.maximumRPM)).", code: 65)
        }
        targets.append((fan, requested))
    }
    let hottest = hottestKnownTemperature(smc)
    if hottest >= 95, targets.contains(where: { $0.rpm < Int($0.fan.maximumRPM * 0.8) }) {
        _ = smc.resetAllFans()
        clearHeartbeat()
        fail("Temperature reached \(Int(hottest))°C; low RPM was rejected and automatic control restored.", code: 70)
    }
    for target in targets {
        guard smc.setFan(id: target.fan.id, rpm: target.rpm) else {
            _ = smc.resetAllFans()
            clearHeartbeat()
            fail("Fan \(target.fan.id) write failed; all fans were restored to automatic mode.", code: 74)
        }
    }
    touchHeartbeat()
    print("OK fans=\(targets.count)")

case "auto":
    requireRootAndAdmin()
    guard arguments.count == 2 else { fail("Usage: auto FAN|all", code: 64) }
    let success: Bool
    if arguments[1] == "all" {
        success = smc.resetAllFans()
        clearHeartbeat()
    } else if let fanID = Int(arguments[1]) {
        success = smc.setAutomatic(id: fanID)
        if smc.fans().allSatisfy({ !$0.isForced }) { clearHeartbeat() }
    } else {
        fail("Invalid fan ID.", code: 65)
    }
    guard success else { fail("SMC rejected automatic mode.", code: 74) }
    print("OK automatic")

case "heartbeat":
    requireRootAndAdmin()
    if smc.fans().contains(where: { $0.isForced }) { touchHeartbeat() }
    print("OK heartbeat")

case "watchdog":
    requireRootAndAdmin()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: heartbeatPath),
          let modified = attributes[.modificationDate] as? Date else { exit(0) }
    if Date().timeIntervalSince(modified) > 45 {
        if smc.resetAllFans() {
            clearHeartbeat()
            print("WATCHDOG restored automatic fan control")
        } else {
            fail("WATCHDOG could not restore automatic fan control", code: 74)
        }
    }

default:
    fail("Unknown command.", code: 64)
}
