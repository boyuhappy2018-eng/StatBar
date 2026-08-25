import Foundation

struct CPUCoreSample: Identifiable, Hashable {
    let id: Int
    let usage: Double
    let kind: CoreKind

    enum CoreKind: String {
        case efficiency = "E"
        case performance = "P"
        case unknown = ""
    }
}

struct ProcessSample: Identifiable, Hashable {
    let id: Int
    let name: String
    let cpu: Double
    let memoryBytes: UInt64
}

struct MemorySample: Hashable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var usagePercent: Double = 0
    var pressureLevel: Int = 1
}

struct DiskSample: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let total: UInt64
    let free: UInt64
    let removable: Bool
    let smartStatus: String?
}

struct NetworkSample: Hashable {
    var interface = "—"
    var wifiName: String?
    var privateAddress = "—"
    var downloadPerSecond: Double = 0
    var uploadPerSecond: Double = 0
    var totalReceived: UInt64 = 0
    var totalSent: UInt64 = 0
    var online = false
}

struct BatterySample: Hashable {
    var percent: Double = 0
    var isCharging = false
    var isCharged = false
    var timeRemainingMinutes: Int?
    var cycleCount: Int?
    var healthPercent: Double?
    var powerSource = "Unknown"
    var amperage: Double?
    var voltage: Double?
    var powerWatts: Double?
}

struct BluetoothBattery: Identifiable, Hashable {
    let id: String
    let name: String
    let percent: Int
}

enum SensorKind: String, CaseIterable {
    case temperature = "Temperature"
    case power = "Power"
    case voltage = "Voltage"
    case current = "Current"
    case frequency = "Frequency"
    case other = "Other"
}

struct SensorSample: Identifiable, Hashable {
    let id: String
    let key: String
    let name: String
    let value: Double
    let kind: SensorKind
    let unit: String
}

struct FanSample: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let currentRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetRPM: Double
    let isForced: Bool
}

struct GPUInfo: Hashable {
    var utilization: Double?
    var memoryBytes: UInt64?
    var name: String = "Apple GPU"
}

struct WeatherSample: Hashable {
    var temperature: Double?
    var apparentTemperature: Double?
    var humidity: Double?
    var windSpeed: Double?
    var precipitation: Double?
    var weatherCode: Int?
    var updatedAt: Date?
    var error: String?
    var hourly = [HourlyWeather]()
    var daily = [DailyWeather]()
}

struct HourlyWeather: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let temperature: Double
    let precipitationChance: Double
    let weatherCode: Int
}

struct DailyWeather: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let low: Double
    let high: Double
    let precipitationChance: Double
    let uvIndex: Double
    let weatherCode: Int
    let sunrise: Date?
    let sunset: Date?
}

struct HistoryPoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct WorldClock: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var timeZoneID: String

    init(id: UUID = UUID(), name: String, timeZoneID: String) {
        self.id = id
        self.name = name
        self.timeZoneID = timeZoneID
    }
}

struct FanCurvePoint: Identifiable, Hashable, Codable {
    var id = UUID()
    var temperature: Double
    var percent: Double
}

struct AppSettings: Codable, Hashable {
    var refreshInterval = 2.0
    var showTemperatureInMenu = true
    var showFanInMenu = true
    var showNetworkInMenu = false
    var launchAtLogin = false
    var weatherName = "Shanghai"
    var weatherLatitude = 31.2304
    var weatherLongitude = 121.4737
    var fetchPublicIP = false
    var cpuAlertPercent = 90.0
    var temperatureAlertCelsius = 90.0
    var batteryAlertPercent = 15.0
    var diskFreeAlertPercent = 10.0
    var rulesEnabled = true
    var curveEnabled = false
    var fanCurve = [
        FanCurvePoint(temperature: 45, percent: 0),
        FanCurvePoint(temperature: 65, percent: 55),
        FanCurvePoint(temperature: 80, percent: 100)
    ]
    var worldClocks = [
        WorldClock(name: "Shanghai", timeZoneID: "Asia/Shanghai"),
        WorldClock(name: "UTC", timeZoneID: "UTC"),
        WorldClock(name: "San Francisco", timeZoneID: "America/Los_Angeles")
    ]
}

extension Double {
    var clampedPercent: Double { min(100, max(0, self)) }
}

enum Formatters {
    static let bytes: ByteCountFormatter = {
        let value = ByteCountFormatter()
        value.countStyle = .memory
        value.allowedUnits = [.useGB, .useMB, .useKB]
        value.includesUnit = true
        return value
    }()

    static let rate: ByteCountFormatter = {
        let value = ByteCountFormatter()
        value.countStyle = .decimal
        value.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        value.includesUnit = true
        return value
    }()

    static func byteString(_ value: UInt64) -> String { bytes.string(fromByteCount: Int64(value)) }
    static func rateString(_ value: Double) -> String { "\(rate.string(fromByteCount: Int64(max(0, value))))/s" }
}
