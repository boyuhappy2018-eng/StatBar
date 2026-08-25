import AppIntents
import SwiftUI
import WidgetKit

@available(macOS 26.0, *)
struct OpenStatBarIntent: AppIntent {
    static var title: LocalizedStringResource = "Open StatBar"
    static var description = IntentDescription("Open the StatBar system dashboard.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(macOS 26.0, *)
struct OpenStatBarControl: ControlWidget {
    static let kind = "com.statbar.app.controls.open"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenStatBarIntent()) {
                Label("Open StatBar", systemImage: "fan.fill")
            }
        }
        .displayName("StatBar")
        .description("Open CPU, thermal, and fan monitoring.")
    }
}

@main
@available(macOS 26.0, *)
struct StatBarControlsBundle: WidgetBundle {
    var body: some Widget {
        OpenStatBarControl()
    }
}
