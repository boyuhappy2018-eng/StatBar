import Charts
import SwiftUI

private enum UITheme {
    static let accent = Color(red: 0.36, green: 0.58, blue: 0.72)
    static let surface = Color(nsColor: .controlBackgroundColor).opacity(0.68)
    static let sidebar = Color(nsColor: .underPageBackgroundColor).opacity(0.42)
}

private enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case cpu = "CPU"
    case storage = "Memory & Disks"
    case network = "Network"
    case sensors = "Sensors & Fans"
    case power = "Power"
    case time = "Time & Weather"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .cpu: "cpu"
        case .storage: "memorychip"
        case .network: "network"
        case .sensors: "fan"
        case .power: "battery.75percent"
        case .time: "clock"
        case .settings: "gearshape"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: SettingsStore
    @ObservedObject var fanController: FanController
    @ObservedObject var rules: RuleEngine
    @ObservedObject var calendar: CalendarStore
    @State private var tab: DashboardTab

    init(monitor: SystemMonitor, settings: SettingsStore, fanController: FanController,
         rules: RuleEngine, calendar: CalendarStore, initialTab: String = "overview") {
        self.monitor = monitor
        self.settings = settings
        self.fanController = fanController
        self.rules = rules
        self.calendar = calendar
        let selected: DashboardTab
        switch initialTab {
        case "cpu": selected = .cpu
        case "storage": selected = .storage
        case "network": selected = .network
        case "sensors": selected = .sensors
        case "power": selected = .power
        case "time": selected = .time
        case "settings": selected = .settings
        default: selected = .overview
        }
        _tab = State(initialValue: selected)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .overview: OverviewView(monitor: monitor, settings: settings)
                        case .cpu: CPUView(monitor: monitor)
                        case .storage: StorageView(monitor: monitor)
                        case .network: NetworkView(monitor: monitor)
                        case .sensors: SensorsFansView(monitor: monitor, settings: settings, controller: fanController)
                        case .power: PowerView(monitor: monitor)
                        case .time: TimeWeatherView(monitor: monitor, settings: settings, calendar: calendar)
                        case .settings: SettingsView(monitor: monitor, settings: settings, controller: fanController, rules: rules, calendar: calendar)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 600, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(UITheme.accent)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("StatBar").font(.headline)
                Text("System Monitor").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let updated = monitor.lastUpdated {
                Text(updated, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Button { monitor.sampleNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(DashboardTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.rawValue).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                    .foregroundStyle(tab == item ? .primary : .secondary)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(tab == item ? UITheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(monitor.network.online ? UITheme.accent : Color.secondary).frame(width: 6, height: 6)
                Text(monitor.network.online ? "Online" : "Offline")
            }
            .font(.caption2).foregroundStyle(.secondary).padding(8)
        }
        .padding(8)
        .frame(width: 166)
        .background(UITheme.sidebar)
    }
}

private struct OverviewView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: SettingsStore
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Live Overview", subtitle: ProcessInfo.processInfo.hostName)
            LazyVGrid(columns: columns, spacing: 10) {
                MetricCard(title: "CPU", value: String(format: "%.0f%%", monitor.cpuUsage), icon: "cpu", tint: .blue,
                           detail: monitor.loadAverages.first.map { String(format: "Load %.2f", $0) } ?? "")
                MetricCard(title: "Memory Use", value: String(format: "%.0f%%", monitor.memory.usagePercent), icon: "memorychip", tint: UITheme.accent,
                           detail: "\(memoryPressureName(monitor.memory.pressureLevel)) · \(Formatters.byteString(monitor.memory.used)) active")
                MetricCard(title: "Peak Temperature", value: monitor.hottestTemperature.map { String(format: "%.1f°C", $0) } ?? "—", icon: "thermometer.medium", tint: temperatureColor(monitor.hottestTemperature),
                           detail: "\(monitor.sensors.filter { $0.kind == .temperature }.count) temperature sensors")
                MetricCard(title: "Fans", value: monitor.fans.first.map { "\(Int($0.currentRPM)) RPM" } ?? "No Fans", icon: "fan", tint: UITheme.accent,
                           detail: monitor.fans.contains(where: { $0.isForced }) ? "Manual Control" : "System Automatic")
                MetricCard(title: "Download", value: Formatters.rateString(monitor.network.downloadPerSecond), icon: "arrow.down", tint: UITheme.accent,
                           detail: monitor.network.wifiName ?? monitor.network.interface)
                MetricCard(title: "Upload", value: Formatters.rateString(monitor.network.uploadPerSecond), icon: "arrow.up", tint: UITheme.accent,
                           detail: monitor.network.privateAddress)
                if let battery = monitor.battery {
                    MetricCard(title: "Battery", value: String(format: "%.0f%%", battery.percent), icon: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent", tint: battery.percent < 20 ? .red : UITheme.accent,
                               detail: battery.isCharging ? "Charging" : battery.powerWatts.map { String(format: "%.1f W", $0) } ?? battery.powerSource)
                }
                MetricCard(title: settings.value.weatherName, value: monitor.weather.temperature.map { String(format: "%.1f°C", $0) } ?? "—", icon: weatherIcon(monitor.weather.weatherCode), tint: .indigo,
                           detail: monitor.weather.apparentTemperature.map { String(format: "Feels Like %.1f°C", $0) } ?? monitor.weather.error ?? "Weather")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Last 6 Minutes").font(.subheadline.weight(.semibold))
                HistoryChart(points: monitor.cpuHistory, color: UITheme.accent, domain: 0...100, label: "CPU")
                    .frame(height: 90)
            }.cardStyle()
        }
    }
}

private struct CPUView: View {
    @ObservedObject var monitor: SystemMonitor
    private let coreColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("CPU & GPU", subtitle: "Per-core activity, history, and active processes")
            HStack(spacing: 10) {
                MetricCard(title: "Total CPU", value: String(format: "%.1f%%", monitor.cpuUsage), icon: "cpu", tint: UITheme.accent,
                           detail: "Uptime \(duration(monitor.uptime))")
                MetricCard(title: "GPU", value: monitor.gpu.utilization.map { String(format: "%.1f%%", $0) } ?? "Unavailable", icon: "square.3.layers.3d", tint: UITheme.accent,
                           detail: monitor.gpu.memoryBytes.map(Formatters.byteString) ?? monitor.gpu.name)
            }
            HistoryChart(points: monitor.cpuHistory, color: UITheme.accent, domain: 0...100, label: "CPU %")
                .frame(height: 120).cardStyle()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Logical Cores").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("P Performance · E Efficiency").font(.caption2).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: coreColumns, spacing: 8) {
                    ForEach(monitor.cpuCores) { core in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text("\(core.kind.rawValue)\(core.id)"); Spacer(); Text("\(Int(core.usage))%") }
                                .font(.caption2.monospacedDigit())
                            ProgressView(value: core.usage, total: 100).tint(UITheme.accent)
                        }
                    }
                }
            }.cardStyle()
            VStack(alignment: .leading, spacing: 7) {
                Text("Active Processes").font(.subheadline.weight(.semibold))
                ForEach(monitor.topProcesses.prefix(8)) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", process.cpu)).monospacedDigit().frame(width: 56, alignment: .trailing)
                        Text(Formatters.byteString(process.memoryBytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
                    }.font(.caption)
                }
            }.cardStyle()
        }
    }
}

private struct StorageView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Memory & Storage", subtitle: "Pressure, compression, swap, capacity, and live I/O")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Memory Use").font(.headline)
                    Text(memoryPressureName(monitor.memory.pressureLevel)).font(.caption).foregroundStyle(memoryPressureColor(monitor.memory.pressureLevel))
                    Spacer()
                    Text(String(format: "%.1f%%", monitor.memory.usagePercent)).monospacedDigit()
                }
                ProgressView(value: monitor.memory.usagePercent, total: 100).tint(memoryPressureColor(monitor.memory.pressureLevel))
                statGrid([
                    ("Used", Formatters.byteString(monitor.memory.used)), ("Total", Formatters.byteString(monitor.memory.total)),
                    ("Wired", Formatters.byteString(monitor.memory.wired)), ("Compressed", Formatters.byteString(monitor.memory.compressed)),
                    ("Cached", Formatters.byteString(monitor.memory.cached)), ("Swap", Formatters.byteString(monitor.memory.swapUsed))
                ])
            }.cardStyle()
            HStack(spacing: 10) {
                MetricCard(title: "Disk Read", value: Formatters.rateString(monitor.diskReadRate), icon: "arrow.down.to.line", tint: UITheme.accent, detail: "All Physical Storage")
                MetricCard(title: "Disk Write", value: Formatters.rateString(monitor.diskWriteRate), icon: "arrow.up.to.line", tint: UITheme.accent, detail: "All Physical Storage")
            }
            ForEach(monitor.disks) { disk in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: disk.removable ? "externaldrive" : "internaldrive")
                        Text(disk.name).font(.headline)
                        Spacer()
                        if let smart = disk.smartStatus { Text("S.M.A.R.T. \(smart)").font(.caption2).foregroundStyle(.secondary) }
                    }
                    let used = disk.total - min(disk.total, disk.free)
                    ProgressView(value: Double(used), total: Double(disk.total)).tint(Double(disk.free) / Double(disk.total) < 0.1 ? .red : UITheme.accent)
                    HStack {
                        Text("Used \(Formatters.byteString(used))")
                        Spacer()
                        Text("Available \(Formatters.byteString(disk.free)) / \(Formatters.byteString(disk.total))")
                    }.font(.caption).foregroundStyle(.secondary)
                }.cardStyle()
            }
        }
    }
}

private struct NetworkView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Network", subtitle: "Interfaces, addresses, totals, and live throughput")
            HStack(spacing: 10) {
                MetricCard(title: "Download", value: Formatters.rateString(monitor.network.downloadPerSecond), icon: "arrow.down.circle.fill", tint: UITheme.accent,
                           detail: "Total \(Formatters.byteString(monitor.network.totalReceived))")
                MetricCard(title: "Upload", value: Formatters.rateString(monitor.network.uploadPerSecond), icon: "arrow.up.circle.fill", tint: UITheme.accent,
                           detail: "Total \(Formatters.byteString(monitor.network.totalSent))")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Throughput History").font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(monitor.networkDownHistory) { point in LineMark(x: .value("Time", point.date), y: .value("Download", point.value)).foregroundStyle(UITheme.accent) }
                    ForEach(monitor.networkUpHistory) { point in LineMark(x: .value("Time", point.date), y: .value("Upload", point.value)).foregroundStyle(.secondary) }
                }.chartXAxis(.hidden).frame(height: 145)
                HStack { Label("Download", systemImage: "arrow.down").foregroundStyle(UITheme.accent); Label("Upload", systemImage: "arrow.up").foregroundStyle(.secondary) }.font(.caption)
            }.cardStyle()
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Active Interface", monitor.network.interface)
                infoRow("Wi‑Fi", monitor.network.wifiName ?? "SSID unavailable (location permission may be required)")
                infoRow("Private IPv4", monitor.network.privateAddress)
                infoRow("Public IP", monitor.publicAddress ?? "Disabled in privacy mode")
                infoRow("Connectivity", monitor.network.online ? "Online" : "Offline")
            }.cardStyle()
            Text("Public IP lookup and per-app traffic require an external request or Network Extension access. Local privacy mode keeps them disabled by default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SensorsFansView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: FanController
    @State private var sensorKind: SensorKind = .temperature
    @State private var showFanWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Sensors & Fans", subtitle: "Live AppleSMC telemetry with protected controls")
            if monitor.fans.isEmpty {
                Text("This Mac does not expose readable fans. This is expected on fanless models.")
                    .font(.caption).foregroundStyle(.secondary).cardStyle()
            } else {
                if !controller.helperInstalled {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield").foregroundStyle(UITheme.accent)
                        Text("Manual control requires the local safety helper.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable Manual Control") { showFanWarning = true }
                            .buttonStyle(.borderedProminent)
                    }.cardStyle()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Fan Control").font(.headline)
                        Spacer()
                        Button("All Automatic") { controller.restoreAutomatic() }.disabled(!controller.helperInstalled || controller.busy)
                    }
                    ForEach(monitor.fans) { fan in FanControlRow(fan: fan, controller: controller) }
                    Toggle("Use a three-point fan curve based on peak temperature", isOn: Binding(get: { settings.value.curveEnabled }, set: { value in
                        settings.value.curveEnabled = value
                        if !value { controller.restoreAutomatic() }
                    })).disabled(!controller.helperInstalled)
                    if settings.value.curveEnabled {
                        ForEach(Array(settings.value.fanCurve.enumerated()), id: \.element.id) { index, point in
                            HStack {
                                Text("\(Int(point.temperature))°C").frame(width: 42)
                                Slider(value: Binding(get: { settings.value.fanCurve[index].percent }, set: { settings.value.fanCurve[index].percent = $0 }), in: 0...100, step: 5)
                                Text("\(Int(settings.value.fanCurve[index].percent))%").monospacedDigit().frame(width: 36)
                            }.font(.caption)
                        }
                    }
                    if !controller.statusMessage.isEmpty { Text(controller.statusMessage).font(.caption).foregroundStyle(.secondary) }
                }.cardStyle()
            }
            Picker("Type", selection: $sensorKind) {
                ForEach(SensorKind.allCases.filter { $0 != .frequency && $0 != .other }, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            let filtered = monitor.sensors.filter { $0.kind == sensorKind }
            VStack(alignment: .leading, spacing: 0) {
                if filtered.isEmpty { Text("No available sensors of this type").font(.caption).foregroundStyle(.secondary).padding() }
                ForEach(filtered) { sensor in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) { Text(sensor.name); Text(sensor.key).font(.caption2).foregroundStyle(.tertiary) }
                        Spacer()
                        Text(String(format: sensor.kind == .temperature ? "%.1f %@" : "%.2f %@", sensor.value, sensor.unit)).monospacedDigit()
                    }.font(.caption).padding(.vertical, 6)
                    if sensor.id != filtered.last?.id { Divider() }
                }
            }.cardStyle()
        }
        .alert("Enable Manual Fan Control", isPresented: $showFanWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Install with Safeguards") { controller.installHelper() }
        } message: {
            Text("macOS will request administrator authorization. RPM stays within hardware limits; low speeds are rejected at 95°C; control returns to the system after 45 seconds without a heartbeat.")
        }
    }
}

private struct FanControlRow: View {
    let fan: FanSample
    @ObservedObject var controller: FanController

    private var selectedRPM: Double {
        let reported = fan.targetRPM > 0 ? fan.targetRPM : max(fan.currentRPM, fan.minimumRPM)
        return min(fan.maximumRPM, max(fan.minimumRPM, controller.pendingRPM[fan.id] ?? reported))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(fan.name, systemImage: "fan").font(.subheadline.weight(.semibold))
                Text(fan.isForced ? "Manual" : "Automatic").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background((fan.isForced ? UITheme.accent : Color.secondary).opacity(0.14), in: Capsule())
                Spacer()
                Text("\(Int(fan.currentRPM)) RPM").monospacedDigit()
            }
            HStack {
                Text("\(Int(fan.minimumRPM))").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { selectedRPM }, set: { controller.pendingRPM[fan.id] = $0 }),
                       in: fan.minimumRPM...max(fan.minimumRPM + 1, fan.maximumRPM), step: 50,
                       onEditingChanged: { editing in
                           if !editing { controller.setFan(fan, rpm: Int(selectedRPM)) }
                       }).disabled(!controller.helperInstalled || controller.busy)
                Text("\(Int(fan.maximumRPM))").font(.caption2).foregroundStyle(.secondary)
                Text("\(Int(selectedRPM))").monospacedDigit().frame(width: 52, alignment: .trailing)
                Button("Apply") { controller.setFan(fan, rpm: Int(selectedRPM)) }
                    .disabled(!controller.helperInstalled || controller.busy)
                Button("Auto") { controller.restoreAutomatic(fanID: fan.id) }.disabled(!controller.helperInstalled || controller.busy)
            }
        }
    }
}

private struct PowerView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Battery & Power", subtitle: "Charge state, health, cycles, and connected devices")
            if let battery = monitor.battery {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent").font(.system(size: 34)).foregroundStyle(battery.percent < 20 ? .red : .green)
                        VStack(alignment: .leading) { Text(String(format: "%.0f%%", battery.percent)).font(.title2.bold()); Text(battery.isCharging ? "Charging" : battery.isCharged ? "Fully Charged" : battery.powerSource).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let minutes = battery.timeRemainingMinutes { Text("About \(minutes / 60) hr \(minutes % 60) min").font(.caption) }
                    }
                    ProgressView(value: battery.percent, total: 100).tint(battery.percent < 20 ? .red : .green)
                    statGrid([
                        ("Battery Health", battery.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—"),
                        ("Cycle Count", battery.cycleCount.map(String.init) ?? "—"),
                        ("Voltage", battery.voltage.map { String(format: "%.2f V", $0) } ?? "—"),
                        ("Current", battery.amperage.map { String(format: "%.2f A", $0) } ?? "—"),
                        ("Live Power", battery.powerWatts.map { String(format: "%.2f W", $0) } ?? "—"),
                        ("Source", battery.powerSource)
                    ])
                }.cardStyle()
            } else { Text("No internal battery detected.").foregroundStyle(.secondary).cardStyle() }
            if !monitor.bluetooth.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bluetooth Devices").font(.headline)
                    ForEach(monitor.bluetooth) { device in
                        HStack { Image(systemName: "headphones"); Text(device.name); Spacer(); ProgressView(value: Double(device.percent), total: 100).frame(width: 100); Text("\(device.percent)%").monospacedDigit().frame(width: 38) }
                            .font(.caption)
                    }
                }.cardStyle()
            }
        }
    }
}

private struct TimeWeatherView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: SettingsStore
    @ObservedObject var calendar: CalendarStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Time & Weather", subtitle: "World clocks, upcoming events, and local weather")
            HStack(spacing: 10) {
                ForEach(settings.value.worldClocks) { clock in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(clock.name).font(.caption).foregroundStyle(.secondary)
                        Text(time(clock.timeZoneID)).font(.title3.monospacedDigit().weight(.semibold))
                        Text(date(clock.timeZoneID)).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: weatherIcon(monitor.weather.weatherCode)).font(.system(size: 34)).foregroundStyle(.indigo)
                    VStack(alignment: .leading) { Text(settings.value.weatherName).font(.headline); Text(monitor.weather.temperature.map { String(format: "%.1f°C", $0) } ?? "Weather Unavailable").font(.title2.bold()) }
                    Spacer()
                    Button { monitor.refreshWeather() } label: { Image(systemName: "arrow.clockwise") }
                }
                statGrid([
                    ("Feels Like", monitor.weather.apparentTemperature.map { String(format: "%.1f°C", $0) } ?? "—"),
                    ("Humidity", monitor.weather.humidity.map { String(format: "%.0f%%", $0) } ?? "—"),
                    ("Wind", monitor.weather.windSpeed.map { String(format: "%.1f km/h", $0) } ?? "—"),
                    ("Precipitation", monitor.weather.precipitation.map { String(format: "%.1f mm", $0) } ?? "—")
                ])
                Text("Weather data: Open‑Meteo · No tracking · No API key").font(.caption2).foregroundStyle(.secondary)
            }.cardStyle()
            if !monitor.weather.hourly.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next 24 Hours").font(.headline)
                    Chart(monitor.weather.hourly) { hour in
                        LineMark(x: .value("Time", hour.date), y: .value("Temperature", hour.temperature))
                            .foregroundStyle(UITheme.accent).interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Time", hour.date), y: .value("Temperature", hour.temperature))
                            .foregroundStyle(UITheme.accent.opacity(0.12))
                    }.chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }.frame(height: 115)
                }.cardStyle()
            }
            if !monitor.weather.daily.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("7-Day Forecast").font(.headline); Spacer(); Text("Moon: \(moonPhase())").font(.caption).foregroundStyle(.secondary) }
                    ForEach(monitor.weather.daily) { day in
                        HStack {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated))).frame(width: 36, alignment: .leading)
                            Image(systemName: weatherIcon(day.weatherCode)).foregroundStyle(UITheme.accent).frame(width: 24)
                            Text("\(Int(day.precipitationChance))%").foregroundStyle(.secondary).frame(width: 38)
                            Spacer()
                            Text("\(Int(day.low))°").foregroundStyle(.secondary)
                            Text("\(Int(day.high))°").frame(width: 34, alignment: .trailing)
                            Text("UV \(Int(day.uvIndex))").foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                        }.font(.caption)
                    }
                    if let today = monitor.weather.daily.first, let sunrise = today.sunrise, let sunset = today.sunset {
                        HStack { Label(sunrise.formatted(date: .omitted, time: .shortened), systemImage: "sunrise"); Spacer(); Label(sunset.formatted(date: .omitted, time: .shortened), systemImage: "sunset") }.font(.caption).foregroundStyle(.secondary)
                    }
                }.cardStyle()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Next 7 Days").font(.headline); Spacer(); if calendar.authorization != "Allowed" { Button("Allow Calendar") { calendar.requestAccess() } } }
                if calendar.events.isEmpty { Text(calendar.authorization == "Allowed" ? "No upcoming events" : "Allow calendar access to show local events").font(.caption).foregroundStyle(.secondary) }
                ForEach(calendar.events.prefix(8)) { event in
                    HStack { Circle().fill(UITheme.accent).frame(width: 6, height: 6); Text(event.title).lineLimit(1); Spacer(); Text(event.allDay ? "All Day" : event.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }.font(.caption)
                }
            }.cardStyle()
        }.onAppear { calendar.refresh() }
    }

    private func time(_ id: String) -> String { let f = DateFormatter(); f.timeZone = TimeZone(identifier: id); f.dateFormat = "HH:mm:ss"; return f.string(from: Date()) }
    private func date(_ id: String) -> String { let f = DateFormatter(); f.timeZone = TimeZone(identifier: id); f.dateStyle = .medium; return f.string(from: Date()) }
    private func moonPhase() -> String {
        let reference = Date(timeIntervalSince1970: 947_182_440)
        let cycle = 29.53058867
        let age = (Date().timeIntervalSince(reference) / 86_400).truncatingRemainder(dividingBy: cycle)
        switch age { case 0..<1.85: return "New Moon"; case 1.85..<5.54: return "Waxing Crescent"; case 5.54..<9.23: return "First Quarter"; case 9.23..<12.92: return "Waxing Gibbous"; case 12.92..<16.61: return "Full Moon"; case 16.61..<20.30: return "Waning Gibbous"; case 20.30..<23.99: return "Last Quarter"; case 23.99..<27.68: return "Waning Crescent"; default: return "New Moon" }
    }
}

private struct SettingsView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: FanController
    @ObservedObject var rules: RuleEngine
    @ObservedObject var calendar: CalendarStore
    @State private var showFanWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Settings", subtitle: "Menu bar, sampling, weather, alerts, and privileged components")
            GroupBox("Menu Bar") {
                VStack(alignment: .leading) {
                    Toggle("Show Temperature", isOn: binding(\.showTemperatureInMenu))
                    Toggle("Show Fans", isOn: binding(\.showFanInMenu))
                    Toggle("Show Network Rate", isOn: binding(\.showNetworkInMenu))
                    Toggle("Launch at Login", isOn: binding(\.launchAtLogin))
                    Toggle("Fetch Public IP (contacts ipify.org)", isOn: Binding(get: { settings.value.fetchPublicIP }, set: { enabled in
                        settings.value.fetchPublicIP = enabled
                        monitor.refreshPublicIP()
                    }))
                    HStack {
                        Text("Refresh Interval")
                        Slider(value: binding(\.refreshInterval), in: 1...10, step: 1) { editing in
                            if !editing { monitor.restartForSettingsChange() }
                        }
                        Text("\(Int(settings.value.refreshInterval)) sec").monospacedDigit()
                    }
                }.padding(6)
            }
            GroupBox("Weather Location") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Location Name", text: binding(\.weatherName))
                    HStack { TextField("Latitude", value: binding(\.weatherLatitude), format: .number); TextField("Longitude", value: binding(\.weatherLongitude), format: .number); Button("Refresh") { monitor.refreshWeather() } }
                }.padding(6)
            }
            GroupBox("Alert Rules") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Alerts", isOn: binding(\.rulesEnabled))
                    thresholdRow("CPU", value: binding(\.cpuAlertPercent), range: 10...100, suffix: "%")
                    thresholdRow("Peak Temp", value: binding(\.temperatureAlertCelsius), range: 50...105, suffix: "°C")
                    thresholdRow("Low Battery", value: binding(\.batteryAlertPercent), range: 5...50, suffix: "%")
                    thresholdRow("Disk Free", value: binding(\.diskFreeAlertPercent), range: 2...30, suffix: "%")
                    HStack { Text("Notification Access: \(rules.notificationStatus)"); Spacer(); Button("Request") { rules.requestAuthorization() } }
                }.padding(6)
            }
            GroupBox("Privileged Fan Helper") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.helperInstalled ? "Installed: constrained by hardware RPM limits and protected by a 45-second failsafe watchdog." : "Not installed: monitoring is read-only; fan writes are disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if controller.helperInstalled {
                            Button("Remove Helper") { controller.uninstallHelper() }
                            Button("Restore All Automatic") { controller.restoreAutomatic() }
                        } else {
                            Button("Install & Enable Fan Control") { showFanWarning = true }.buttonStyle(.borderedProminent)
                        }
                        if controller.busy { ProgressView().controlSize(.small) }
                    }
                    if !controller.statusMessage.isEmpty { Text(controller.statusMessage).font(.caption) }
                }.padding(6)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Link("iStat Menus Feature Reference", destination: URL(string: "https://bjango.com/mac/istatmenus/")!)
                Spacer()
                Button("Quit StatBar") { NSApplication.shared.terminate(nil) }
            }.font(.caption)
        }
        .alert("Fan Control Requires Elevated Access", isPresented: $showFanWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Install with Safeguards") { controller.installHelper() }
        } message: {
            Text("StatBar limits RPM to the machine-reported range, rejects low speed at 95°C, and restores system control after 45 seconds without a heartbeat. Your administrator password is handled only by macOS.")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { settings.value[keyPath: keyPath] }, set: { settings.value[keyPath: keyPath] = $0 })
    }

    private func thresholdRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack { Text(title).frame(width: 74, alignment: .leading); Slider(value: value, in: range, step: 1); Text("\(Int(value.wrappedValue))\(suffix)").monospacedDigit().frame(width: 48, alignment: .trailing) }.font(.caption)
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String
    init(_ title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
    var body: some View { VStack(alignment: .leading, spacing: 2) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
}

private struct MetricCard: View {
    let title: String, value: String, icon: String
    let tint: Color
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: icon).foregroundStyle(UITheme.accent); Text(title).font(.caption).foregroundStyle(.secondary); Spacer() }
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
}

private struct HistoryChart: View {
    let points: [HistoryPoint]
    let color: Color
    let domain: ClosedRange<Double>?
    let label: String
    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.date), y: .value(label, point.value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", point.date), y: .value(label, point.value)).foregroundStyle(color).interpolationMethod(.catmullRom)
        }.chartXAxis(.hidden).chartYAxis(.hidden).ifLet(domain) { view, range in view.chartYScale(domain: range) }
    }
}

private extension View {
    func cardStyle() -> some View { self.padding(12).background(UITheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08))) }
    @ViewBuilder func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View { if let value { transform(self, value) } else { self } }
}

private func temperatureColor(_ value: Double?) -> Color {
    guard let value else { return .gray }
    if value >= 90 { return .red }
    if value >= 75 { return .orange }
    return .teal
}

private func memoryPressureName(_ level: Int) -> String {
    if level >= 4 { return "Critical Pressure" }
    if level >= 2 { return "Warning Pressure" }
    return "Normal Pressure"
}

private func memoryPressureColor(_ level: Int) -> Color {
    if level >= 4 { return .red }
    if level >= 2 { return .orange }
    return UITheme.accent
}

private func weatherIcon(_ code: Int?) -> String {
    guard let code else { return "cloud" }
    switch code { case 0: return "sun.max.fill"; case 1...3: return "cloud.sun.fill"; case 45...48: return "cloud.fog.fill"; case 51...67, 80...82: return "cloud.rain.fill"; case 71...77, 85...86: return "cloud.snow.fill"; case 95...99: return "cloud.bolt.rain.fill"; default: return "cloud.fill" }
}

private func duration(_ seconds: TimeInterval) -> String {
    let days = Int(seconds) / 86_400
    let hours = (Int(seconds) % 86_400) / 3_600
    return days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
}

@ViewBuilder private func infoRow(_ title: String, _ value: String) -> some View {
    HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.caption)
}

@ViewBuilder private func statGrid(_ values: [(String, String)]) -> some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
        ForEach(Array(values.enumerated()), id: \.offset) { _, item in
            VStack(alignment: .leading, spacing: 2) { Text(item.0).font(.caption2).foregroundStyle(.secondary); Text(item.1).font(.caption.monospacedDigit()) }
        }
    }
}
