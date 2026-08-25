import EventKit
import Foundation
import UserNotifications

@MainActor
final class RuleEngine: ObservableObject {
    @Published private(set) var notificationStatus = "Not Requested"
    private let settings: SettingsStore
    private var firstExceeded: [String: Date] = [:]
    private var lastNotification: [String: Date] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
        refreshAuthorizationStatus()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notificationStatus = granted ? "Allowed" : "Not Allowed" }
        }
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] value in
            let label: String
            switch value.authorizationStatus {
            case .authorized, .provisional: label = "Allowed"
            case .denied: label = "Denied"
            default: label = "Not Requested"
            }
            DispatchQueue.main.async { self?.notificationStatus = label }
        }
    }

    func evaluate(_ monitor: SystemMonitor) {
        guard settings.value.rulesEnabled else { return }
        check(key: "cpu", condition: monitor.cpuUsage >= settings.value.cpuAlertPercent, duration: 10,
              title: "Sustained CPU Load", body: String(format: "CPU usage is %.0f%%", monitor.cpuUsage))
        if let temperature = monitor.hottestTemperature {
            check(key: "temperature", condition: temperature >= settings.value.temperatureAlertCelsius, duration: 2,
                  title: "Temperature Alert", body: String(format: "Highest sensor temperature is %.1f°C", temperature))
        }
        if let battery = monitor.battery, !battery.isCharging {
            check(key: "battery", condition: battery.percent <= settings.value.batteryAlertPercent, duration: 2,
                  title: "Low Battery", body: String(format: "%.0f%% remaining", battery.percent))
        }
        if let root = monitor.disks.first(where: { $0.path == "/" }) {
            let freePercent = root.total > 0 ? Double(root.free) / Double(root.total) * 100 : 100
            check(key: "disk", condition: freePercent <= settings.value.diskFreeAlertPercent, duration: 2,
                  title: "Low Disk Space", body: String(format: "System disk has %.1f%% free", freePercent))
        }
        check(key: "network", condition: !monitor.network.online, duration: 15,
              title: "Network Offline", body: "The active network interface has no IPv4 address.")
    }

    private func check(key: String, condition: Bool, duration: TimeInterval, title: String, body: String) {
        guard condition else { firstExceeded[key] = nil; return }
        let now = Date()
        if firstExceeded[key] == nil { firstExceeded[key] = now }
        guard now.timeIntervalSince(firstExceeded[key] ?? now) >= duration,
              now.timeIntervalSince(lastNotification[key] ?? .distantPast) >= 15 * 60 else { return }
        lastNotification[key] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "StatBar.\(key).\(now.timeIntervalSince1970)",
                                                                       content: content, trigger: nil))
    }
}

struct CalendarEventItem: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
}

@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var events = [CalendarEventItem]()
    @Published private(set) var authorization = "Not Requested"
    private let store = EKEventStore()

    func requestAccess() {
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                authorization = granted ? "Allowed" : "Not Allowed"
                if granted { refresh() }
            } catch {
                authorization = error.localizedDescription
            }
        }
    }

    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            authorization = status == .denied ? "Denied" : "Not Requested"
            return
        }
        authorization = "Allowed"
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .prefix(20).map { CalendarEventItem(id: $0.eventIdentifier ?? UUID().uuidString,
                                                title: $0.title ?? "Untitled Event", start: $0.startDate,
                                                end: $0.endDate, allDay: $0.isAllDay) }
    }
}
