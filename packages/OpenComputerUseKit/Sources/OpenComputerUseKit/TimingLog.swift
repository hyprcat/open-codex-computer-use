import Foundation

/// Millisecond timing for the background-input and window-placement paths.
/// Enabled with `OPEN_COMPUTER_USE_DEBUG_TIMING=1`; lines go to stderr as
/// `[open-computer-use] timing <label> <ms>ms` so a tool session can be
/// profiled without changing tool output.
enum TimingLog {
    nonisolated(unsafe) static var enabled: Bool = {
        let value = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_DEBUG_TIMING"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["1", "true", "yes", "on"].contains(value)
    }()

    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static func log(_ label: String, since start: TimeInterval) {
        guard enabled else { return }
        fputs(String(format: "[open-computer-use] timing %@ %.1fms\n", label, (now() - start) * 1000), stderr)
    }

    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = now()
        defer { log(label, since: start) }
        return try body()
    }
}

/// Poll `condition` every `interval` until it holds or `timeout` elapses.
/// Returns the elapsed time when it held, or nil on timeout.
@discardableResult
func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.01, _ condition: () -> Bool) -> TimeInterval? {
    let start = TimingLog.now()
    while TimingLog.now() - start < timeout {
        if condition() {
            return TimingLog.now() - start
        }
        Thread.sleep(forTimeInterval: interval)
    }
    return nil
}
