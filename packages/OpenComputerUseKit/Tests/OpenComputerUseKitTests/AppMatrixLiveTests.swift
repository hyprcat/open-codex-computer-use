import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Opt-in survey across whatever GUI apps are running: snapshot each app
/// without activating it, then, when it exposes an EMPTY text or search field,
/// sky_click that field, sky_key a marker into it, verify the marker via a
/// fresh snapshot, and delete exactly the marker again. Prints one row per app
/// and never asserts per app; the only assertion is that the frontmost app is
/// unchanged at the end. Set OPEN_COMPUTER_USE_APP_MATRIX_SKIP to a comma list
/// of app names to exclude.
@MainActor
final class AppMatrixLiveTests: XCTestCase {
    func testSurveyRunningApps() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_APP_MATRIX"] == "1" else { throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_APP_MATRIX=1") }
        setvbuf(stdout, nil, _IONBF, 0)
        let spi = SkyLightSPI.shared
        let skip = Set((ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_APP_MATRIX_SKIP"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontBefore = NSWorkspace.shared.frontmostApplication
        let marker = "zq7x"
        var rows: [String] = []
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.processIdentifier != ownPID && app.processIdentifier != frontBefore?.processIdentifier
                && !skip.contains((app.localizedName ?? "").lowercased())
        }
        for app in apps {
            let name = app.localizedName ?? "pid \(app.processIdentifier)"
            let engine = appHasLazyWebAccessibility(bundleURL: app.bundleURL) ? "chromium" : (appLooksWebKit(app) ? "webkit" : "native")
            let descriptor = RunningAppDescriptor(name: name, bundleIdentifier: app.bundleIdentifier, pid: app.processIdentifier, runningApplication: app)
            let t0 = TimingLog.now()
            let snapshot: AppSnapshot
            do {
                snapshot = try SnapshotBuilder.build(for: descriptor, recoveryPolicy: .readOnly)
            } catch {
                rows.append(row(name, engine, "snapshot FAILED: \(short(error))"))
                continue
            }
            let snapMs = Int((TimingLog.now() - t0) * 1000)
            let nodes = snapshot.elements.count
            let hasWeb = snapshot.treeLines.contains { $0.contains("HTML content") }
            let covered = snapshot.treeLines.contains { $0.hasPrefix("Note: this window is covered") }
            let shot = snapshot.screenshotPNGData?.count ?? 0
            guard let windowID = snapshot.targetWindowID, let bounds = snapshot.windowBounds else {
                rows.append(row(name, engine, "snapshot ok nodes=\(nodes) web=\(hasWeb) shot=\(shot)B \(snapMs)ms; no window id"))
                continue
            }
            var detail = "snapshot \(snapMs)ms nodes=\(nodes) web=\(hasWeb) covered=\(covered) shot=\(shot)B"
            // Find an empty text/search field.
            let candidates = snapshot.elements.values.filter { record in
                guard let role = record.role, let element = record.element else { return false }
                guard role == kAXTextFieldRole as String || role == "AXSearchField" || role == kAXTextAreaRole as String || role == kAXComboBoxRole as String else { return false }
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                let text = (value as? String) ?? ""
                guard text.isEmpty, let frame = record.localFrame, frame.width >= 40, frame.height >= 12 else { return false }
                // Popover children carry frames outside the window; sky_click rejects those by design.
                return CGRect(origin: .zero, size: bounds.size).contains(CGPoint(x: frame.midX, y: frame.midY))
            }.sorted { ($0.role == "AXSearchField" ? 0 : 1, $0.index) < ($1.role == "AXSearchField" ? 0 : 1, $1.index) }
            guard let field = candidates.first, let frame = field.localFrame else {
                rows.append(row(name, engine, detail + "; no empty text field -> no input test"))
                continue
            }
            let windowPoint = CGPoint(x: frame.midX, y: frame.midY)
            let screenPoint = CGPoint(x: bounds.minX + windowPoint.x, y: bounds.minY + windowPoint.y)
            let target = SkyKeyboardTarget(windowID: windowID, pid: app.processIdentifier)
            do {
                let c0 = TimingLog.now()
                try SkyClickDispatcher.click(target: SkyClickTarget(screenPoint: screenPoint, windowPoint: windowPoint, windowBounds: bounds, windowID: windowID, pid: app.processIdentifier), clickCount: 1, spi: spi)
                let k0 = TimingLog.now()
                try SkyKeyboardDispatcher.typeText(target: target, text: marker, spi: spi)
                let kMs = Int((TimingLog.now() - k0) * 1000)
                Thread.sleep(forTimeInterval: 0.3)
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(field.element!, kAXValueAttribute as CFString, &value)
                let inField = ((value as? String) ?? "").contains(marker)
                // Some search bars open an overlay: look for the marker anywhere in a fresh tree.
                let afterSnapshot = try? SnapshotBuilder.build(for: descriptor, recoveryPolicy: .readOnly)
                let inTree = afterSnapshot?.treeLines.contains { $0.contains(marker) } ?? false
                for _ in 0..<marker.count { try SkyKeyboardDispatcher.pressKey(target: target, key: "backspace", spi: spi) }
                Thread.sleep(forTimeInterval: 0.2)
                let clearedSnapshot = try? SnapshotBuilder.build(for: descriptor, recoveryPolicy: .readOnly)
                let cleared = !(clearedSnapshot?.treeLines.contains { $0.contains(marker) } ?? true)
                detail += "; field=\(field.role ?? "?")#\(field.index) click+type \(Int((TimingLog.now() - c0) * 1000))ms (type \(kMs)ms) typedInField=\(inField) typedInTree=\(inTree) cleared=\(cleared)"
            } catch {
                detail += "; input FAILED: \(short(error))"
            }
            rows.append(row(name, engine, detail))
        }
        print("MATRIX frontmost=\(frontBefore?.localizedName ?? "?") apps=\(apps.count)")
        rows.forEach { print($0) }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontBefore?.processIdentifier, "the survey must not change the frontmost app")
        WindowOcclusionKeepAlive.shared.releaseAll()
    }

    private func row(_ name: String, _ engine: String, _ detail: String) -> String { "MATRIX \(name) [\(engine)] \(detail)" }
    private func short(_ error: Error) -> String { String(((error as? ComputerUseError)?.errorDescription ?? "\(error)").prefix(90)) }
    private func appLooksWebKit(_ app: NSRunningApplication) -> Bool {
        (app.bundleIdentifier ?? "").lowercased().contains("safari")
    }
}
