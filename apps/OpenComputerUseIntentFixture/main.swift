import AppKit
import SwiftUI
import AppIntents
import Foundation

struct EchoParametersIntent: AppIntent {
    static var title: LocalizedStringResource = "Echo OCU test parameters"
    static var description = IntentDescription("Returns the supplied parameters as JSON for isolated OCU integration tests.")
    static var openAppWhenRun = false
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Count") var count: Int
    @Parameter(title: "Enabled") var enabled: Bool
    @Parameter(title: "Ratio") var ratio: Double

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let value: [String: Any] = ["text": text, "count": count, "enabled": enabled, "ratio": ratio]
        let result = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-intent-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try result.write(to: directory.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
        return .result(value: result)
    }
}

struct FixtureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: EchoParametersIntent(), phrases: ["Echo parameters with \(.applicationName)"], shortTitle: "Echo parameters", systemImageName: "checkmark.circle")
    }
}

@main
struct IntentFixtureApp: App {
    init() { FixtureShortcuts.updateAppShortcutParameters() }
    var body: some Scene {
        WindowGroup { Text("Isolated OCU App Intent test fixture").padding() }
    }
}
