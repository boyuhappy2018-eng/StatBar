import AppKit
import CHIDBridge
import Combine
import SwiftUI

private extension Notification.Name {
    static let statBarShowDashboard = Notification.Name("com.statbar.app.show-dashboard")
}

@MainActor
private final class StatusMetricsView: NSView {
    var temperature = "—°" { didSet { needsDisplay = true } }
    var temperatureCelsius: Double? { didSet { needsDisplay = true } }
    var fan1 = "—" { didSet { needsDisplay = true } }
    var fan2 = "—" { didSet { needsDisplay = true } }

    var requiredWidth: CGFloat {
        let temperatureFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let fanFont = fanDisplayFont
        let temperatureWidth = ceil((temperature as NSString).size(withAttributes: [.font: temperatureFont]).width) + 3
        let fanWidth = ceil(max(
            ("F1 \(fan1)" as NSString).size(withAttributes: [.font: fanFont]).width,
            ("F2 \(fan2)" as NSString).size(withAttributes: [.font: fanFont]).width
        )) + 3
        return min(84, max(54, temperatureWidth + fanWidth + 8))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let height = bounds.height
        let temperatureFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let fanFont = fanDisplayFont
        let temperatureWidth = ceil((temperature as NSString).size(withAttributes: [.font: temperatureFont]).width) + 3
        let dividerX = temperatureWidth + 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let temperatureAttributes: [NSAttributedString.Key: Any] = [
            .font: temperatureFont,
            .foregroundColor: temperatureColor,
            .paragraphStyle: paragraph
        ]
        let fanAttributes: [NSAttributedString.Key: Any] = [
            .font: fanFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let temperatureRect = NSRect(x: 1, y: (height - 15) / 2, width: temperatureWidth, height: 15)
        temperature.draw(in: temperatureRect, withAttributes: temperatureAttributes)

        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(x: dividerX, y: 3, width: 1, height: max(0, height - 6)).fill()

        let rightX = dividerX + 3
        let rightWidth = max(0, bounds.width - rightX - 1)
        "F1 \(fan1)".draw(in: NSRect(x: rightX, y: height / 2, width: rightWidth, height: 10), withAttributes: fanAttributes)
        "F2 \(fan2)".draw(in: NSRect(x: rightX, y: max(0, height / 2 - 9), width: rightWidth, height: 10), withAttributes: fanAttributes)
    }

    private var fanDisplayFont: NSFont {
        let digits = max(fan1.count, fan2.count)
        let size: CGFloat
        switch digits {
        case 0...1: size = 9.5
        case 2: size = 9.1
        case 3: size = 8.7
        case 4: size = 8.2
        default: size = 7.6
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }

    private var temperatureColor: NSColor {
        guard let temperatureCelsius else { return .secondaryLabelColor }
        if temperatureCelsius >= 85 { return .systemRed }
        if temperatureCelsius >= 70 { return .systemOrange }
        return .labelColor
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var monitor = SystemMonitor(settings: settings)
    private lazy var fanController = FanController(settings: settings)
    private lazy var rules = RuleEngine(settings: settings)
    private let calendar = CalendarStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var displayTimer: Timer?
    private var ruleTimer: Timer?
    private var dashboardWindow: NSWindow?
    private let statusMetricsView = StatusMetricsView()

    static func main() {
        if CommandLine.arguments.contains("--diagnose-hid") {
            let temperatures = SBAppleSiliconSensors(0xff00, 0x0005, 15) ?? [:]
            var values = temperatures.mapValues(\.doubleValue)
            for (key, value) in SBHIDDiagnostics(0xff00, 0x0005, 15) { values["_\(key)"] = value.doubleValue }
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            return
        }

        // The build product and the installed app share a bundle identifier. Without
        // this guard, opening both creates two independent menu-bar monitors.
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           let runningInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().post(
                name: .statBarShowDashboard,
                object: bundleIdentifier,
                userInfo: nil
            )
            runningInstance.activate(options: [])
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(CommandLine.arguments.contains("--show-window") ? .regular : .accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(revealExistingInstance(_:)),
            name: .statBarShowDashboard,
            object: Bundle.main.bundleIdentifier
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            statusItem.length = 84
            button.image = nil
            button.title = ""
            statusMetricsView.frame = button.bounds
            statusMetricsView.autoresizingMask = [.width, .height]
            button.addSubview(statusMetricsView)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.behavior = [.removalAllowed, .terminationOnRemoval]

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 600, height: 680)
        popover.contentViewController = NSHostingController(rootView: DashboardView(
            monitor: monitor, settings: settings, fanController: fanController,
            rules: rules, calendar: calendar, initialTab: requestedTab
        ))

        fanController.attach(monitor: monitor)
        monitor.start()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        ruleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rules.evaluate(self.monitor)
            }
        }
        updateStatusItem()
        if CommandLine.arguments.contains("--show-window") {
            showDashboardWindow()
        } else if !UserDefaults.standard.bool(forKey: "StatBar.didShowFirstLaunchDashboard") {
            UserDefaults.standard.set(true, forKey: "StatBar.didShowFirstLaunchDashboard")
            showDashboardWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboardWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        fanController.restoreOnExit()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Restore Automatic Fan Control", action: #selector(restoreFans), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit StatBar", action: #selector(quit), keyEquivalent: "q")
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func restoreFans() { fanController.restoreAutomatic() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func revealExistingInstance(_ notification: Notification) { showDashboardWindow() }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let temperature = monitor.hottestTemperature.map { String(format: "%.1f°", $0) } ?? "—°"
        let fan1 = monitor.fans.indices.contains(0) ? "\(Int(monitor.fans[0].currentRPM))" : "—"
        let fan2 = monitor.fans.indices.contains(1) ? "\(Int(monitor.fans[1].currentRPM))" : "—"
        statusMetricsView.temperature = temperature
        statusMetricsView.temperatureCelsius = monitor.hottestTemperature
        statusMetricsView.fan1 = fan1
        statusMetricsView.fan2 = fan2
        let fittedLength = statusMetricsView.requiredWidth
        if abs(statusItem.length - fittedLength) > 0.5 {
            statusItem.length = fittedLength
        }
        button.toolTip = "StatBar — Click for details, right-click for safety controls"
    }

    private func showDashboardWindow() {
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = CommandLine.arguments.contains("--capture") ? "StatBar Visual Review" : "StatBar"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DashboardView(
            monitor: monitor, settings: settings, fanController: fanController,
            rules: rules, calendar: calendar, initialTab: requestedTab
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow = window
        captureTestWindowIfRequested(window)
    }

    private func captureTestWindowIfRequested(_ window: NSWindow) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--capture"), arguments.indices.contains(flag + 1) else { return }
        let outputURL = URL(fileURLWithPath: arguments[flag + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: outputURL, options: .atomic)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private var requestedTab: String {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--tab"), arguments.indices.contains(flag + 1) else { return "overview" }
        return arguments[flag + 1]
    }
}
