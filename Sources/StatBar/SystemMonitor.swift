import AppKit
import CHIDBridge
import Combine
import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SMCCore

private struct SystemSnapshot {
    var cpuUsage: Double
    var cpuCores: [CPUCoreSample]
    var loadAverages: [Double]
    var uptime: TimeInterval
    var processes: [ProcessSample]
    var memory: MemorySample
    var disks: [DiskSample]
    var diskReadRate: Double
    var diskWriteRate: Double
    var network: NetworkSample
    var battery: BatterySample?
    var bluetooth: [BluetoothBattery]
    var gpu: GPUInfo
    var sensors: [SensorSample]
    var fans: [FanSample]
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpuUsage = 0.0
    @Published private(set) var cpuCores = [CPUCoreSample]()
    @Published private(set) var loadAverages = [Double]()
    @Published private(set) var uptime: TimeInterval = 0
    @Published private(set) var topProcesses = [ProcessSample]()
    @Published private(set) var memory = MemorySample()
    @Published private(set) var disks = [DiskSample]()
    @Published private(set) var diskReadRate = 0.0
    @Published private(set) var diskWriteRate = 0.0
    @Published private(set) var network = NetworkSample()
    @Published private(set) var battery: BatterySample?
    @Published private(set) var bluetooth = [BluetoothBattery]()
    @Published private(set) var gpu = GPUInfo()
    @Published private(set) var sensors = [SensorSample]()
    @Published private(set) var fans = [FanSample]()
    @Published private(set) var cpuHistory = [HistoryPoint]()
    @Published private(set) var temperatureHistory = [HistoryPoint]()
    @Published private(set) var networkDownHistory = [HistoryPoint]()
    @Published private(set) var networkUpHistory = [HistoryPoint]()
    @Published private(set) var weather = WeatherSample()
    @Published private(set) var publicAddress: String?
    @Published private(set) var lastUpdated: Date?

    private let settings: SettingsStore
    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "com.statbar.sampler", qos: .utility)
    private var timer: Timer?
    private var sampling = false
    private var weatherTimer: Timer?
    private var publicIPTimer: Timer?

    var hottestTemperature: Double? {
        sensors.filter { $0.kind == .temperature }.map(\.value).max()
    }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        stop()
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, settings.value.refreshInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
        refreshWeather()
        refreshPublicIP()
        weatherTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWeather() }
        }
        publicIPTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPublicIP() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        weatherTimer?.invalidate()
        weatherTimer = nil
        publicIPTimer?.invalidate()
        publicIPTimer = nil
    }

    func restartForSettingsChange() { start() }

    func sampleNow() {
        guard !sampling else { return }
        sampling = true
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.sampler.sample()
            DispatchQueue.main.async {
                self.apply(snapshot)
                self.sampling = false
            }
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        cpuUsage = snapshot.cpuUsage
        cpuCores = snapshot.cpuCores
        loadAverages = snapshot.loadAverages
        uptime = snapshot.uptime
        topProcesses = snapshot.processes
        memory = snapshot.memory
        disks = snapshot.disks
        diskReadRate = snapshot.diskReadRate
        diskWriteRate = snapshot.diskWriteRate
        network = snapshot.network
        battery = snapshot.battery
        bluetooth = snapshot.bluetooth
        gpu = snapshot.gpu
        sensors = snapshot.sensors
        fans = snapshot.fans
        lastUpdated = Date()

        append(&cpuHistory, value: cpuUsage)
        append(&temperatureHistory, value: hottestTemperature ?? 0)
        append(&networkDownHistory, value: network.downloadPerSecond)
        append(&networkUpHistory, value: network.uploadPerSecond)
    }

    private func append(_ history: inout [HistoryPoint], value: Double) {
        history.append(HistoryPoint(date: Date(), value: value))
        if history.count > 180 { history.removeFirst(history.count - 180) }
    }

    func refreshWeather() {
        let latitude = settings.value.weatherLatitude
        let longitude = settings.value.weatherLongitude
        let query = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m&hourly=temperature_2m,precipitation_probability,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max,uv_index_max&forecast_days=7&timezone=auto"
        guard let url = URL(string: query) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            var sample = WeatherSample()
            if let error {
                sample.error = error.localizedDescription
            } else if let data,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let current = root["current"] as? [String: Any] {
                sample.temperature = current["temperature_2m"] as? Double
                sample.apparentTemperature = current["apparent_temperature"] as? Double
                sample.humidity = current["relative_humidity_2m"] as? Double
                sample.precipitation = current["precipitation"] as? Double
                sample.weatherCode = current["weather_code"] as? Int
                sample.windSpeed = current["wind_speed_10m"] as? Double
                sample.updatedAt = Date()
                sample.hourly = Self.parseHourly(root["hourly"] as? [String: Any])
                sample.daily = Self.parseDaily(root["daily"] as? [String: Any])
            } else {
                sample.error = "Unable to parse weather response"
            }
            DispatchQueue.main.async { self?.weather = sample }
        }.resume()
    }

    func refreshPublicIP() {
        guard settings.value.fetchPublicIP else { publicAddress = nil; return }
        guard let url = URL(string: "https://api64.ipify.org?format=json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            DispatchQueue.main.async { self?.publicAddress = root["ip"] }
        }.resume()
    }

    nonisolated private static func parseHourly(_ raw: [String: Any]?) -> [HourlyWeather] {
        guard let raw,
              let times = raw["time"] as? [String],
              let temperatures = raw["temperature_2m"] as? [Double],
              let precipitation = raw["precipitation_probability"] as? [Double],
              let codes = raw["weather_code"] as? [Int] else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let now = Date().addingTimeInterval(-3600)
        return times.indices.compactMap { index in
            guard temperatures.indices.contains(index), precipitation.indices.contains(index), codes.indices.contains(index),
                  let date = formatter.date(from: times[index]), date >= now else { return nil }
            return HourlyWeather(date: date, temperature: temperatures[index], precipitationChance: precipitation[index], weatherCode: codes[index])
        }.prefix(24).map { $0 }
    }

    nonisolated private static func parseDaily(_ raw: [String: Any]?) -> [DailyWeather] {
        guard let raw,
              let times = raw["time"] as? [String],
              let lows = raw["temperature_2m_min"] as? [Double],
              let highs = raw["temperature_2m_max"] as? [Double],
              let precipitation = raw["precipitation_probability_max"] as? [Double],
              let uv = raw["uv_index_max"] as? [Double],
              let codes = raw["weather_code"] as? [Int],
              let sunrises = raw["sunrise"] as? [String], let sunsets = raw["sunset"] as? [String] else { return [] }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let timestamp = DateFormatter(); timestamp.locale = Locale(identifier: "en_US_POSIX"); timestamp.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return times.indices.compactMap { index in
            guard lows.indices.contains(index), highs.indices.contains(index), precipitation.indices.contains(index),
                  uv.indices.contains(index), codes.indices.contains(index), sunrises.indices.contains(index), sunsets.indices.contains(index),
                  let date = day.date(from: times[index]) else { return nil }
            return DailyWeather(date: date, low: lows[index], high: highs[index], precipitationChance: precipitation[index],
                                uvIndex: uv[index], weatherCode: codes[index], sunrise: timestamp.date(from: sunrises[index]),
                                sunset: timestamp.date(from: sunsets[index]))
        }
    }
}

private final class SystemSampler: @unchecked Sendable {
    private static let trustedAppleSiliconSMCKeys: Set<String> = [
        "TC0P", "TC0D", "TC0F", "TG0P", "TG0D", "Ts0P", "Tm0P", "TB0T",
        "PCPC", "PCPG", "PSTR", "VC0C"
    ]

    private struct CPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64
        var total: UInt64 { user + system + idle + nice }
        var busy: UInt64 { user + system + nice }
    }

    private var previousCPU = [CPUTicks]()
    private var previousNetwork: (received: UInt64, sent: UInt64, date: Date)?
    private var previousDisk: (read: UInt64, write: UInt64, date: Date)?
    private var sensorKeys: [(String, SensorKind)]?
    private var smartStatus: String?
    private var lastSMARTRefresh = Date.distantPast
    private var lastBluetooth = [BluetoothBattery]()
    private var lastBluetoothRefresh = Date.distantPast
    private var lastFans = [FanSample]()
    private var lastFanRefresh = Date.distantPast
    private let performanceCoreCount: Int

    init() {
        performanceCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
    }

    func sample() -> SystemSnapshot {
        let cpu = sampleCPU()
        let diskCounters = blockStorageCounters()
        let now = Date()
        var diskReadRate = 0.0
        var diskWriteRate = 0.0
        if let previousDisk {
            let elapsed = max(0.1, now.timeIntervalSince(previousDisk.date))
            diskReadRate = Double(diskCounters.read >= previousDisk.read ? diskCounters.read - previousDisk.read : 0) / elapsed
            diskWriteRate = Double(diskCounters.write >= previousDisk.write ? diskCounters.write - previousDisk.write : 0) / elapsed
        }
        previousDisk = (diskCounters.read, diskCounters.write, now)

        if now.timeIntervalSince(lastSMARTRefresh) > 60 {
            smartStatus = readSMARTStatus()
            lastSMARTRefresh = now
        }
        if now.timeIntervalSince(lastBluetoothRefresh) > 30 {
            lastBluetooth = sampleBluetooth()
            lastBluetoothRefresh = now
        }

        if now.timeIntervalSince(lastFanRefresh) > 4 {
            lastFans = sampleFans()
            lastFanRefresh = now
        }

        return SystemSnapshot(
            cpuUsage: cpu.total,
            cpuCores: cpu.cores,
            loadAverages: loadAverage(),
            uptime: ProcessInfo.processInfo.systemUptime,
            processes: sampleProcesses(),
            memory: sampleMemory(),
            disks: sampleDisks(smartStatus: smartStatus),
            diskReadRate: diskReadRate,
            diskWriteRate: diskWriteRate,
            network: sampleNetwork(),
            battery: sampleBattery(),
            bluetooth: lastBluetooth,
            gpu: sampleGPU(),
            sensors: sampleSensors(),
            fans: lastFans
        )
    }

    private func sampleCPU() -> (total: Double, cores: [CPUCoreSample]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var current = [CPUTicks]()
        for index in 0..<Int(cpuCount) {
            let offset = index * Int(CPU_STATE_MAX)
            current.append(CPUTicks(
                user: UInt64(info[offset + Int(CPU_STATE_USER)]),
                system: UInt64(info[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[offset + Int(CPU_STATE_NICE)])
            ))
        }

        let hasPrevious = previousCPU.count == current.count
        var usages = [Double]()
        for index in current.indices {
            guard hasPrevious else { usages.append(0); continue }
            let totalDelta = current[index].total >= previousCPU[index].total ? current[index].total - previousCPU[index].total : 0
            let busyDelta = current[index].busy >= previousCPU[index].busy ? current[index].busy - previousCPU[index].busy : 0
            usages.append(totalDelta > 0 ? Double(busyDelta) / Double(totalDelta) * 100 : 0)
        }
        previousCPU = current

        let cores = usages.enumerated().map { index, usage in
            let kind: CPUCoreSample.CoreKind
            if performanceCoreCount == 0 { kind = .unknown }
            else { kind = index < performanceCoreCount ? .performance : .efficiency }
            return CPUCoreSample(id: index, usage: usage.clampedPercent, kind: kind)
        }
        let total = usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
        return (total.clampedPercent, cores)
    }

    private func loadAverage() -> [Double] {
        var values = Array(repeating: 0.0, count: 3)
        _ = getloadavg(&values, 3)
        return values
    }

    private func sampleMemory() -> MemorySample {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return MemorySample() }
        let page = UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        let wired = UInt64(stats.wire_count) * page
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let speculative = UInt64(stats.speculative_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        // Inactive/speculative pages are reclaimable file cache. Counting them
        // as active use makes a healthy Mac appear permanently 90%+ full.
        let cached = min(total, inactive + speculative)
        let used = min(total, wired + active + compressed)
        let pressureLevel = Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1

        var swapUsed: UInt64 = 0
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { swapUsed = swap.xsu_used }
        return MemorySample(total: total, used: used, wired: wired, compressed: compressed,
                            cached: cached, swapUsed: swapUsed,
                            usagePercent: total > 0 ? Double(used) / Double(total) * 100 : 0,
                            pressureLevel: pressureLevel)
    }

    private func sampleDisks(smartStatus: String?) -> [DiskSample] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsRemovableKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsBrowsable != false,
                  let totalNumber = values.volumeTotalCapacity, totalNumber > 0 else { return nil }
            let free = max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)
            return DiskSample(id: url.path, name: values.volumeName ?? url.lastPathComponent,
                              path: url.path, total: UInt64(totalNumber), free: UInt64(free),
                              removable: values.volumeIsRemovable ?? false,
                              smartStatus: url.path == "/" ? smartStatus : nil)
        }.sorted { $0.path == "/" || ($1.path != "/" && $0.name < $1.name) }
    }

    private func blockStorageCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = property as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    private func sampleNetwork() -> NetworkSample {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return NetworkSample() }
        defer { freeifaddrs(pointer) }
        var counters: [String: (received: UInt64, sent: UInt64)] = [:]
        var addresses: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor?.pointee {
            let name = String(cString: item.ifa_name)
            let flags = Int32(item.ifa_flags)
            let active = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
            if active, let address = item.ifa_addr {
                if address.pointee.sa_family == UInt8(AF_LINK), let data = item.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    counters[name] = (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
                } else if address.pointee.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addresses[name] = String(cString: host)
                    }
                }
            }
            cursor = item.ifa_next
        }
        let preferred = ["en0", "en1"].first(where: { counters[$0] != nil })
            ?? counters.keys.filter { !$0.hasPrefix("utun") && !$0.hasPrefix("awdl") && !$0.hasPrefix("llw") }.sorted().first
            ?? counters.keys.sorted().first
        guard let interface = preferred, let totals = counters[interface] else { return NetworkSample() }
        let now = Date()
        var down = 0.0
        var up = 0.0
        if let previousNetwork {
            let elapsed = max(0.1, now.timeIntervalSince(previousNetwork.date))
            down = Double(totals.received >= previousNetwork.received ? totals.received - previousNetwork.received : 0) / elapsed
            up = Double(totals.sent >= previousNetwork.sent ? totals.sent - previousNetwork.sent : 0) / elapsed
        }
        previousNetwork = (totals.received, totals.sent, now)
        let wifi = CWWiFiClient.shared().interface(withName: interface)?.ssid()
        return NetworkSample(interface: interface, wifiName: wifi, privateAddress: addresses[interface] ?? "—",
                             downloadPerSecond: down, uploadPerSecond: up,
                             totalReceived: totals.received, totalSent: totals.sent,
                             online: addresses[interface] != nil)
    }

    private func sampleBattery() -> BatterySample? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (raw[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = (raw[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = (raw[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            let state = raw[kIOPSPowerSourceStateKey] as? String ?? "Unknown"
            let charging = (raw[kIOPSIsChargingKey] as? Bool) ?? false
            let charged = (raw[kIOPSIsChargedKey] as? Bool) ?? false
            let timeKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (raw[timeKey] as? NSNumber)?.intValue
            var battery = BatterySample(percent: maximum > 0 ? current / maximum * 100 : current,
                                        isCharging: charging, isCharged: charged,
                                        timeRemainingMinutes: (minutes ?? 0) > 0 ? minutes : nil,
                                        powerSource: state)
            enrichBattery(&battery)
            return battery
        }
        return nil
    }

    private func enrichBattery(_ battery: inout BatterySample) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return }
        battery.cycleCount = (dict["CycleCount"] as? NSNumber)?.intValue
        if let design = (dict["DesignCapacity"] as? NSNumber)?.doubleValue,
           let max = (dict["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue, design > 0 {
            battery.healthPercent = min(100, max / design * 100)
        }
        battery.amperage = (dict["Amperage"] as? NSNumber)?.doubleValue.map { $0 / 1000 }
        battery.voltage = (dict["Voltage"] as? NSNumber)?.doubleValue.map { $0 / 1000 }
        if let amps = battery.amperage, let volts = battery.voltage { battery.powerWatts = abs(amps * volts) }
    }

    private func sampleGPU() -> GPUInfo {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return GPUInfo() }
        defer { IOObjectRelease(iterator) }
        var result = GPUInfo()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let root = properties?.takeRetainedValue() as? [String: Any] else { continue }
            let stats = (root["PerformanceStatistics"] as? [String: Any]) ?? root
            for (key, raw) in stats {
                guard let number = raw as? NSNumber else { continue }
                let lower = key.lowercased()
                if lower.contains("device utilization") || lower == "gpu activity(%)" || lower == "gpu busy" {
                    result.utilization = max(result.utilization ?? 0, number.doubleValue)
                }
                if lower.contains("in use system memory") || lower.contains("vram used") {
                    result.memoryBytes = max(result.memoryBytes ?? 0, number.uint64Value)
                }
            }
            if let model = root["model"] as? Data, let name = String(data: model, encoding: .utf8) {
                result.name = name.trimmingCharacters(in: .controlCharacters)
            }
        }
        if let utilization = result.utilization, utilization <= 1 { result.utilization = utilization * 100 }
        return result
    }

    private func sampleSensors() -> [SensorSample] {
        if sensorKeys == nil {
            sensorKeys = SMC.shared.allKeys().compactMap { key in
                #if arch(arm64)
                // Most Apple Silicon SMC T/P/V keys are limits or calibration
                // constants rather than live telemetry. Only retain established
                // live keys; the HID sensor hub supplies the model-specific set.
                guard Self.trustedAppleSiliconSMCKeys.contains(key) else { return nil }
                #endif
                guard let first = key.first else { return nil }
                let kind: SensorKind
                switch first {
                case "T", "t": kind = .temperature
                case "P", "p": kind = .power
                case "V", "v": kind = .voltage
                case "I", "i":
                    #if arch(arm64)
                    // Apple Silicon exposes live current sensors through the HID
                    // sensor hub. Raw SMC i* keys also contain limits/calibration
                    // constants (for example iaWS=500), so labeling all of them
                    // as live amperage produces dangerously misleading readings.
                    return nil
                    #else
                    kind = .current
                    #endif
                default: return nil
                }
                return (key, kind)
            }
        }
        var readings: [SensorSample] = (sensorKeys ?? []).compactMap { pair -> SensorSample? in
            let (key, kind) = pair
            guard let value = SMC.shared.value(for: key), value.isFinite else { return nil }
            switch kind {
            case .temperature where !(value > -20 && value < 130): return nil
            case .power where !(value >= 0 && value < 2_000): return nil
            case .voltage where !(value >= 0 && value < 500): return nil
            case .current where !(abs(value) < 1_000): return nil
            default: break
            }
            let unit: String
            switch kind { case .temperature: unit = "°C"; case .power: unit = "W"; case .voltage: unit = "V"; case .current: unit = "A"; default: unit = "" }
            return SensorSample(id: key, key: key, name: Self.sensorName(key), value: value, kind: kind, unit: unit)
        }
        #if arch(arm64)
        let hidTypes: [(Int32, Int32, Int32, SensorKind, String)] = [
            (0xff00, 0x0005, 15, .temperature, "°C"),
            (0xff08, 0x0003, 25, .voltage, "V"),
            (0xff08, 0x0002, 25, .current, "A")
        ]
        for (page, usage, eventType, kind, unit) in hidTypes {
            guard let values = SBAppleSiliconSensors(page, usage, eventType) else { continue }
            for (name, number) in values {
                let value = number.doubleValue
                let normalizedName = name.lowercased()
                if kind == .temperature && (normalizedName.contains("tcal") || normalizedName.contains("calibration")) {
                    continue
                }
                let sane: Bool
                switch kind {
                case .temperature: sane = value > 0 && value < 120
                case .voltage: sane = value > 0.001 && value < 300
                case .current: sane = abs(value) > 0.001 && abs(value) < 300
                default: sane = value.isFinite
                }
                guard sane else { continue }
                readings.append(SensorSample(id: "HID:\(name):\(kind.rawValue)", key: "HID", name: Self.hidSensorName(name), value: value, kind: kind, unit: unit))
            }
        }
        #endif
        return readings.sorted { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue { return lhs.name < rhs.name }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private func sampleFans() -> [FanSample] {
        let direct = SMC.shared.fans()
        var values = direct
        if values.isEmpty {
            let helper = "/Library/PrivilegedHelperTools/com.statbar.SMCHelper"
            if FileManager.default.isExecutableFile(atPath: helper),
               let data = Self.runData(helper, ["list"]),
               let decoded = try? JSONDecoder().decode([SMCFanInfo].self, from: data) {
                values = decoded
            }
        }
        return values.map {
            FanSample(id: $0.id, name: $0.name, currentRPM: $0.currentRPM,
                      minimumRPM: $0.minimumRPM, maximumRPM: $0.maximumRPM,
                      targetRPM: $0.targetRPM, isForced: $0.isForced)
        }
    }

    private func sampleProcesses() -> [ProcessSample] {
        guard let output = Self.run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm=", "-r"]) else { return [] }
        return output.split(separator: "\n").prefix(12).compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1]), let rss = UInt64(fields[2]) else { return nil }
            return ProcessSample(id: pid, name: URL(fileURLWithPath: String(fields[3])).lastPathComponent,
                                 cpu: cpu, memoryBytes: rss * 1024)
        }
    }

    private func sampleBluetooth() -> [BluetoothBattery] {
        guard let data = Self.runData("/usr/sbin/ioreg", ["-a", "-r", "-l", "-c", "AppleDeviceManagementHIDEventService"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
        return plist.compactMap { dict in
            let percent = (dict["BatteryPercent"] as? NSNumber)?.intValue
                ?? (dict["BatteryPercentSingle"] as? NSNumber)?.intValue
            guard let percent, percent >= 0, percent <= 100 else { return nil }
            let name = dict["Product"] as? String ?? dict["ProductName"] as? String ?? "Bluetooth Device"
            let address = dict["DeviceAddress"] as? String ?? name
            return BluetoothBattery(id: address, name: name, percent: percent)
        }
    }

    private func readSMARTStatus() -> String? {
        guard let data = Self.runData("/usr/sbin/diskutil", ["info", "-plist", "/"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["SMARTStatus"] as? String
    }

    private static func sensorName(_ key: String) -> String {
        let names = [
            "TC0P": "CPU Proximity", "TC0D": "CPU Core", "TC0F": "CPU Control",
            "TG0P": "GPU Proximity", "TG0D": "GPU Core", "Ts0P": "Palm Rest",
            "Tm0P": "Memory", "TB0T": "Battery", "PCPC": "CPU Power",
            "PCPG": "GPU Power", "PSTR": "System Power", "VC0C": "CPU Voltage"
        ]
        return names[key] ?? key
    }

    private static func hidSensorName(_ name: String) -> String {
        if name.hasPrefix("pACC MTR Temp") { return "CPU Performance Cluster " + name.replacingOccurrences(of: "pACC MTR Temp", with: "") }
        if name.hasPrefix("eACC MTR Temp") { return "CPU Efficiency Cluster " + name.replacingOccurrences(of: "eACC MTR Temp", with: "") }
        if name.hasPrefix("GPU MTR Temp") { return "GPU " + name.replacingOccurrences(of: "GPU MTR Temp", with: "") }
        if name.hasPrefix("SOC MTR Temp") { return "SoC " + name.replacingOccurrences(of: "SOC MTR Temp", with: "") }
        return name
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        guard let data = runData(executable, arguments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func runData(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

private extension Double {
    func map<T>(_ transform: (Double) -> T) -> T { transform(self) }
}
