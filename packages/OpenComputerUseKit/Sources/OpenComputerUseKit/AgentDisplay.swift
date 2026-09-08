import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenComputerUseVirtualDisplayShim

public enum WindowPlacement: String, CaseIterable, Sendable {
    case keep
    case agentDisplay = "agent_display"
    case restore
}

func parseWindowPlacement(_ rawValue: String?) throws -> WindowPlacement {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? WindowPlacement.keep.rawValue

    guard let placement = WindowPlacement(rawValue: normalized) else {
        let expected = WindowPlacement.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid window_placement '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return placement
}

/// Where a parked window goes on the agent display: inset from the top-left
/// corner, clamped so at least the top-left `minVisible` points stay inside the
/// display when the window is larger than it.
func agentDisplayPlacement(windowSize: CGSize, displayBounds: CGRect, inset: CGFloat = 40, minVisible: CGFloat = 200) -> CGPoint {
    let maxX = max(displayBounds.minX, displayBounds.maxX - max(windowSize.width, minVisible))
    let maxY = max(displayBounds.minY, displayBounds.maxY - max(windowSize.height, minVisible))
    return CGPoint(
        x: min(displayBounds.minX + inset, maxX),
        y: min(displayBounds.minY + inset, maxY)
    )
}

/// The agent's own display: a virtual display (the mechanism behind Screen
/// Sharing's headless sessions) that the user never sees. A window parked on it
/// is genuinely on screen for WindowServer, so its app renders it, exposes its
/// full accessibility tree and accepts input, while the user's Space, foreground
/// app and pointer are untouched. Parking moves the window's frame (AX
/// position, no activation); the original position is restored on `restore`
/// and at process exit, and the display is removed once nothing is parked.
final class AgentDisplay: @unchecked Sendable {
    static let shared = AgentDisplay()

    static let displaySize = CGSize(width: 1920, height: 1080)
    // ponytail: fixed waits for the display and the window move to settle.
    static let displaySettle: TimeInterval = 2.0
    static let moveSettle: TimeInterval = 1.0

    struct ParkedWindow {
        let pid: pid_t
        let element: AXUIElement
        let originalPosition: CGPoint
    }

    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private(set) var displayID: CGDirectDisplayID = 0
    private var parked: [CGWindowID: ParkedWindow] = [:]
    private var exitHookInstalled = false

    var isSupported: Bool {
        ocu_virtual_display_is_supported() != 0
    }

    var displayBounds: CGRect? {
        displayID == 0 ? nil : CGDisplayBounds(displayID)
    }

    func isParked(windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parked[windowID] != nil
    }

    func parkedWindowIDs(pid: pid_t) -> [CGWindowID] {
        lock.lock()
        defer { lock.unlock() }
        return parked.filter { $0.value.pid == pid }.map(\.key)
    }

    /// Move `window` onto the agent display. Returns the display bounds.
    @discardableResult
    func park(windowID: CGWindowID, pid: pid_t, window: AXUIElement) throws -> CGRect {
        lock.lock()
        defer { lock.unlock() }

        let bounds = try ensureDisplay()
        if parked[windowID] != nil {
            return bounds
        }

        guard let position = axPoint(window, kAXPositionAttribute as String) else {
            throw ComputerUseError.stateUnavailable("window_placement 'agent_display' could not read the window position")
        }
        let size = axSize(window) ?? CGSize(width: 800, height: 600)
        let target = agentDisplayPlacement(windowSize: size, displayBounds: bounds)
        try setAXPosition(window, target)
        parked[windowID] = ParkedWindow(pid: pid, element: window, originalPosition: position)
        installExitHookIfNeeded()
        Thread.sleep(forTimeInterval: Self.moveSettle)
        return bounds
    }

    /// Put a parked window back where it was.
    func restore(windowID: CGWindowID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = parked.removeValue(forKey: windowID) else {
            return
        }
        try setAXPosition(entry.element, entry.originalPosition)
        Thread.sleep(forTimeInterval: Self.moveSettle)
        destroyDisplayIfIdle()
    }

    func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        for entry in parked.values {
            try? setAXPosition(entry.element, entry.originalPosition)
        }
        if !parked.isEmpty {
            Thread.sleep(forTimeInterval: Self.moveSettle)
        }
        parked.removeAll()
        destroyDisplayIfIdle()
    }

    // MARK: - Display lifecycle (call with lock held)

    private func ensureDisplay() throws -> CGRect {
        if displayID != 0, let bounds = displayBounds, !bounds.isEmpty {
            return bounds
        }
        guard isSupported else {
            throw ComputerUseError.message("window_placement 'agent_display' is unavailable: CGVirtualDisplay is not present on this macOS")
        }
        var newHandle: UnsafeMutableRawPointer?
        let id = ocu_virtual_display_create("Open Computer Use", UInt32(Self.displaySize.width), UInt32(Self.displaySize.height), 60, &newHandle)
        guard id != 0, let newHandle else {
            throw ComputerUseError.message("window_placement 'agent_display' could not create the agent display")
        }
        handle = newHandle
        displayID = id
        let deadline = Date().addingTimeInterval(Self.displaySettle)
        while Date() < deadline {
            if let bounds = displayBounds, !bounds.isEmpty {
                // Let WindowServer finish adding the display's Space before parking.
                Thread.sleep(forTimeInterval: 0.5)
                return bounds
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        destroyDisplay()
        throw ComputerUseError.message("window_placement 'agent_display' timed out waiting for the agent display")
    }

    private func destroyDisplayIfIdle() {
        if parked.isEmpty {
            destroyDisplay()
        }
    }

    private func destroyDisplay() {
        if let handle {
            ocu_virtual_display_destroy(handle)
        }
        handle = nil
        displayID = 0
    }

    private func installExitHookIfNeeded() {
        guard !exitHookInstalled else { return }
        exitHookInstalled = true
        atexit {
            AgentDisplay.shared.restoreAll()
        }
    }

    // MARK: - AX helpers

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func setAXPosition(_ element: AXUIElement, _ point: CGPoint) throws {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else {
            throw ComputerUseError.message("could not encode the window position")
        }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard result == .success else {
            throw ComputerUseError.stateUnavailable("window_placement could not move the window (AXError \(result.rawValue))")
        }
    }
}
