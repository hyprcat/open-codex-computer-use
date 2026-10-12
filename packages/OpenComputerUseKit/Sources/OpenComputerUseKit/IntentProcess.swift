import Foundation
import Darwin

/// Bounded child execution. Never waits for EOF or trusts SIGTERM to finish a child.
struct IntentProcessResult {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32?
    let failure: String?
    var succeeded: Bool { failure == nil && exitCode == 0 }
    var diagnostic: String { String(decoding: stderr.prefix(8192), as: UTF8.self) }
}

enum IntentProcess {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval,
                    maximumBytes: Int = 131072) -> IntentProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        // No process injection variables may alter the fixed Apple executables.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        do { try process.run() } catch {
            return .init(stdout: Data(), stderr: Data(), exitCode: nil, failure: "launch_failed")
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = error.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(errFD, F_SETFL, fcntl(errFD, F_GETFL) | O_NONBLOCK)
        defer { try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close() }
        var stdout = Data(), stderr = Data()
        var failure: String?
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain(_ fd: Int32, into data: inout Data, remaining: Int) {
            let initialCount = data.count
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                guard count > 0 else { break }
                let room = max(0, remaining - data.count + initialCount)
                data.append(contentsOf: buffer.prefix(min(count, room)))
                if count > room { failure = "output_limit"; break }
            }
        }
        while true {
            drain(outFD, into: &stdout, remaining: max(0, maximumBytes - stdout.count - stderr.count))
            drain(errFD, into: &stderr, remaining: max(0, maximumBytes - stdout.count - stderr.count))
            if failure != nil { break }
            if !process.isRunning { break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = "timeout"; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if failure != nil && process.isRunning {
            process.terminate()
            let graceful = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < graceful { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            let killed = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killed { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard !process.isRunning else {
            return .init(stdout: stdout, stderr: stderr, exitCode: nil, failure: failure ?? "termination_unconfirmed")
        }
        process.waitUntilExit()
        if failure == nil {
            drain(outFD, into: &stdout, remaining: max(0, maximumBytes - stdout.count - stderr.count))
            drain(errFD, into: &stderr, remaining: max(0, maximumBytes - stdout.count - stderr.count))
        }
        return .init(stdout: stdout, stderr: stderr,
                     exitCode: process.terminationReason == .exit ? process.terminationStatus : nil,
                     failure: failure ?? (process.terminationReason == .exit ? nil : "terminated"))
    }
}
