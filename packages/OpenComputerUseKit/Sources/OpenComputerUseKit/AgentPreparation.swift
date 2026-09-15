import AppKit
import ApplicationServices
import Foundation

/// Preparing an app to be worked on without taking over the user's screen: the
/// window is moved to the agent display, and put back where they had it afterwards.
enum AgentPreparation {
    /// One window of an app, as the parking path needs it.
    struct PreparedWindow {
        let windowID: CGWindowID
        let element: AXUIElement
    }

    static func display() throws -> ToolCallResult {
        let bounds = try AgentDisplay.shared.prepare()
        return try json(["version": 1, "display_id": AgentDisplay.shared.displayID,
                         "width": Int(bounds.width), "height": Int(bounds.height)])
    }

    static func app(query: String, newWindow: Bool) throws -> ToolCallResult {
        let app = try AppDiscovery.resolve(query, activate: false)
        let visible = currentWindow(pid: app.pid)
        let front = SkyLightSPI.shared.frontProcess()
        // Opening a window may bring the app forward; focus goes back to where it was on every exit.
        defer {
            if let front, !SkyLightSPI.shared.restoreFrontProcess(front) {
                TimingLog.note("prepare_app could not restore the front process")
            }
        }
        let before = windowIDs(pid: app.pid)
        var opened = false
        let prepared: PreparedWindow
        if newWindow && app.runningApplication.isFinishedLaunching {
            // The user's own windows stay where they are: only the window opened here is parked,
            // even when none of theirs is on this Space (the menu bar needs no window).
            try SkyKeyboardDispatcher.pressNewWindow(pid: app.pid, appName: app.name)
            opened = true
            prepared = try awaitWindow(app: app, excluding: visible?.windowID)
        } else {
            // A window in its own full-screen Space is the user's to keep: reopening would switch
            // them to that Space, and a full-screen window cannot be moved to the agent display.
            if inFullScreen(pid: app.pid, windowID: visible?.windowID) {
                throw ComputerUseError.stateUnavailable("\(app.name) is in full screen; it is left alone")
            }
            if visible == nil {
                if app.runningApplication.isFinishedLaunching {
                    // Running with no open window: the reopen a Dock click sends brings a closed window back.
                    try AppDiscovery.reopen(app)
                    opened = true
                } else {
                    try AppDiscovery.launchIfPossible(query, activate: false)
                }
            }
            prepared = try awaitWindow(app: app)
        }

        try AgentDisplay.shared.park(windowID: prepared.windowID, pid: app.pid, window: prepared.element)
        // A window the agent opened (Dock reopen or New Window) that did not exist before is closed
        // when restored; marked as soon as it is parked, so a failure below still ends with it closed.
        // Reopen can also un-minimize or raise a window the user already had; that one comes back
        // open, not re-minimized: they asked for work in it, and restore only moves frames. A window
        // that appeared because the app was launched is left to the app.
        if opened, !before.contains(prepared.windowID) {
            AgentDisplay.shared.closeWhenRestored(prepared.windowID)
        }
        return try json(["app": app.bundleIdentifier ?? app.name, "name": app.name,
                         "window_id": Int(prepared.windowID)])
    }

    /// The app's current window, read-only: no activation, no raise, no capture.
    private static func currentWindow(pid: pid_t) -> PreparedWindow? {
        let appElement = AXUIElementCreateApplication(pid)
        let candidates = [copyElement(appElement, kAXFocusedWindowAttribute)]
            .compactMap { $0 } + (copyValue(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? [])
        for window in candidates {
            if let id = SkyLightSPI.shared.windowID(for: window) {
                return PreparedWindow(windowID: id, element: window)
            }
        }
        return nil
    }

    /// The app's document-level windows on any Space, minimized or not.
    private static func windowIDs(pid: pid_t) -> [CGWindowID] {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
    }

    /// Whether `windowID`, or any window of the app when nil, sits in a full-screen Space.
    private static func inFullScreen(pid: pid_t, windowID: CGWindowID?) -> Bool {
        let fullScreen = SkyLightSPI.shared.fullScreenSpaces()
        guard !fullScreen.isEmpty else { return false }
        return windowIDs(pid: pid).contains { id in
            guard windowID == nil || windowID == id, let spaces = SkyLightSPI.shared.spaces(forWindow: id) else { return false }
            return spaces.contains(where: fullScreen.contains)
        }
    }

    private static func awaitWindow(app: RunningAppDescriptor, excluding: CGWindowID? = nil) throws -> PreparedWindow {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let window = currentWindow(pid: app.pid), window.windowID != excluding { return window }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw ComputerUseError.stateUnavailable("The requested window did not open in \(app.name)")
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func json(_ value: Any) throws -> ToolCallResult {
        .text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}
