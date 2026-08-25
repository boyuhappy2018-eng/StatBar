import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { save() }
    }

    private let defaultsKey = "StatBar.Settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = decoded
            if value.weatherName == "上海" { value.weatherName = "Shanghai" }
            value.worldClocks = value.worldClocks.map { clock in
                if clock.name == "上海" { return WorldClock(id: clock.id, name: "Shanghai", timeZoneID: clock.timeZoneID) }
                if clock.name == "旧金山" { return WorldClock(id: clock.id, name: "San Francisco", timeZoneID: clock.timeZoneID) }
                return clock
            }
        } else {
            value = AppSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        syncLoginItem()
    }

    private func syncLoginItem() {
        let service = SMAppService.mainApp
        do {
            if value.launchAtLogin, service.status != .enabled { try service.register() }
            if !value.launchAtLogin, service.status == .enabled { try service.unregister() }
        } catch {
            // This can fail while running an unbundled debug executable. The
            // setting is retained and retried after the app bundle launches.
        }
    }
}
