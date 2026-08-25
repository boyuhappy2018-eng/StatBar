// Portions of this AppleSMC transport are adapted from exelban/Stats.
// Stats is Copyright (c) 2019 Serhiy Mytrovtsiy and licensed under MIT.
// See THIRD_PARTY_NOTICES.md in this project.

import Foundation
import IOKit

private enum SMCDataType: String {
    case ui8 = "ui8 ", ui16 = "ui16", ui32 = "ui32"
    case sp1e = "sp1e", sp3c = "sp3c", sp4b = "sp4b", sp5a = "sp5a"
    case spa5 = "spa5", sp69 = "sp69", sp78 = "sp78", sp87 = "sp87"
    case sp96 = "sp96", spb4 = "spb4", spf0 = "spf0"
    case flt = "flt ", fpe2 = "fpe2", fds = "{fds"
}

private enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

private struct SMCKeyData {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCValue {
    var key: String
    var dataSize: UInt32 = 0
    var dataType = ""
    var bytes = Array(repeating: UInt8(0), count: 32)
}

private extension UInt32 {
    init(smcKey: String) {
        self = smcKey.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    var smcString: String {
        let raw = [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff),
                   UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
        return String(bytes: raw, encoding: .macOSRoman) ?? "????"
    }
}

public struct SMCFanInfo: Codable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let currentRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double
    public let isForced: Bool
}

public final class SMC {
    public static let shared = SMC()

    private var connection: io_connect_t = 0
    private var lowerCaseModeKey: Bool?
    private let lock = NSLock()

    public var isAvailable: Bool { connection != 0 }

    public init() {
        // Intel Macs publish AppleSMC. Newer Apple Silicon versions expose the
        // same AppleSMCClient user client through AppleSMCKeysEndpoint.
        for serviceClass in ["AppleSMC", "AppleSMCKeysEndpoint"] {
            var iterator: io_iterator_t = 0
            let matching = IOServiceMatching(serviceClass)
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { continue }
            let device = IOIteratorNext(iterator)
            IOObjectRelease(iterator)
            guard device != 0 else { continue }
            let result = IOServiceOpen(device, mach_task_self_, 0, &connection)
            IOObjectRelease(device)
            if result == kIOReturnSuccess { return }
            connection = 0
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    public func value(for key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var value = SMCValue(key: key)
        guard read(&value) == kIOReturnSuccess, value.dataSize > 0 else { return nil }
        return decode(value)
    }

    public func stringValue(for key: String) -> String? {
        guard key.utf8.count == 4 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var value = SMCValue(key: key)
        guard read(&value) == kIOReturnSuccess, value.dataSize > 0 else { return nil }
        if value.dataType == SMCDataType.fds.rawValue {
            return String(bytes: value.bytes.dropFirst(4).prefix(12), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
        return String(bytes: value.bytes.prefix(Int(value.dataSize)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    public func allKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var countValue = SMCValue(key: "#KEY")
        guard read(&countValue) == kIOReturnSuccess,
              let keyCount = decode(countValue), keyCount > 0 else { return [] }
        let count = min(Int(keyCount), 20_000)
        var keys = [String]()
        keys.reserveCapacity(count)
        for index in 0..<count {
            var input = SMCKeyData()
            var output = SMCKeyData()
            input.data8 = SMCCommand.readIndex.rawValue
            input.data32 = UInt32(index)
            guard call(SMCCommand.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess else { continue }
            let key = output.key.smcString
            if key.utf8.count == 4 { keys.append(key) }
        }
        return keys
    }

    public func fans() -> [SMCFanInfo] {
        guard let rawCount = value(for: "FNum") else { return [] }
        return (0..<min(Int(rawCount), 16)).compactMap { index in
            guard let current = value(for: "F\(index)Ac") else { return nil }
            let minimum = value(for: "F\(index)Mn") ?? 0
            let maximum = value(for: "F\(index)Mx") ?? max(current, minimum)
            let target = value(for: "F\(index)Tg") ?? current
            // Apple Silicon may report 3 for a system-managed automatic mode.
            // Only mode 1 is explicitly forced/manual.
            let forced = Int(value(for: fanModeKey(index)) ?? 0) == 1
            let discovered = stringValue(for: "F\(index)ID")
            let name = (discovered?.isEmpty == false ? discovered! : "Fan \(index + 1)")
            return SMCFanInfo(id: index, name: name, currentRPM: current,
                              minimumRPM: minimum, maximumRPM: maximum,
                              targetRPM: target, isForced: forced)
        }
    }

    public func setFan(id: Int, rpm requestedRPM: Int) -> Bool {
        guard let count = value(for: "FNum"), id >= 0, id < Int(count),
              let minimum = value(for: "F\(id)Mn"),
              let maximum = value(for: "F\(id)Mx") else { return false }
        let rpm = min(Int(maximum), max(Int(minimum), requestedRPM))
        lock.lock()
        defer { lock.unlock() }

        #if arch(arm64)
        guard unlockFanControlLocked(fanID: id) else { return false }
        #else
        guard setIntelModeLocked(id: id, forced: true) else { return false }
        #endif

        var target = SMCValue(key: "F\(id)Tg")
        guard read(&target) == kIOReturnSuccess else { return false }
        if target.dataType == SMCDataType.flt.rawValue {
            let bytes = withUnsafeBytes(of: Float(rpm), Array.init)
            target.bytes.replaceSubrange(0..<4, with: bytes)
        } else if target.dataType == SMCDataType.fpe2.rawValue {
            target.bytes[0] = UInt8((rpm >> 6) & 0xff)
            target.bytes[1] = UInt8((rpm << 2) & 0xff)
        } else {
            return false
        }
        return writeWithRetryLocked(target)
    }

    public func setAutomatic(id: Int) -> Bool {
        guard let count = value(for: "FNum"), id >= 0, id < Int(count) else { return false }
        lock.lock()
        defer { lock.unlock() }
        #if arch(arm64)
        var mode = SMCValue(key: fanModeKeyLocked(id))
        guard read(&mode) == kIOReturnSuccess else { return false }
        mode.bytes[0] = 0
        let modeOK = writeWithRetryLocked(mode)
        var target = SMCValue(key: "F\(id)Tg")
        if read(&target) == kIOReturnSuccess, target.dataType == SMCDataType.flt.rawValue {
            let bytes = withUnsafeBytes(of: Float(0), Array.init)
            target.bytes.replaceSubrange(0..<4, with: bytes)
            _ = writeWithRetryLocked(target)
        }
        return modeOK
        #else
        return setIntelModeLocked(id: id, forced: false)
        #endif
    }

    public func resetAllFans() -> Bool {
        #if arch(arm64)
        lock.lock()
        defer { lock.unlock() }
        var test = SMCValue(key: "Ftst")
        if read(&test) == kIOReturnSuccess, test.dataSize > 0 {
            test.bytes[0] = 0
            return writeWithRetryLocked(test)
        }
        guard let countValue = readValueLocked("FNum"), let countNumber = decode(countValue) else { return false }
        var success = true
        for index in 0..<min(Int(countNumber), 16) {
            var mode = SMCValue(key: fanModeKeyLocked(index))
            guard read(&mode) == kIOReturnSuccess else { continue }
            mode.bytes[0] = 0
            if !writeWithRetryLocked(mode) { success = false }
        }
        return success
        #else
        guard let count = value(for: "FNum") else { return false }
        return (0..<min(Int(count), 16)).allSatisfy { setAutomatic(id: $0) }
        #endif
    }

    public func fanModeKey(_ id: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fanModeKeyLocked(id)
    }

    private func fanModeKeyLocked(_ id: Int) -> String {
        #if arch(arm64)
        if lowerCaseModeKey == nil {
            var probe = SMCValue(key: "F0md")
            lowerCaseModeKey = read(&probe) == kIOReturnSuccess && probe.dataSize > 0
        }
        return lowerCaseModeKey == true ? "F\(id)md" : "F\(id)Md"
        #else
        return "F\(id)Md"
        #endif
    }

    #if arch(arm64)
    private func unlockFanControlLocked(fanID: Int) -> Bool {
        var mode = SMCValue(key: fanModeKeyLocked(fanID))
        guard read(&mode) == kIOReturnSuccess else { return false }
        mode.bytes[0] = 1
        if write(mode) == kIOReturnSuccess { return true }

        var test = SMCValue(key: "Ftst")
        guard read(&test) == kIOReturnSuccess, test.dataSize > 0 else { return false }
        if test.bytes[0] != 1 {
            test.bytes[0] = 1
            guard writeWithRetryLocked(test, attempts: 100) else { return false }
            usleep(3_000_000)
        }
        var retryMode = SMCValue(key: fanModeKeyLocked(fanID))
        guard read(&retryMode) == kIOReturnSuccess else { return false }
        retryMode.bytes[0] = 1
        return writeWithRetryLocked(retryMode, attempts: 300, delay: 100_000)
    }
    #endif

    private func setIntelModeLocked(id: Int, forced: Bool) -> Bool {
        var mode = SMCValue(key: "F\(id)Md")
        if read(&mode) == kIOReturnSuccess {
            mode.bytes[0] = forced ? 1 : 0
            if write(mode) != kIOReturnSuccess { return false }
        }
        var global = SMCValue(key: "FS! ")
        guard read(&global) == kIOReturnSuccess else { return true }
        var mask = Int(decode(global) ?? 0)
        if forced { mask |= (1 << id) } else { mask &= ~(1 << id) }
        global.bytes[0] = UInt8((mask >> 8) & 0xff)
        global.bytes[1] = UInt8(mask & 0xff)
        return write(global) == kIOReturnSuccess
    }

    private func readValueLocked(_ key: String) -> SMCValue? {
        var value = SMCValue(key: key)
        return read(&value) == kIOReturnSuccess ? value : nil
    }

    private func decode(_ value: SMCValue) -> Double? {
        guard value.dataSize > 0 else { return nil }
        let b = value.bytes
        switch value.dataType {
        case SMCDataType.ui8.rawValue: return Double(b[0])
        case SMCDataType.ui16.rawValue: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case SMCDataType.ui32.rawValue:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case SMCDataType.sp1e.rawValue: return fixed(b, divisor: 16_384)
        case SMCDataType.sp3c.rawValue: return fixed(b, divisor: 4_096)
        case SMCDataType.sp4b.rawValue: return fixed(b, divisor: 2_048)
        case SMCDataType.sp5a.rawValue: return fixed(b, divisor: 1_024)
        case SMCDataType.sp69.rawValue: return fixed(b, divisor: 512)
        case SMCDataType.sp78.rawValue: return signedFixed(b, divisor: 256)
        case SMCDataType.sp87.rawValue: return signedFixed(b, divisor: 128)
        case SMCDataType.sp96.rawValue: return signedFixed(b, divisor: 64)
        case SMCDataType.spa5.rawValue: return signedFixed(b, divisor: 32)
        case SMCDataType.spb4.rawValue: return signedFixed(b, divisor: 16)
        case SMCDataType.spf0.rawValue: return signedFixed(b, divisor: 1)
        case SMCDataType.fpe2.rawValue: return Double((Int(b[0]) << 6) | (Int(b[1]) >> 2))
        case SMCDataType.flt.rawValue:
            guard b.count >= 4 else { return nil }
            var raw: Float = 0
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: b.prefix(4)) }
            return raw.isFinite ? Double(raw) : nil
        default: return nil
        }
    }

    private func fixed(_ bytes: [UInt8], divisor: Double) -> Double {
        Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / divisor
    }

    private func signedFixed(_ bytes: [UInt8], divisor: Double) -> Double {
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        return Double(raw) / divisor
    }

    private func read(_ value: inout SMCValue) -> kern_return_t {
        guard connection != 0 else { return kIOReturnNotOpen }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = UInt32(smcKey: value.key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        var result = call(SMCCommand.kernelIndex.rawValue, input: &input, output: &output)
        guard result == kIOReturnSuccess else { return result }
        value.dataSize = UInt32(output.keyInfo.dataSize)
        value.dataType = output.keyInfo.dataType.smcString
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCCommand.readBytes.rawValue
        result = call(SMCCommand.kernelIndex.rawValue, input: &input, output: &output)
        guard result == kIOReturnSuccess else { return result }
        withUnsafeBytes(of: output.bytes) { raw in
            value.bytes.replaceSubrange(0..<min(Int(value.dataSize), 32), with: raw.prefix(min(Int(value.dataSize), 32)))
        }
        return kIOReturnSuccess
    }

    private func write(_ value: SMCValue) -> kern_return_t {
        guard connection != 0 else { return kIOReturnNotOpen }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = UInt32(smcKey: value.key)
        input.data8 = SMCCommand.writeBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(value.dataSize)
        withUnsafeMutableBytes(of: &input.bytes) { destination in
            destination.copyBytes(from: value.bytes.prefix(min(Int(value.dataSize), 32)))
        }
        let result = call(SMCCommand.kernelIndex.rawValue, input: &input, output: &output)
        guard result == kIOReturnSuccess else { return result }
        return output.result == 0 ? kIOReturnSuccess : kIOReturnError
    }

    private func writeWithRetryLocked(_ value: SMCValue, attempts: Int = 10, delay: UInt32 = 50_000) -> Bool {
        for attempt in 0..<attempts {
            if write(value) == kIOReturnSuccess { return true }
            if attempt + 1 < attempts { usleep(delay) }
        }
        return false
    }

    private func call(_ index: UInt8, input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(connection, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}
