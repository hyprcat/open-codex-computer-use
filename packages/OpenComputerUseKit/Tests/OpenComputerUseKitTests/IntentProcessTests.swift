import XCTest
import Darwin
@testable import OpenComputerUseKit

final class IntentProcessTests: XCTestCase {
    func testNormalOutputExitCodeAndLaunchFailure() {
        let result = IntentProcess.run("/bin/sh", ["-c", "printf output; printf diagnostic >&2; exit 7"], timeout: 1)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "output")
        XCTAssertEqual(result.diagnostic, "diagnostic")
        XCTAssertEqual(result.exitCode, 7); XCTAssertFalse(result.succeeded)
        XCTAssertEqual(IntentProcess.run("/nonexistent/ocu-test", [], timeout: 1).failure, "launch_failed")
    }
    func testIgnoringTermCannotHangTimeout() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = IntentProcess.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertEqual(result.failure, "timeout")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testContinuousOutputIsBounded() {
        let result = IntentProcess.run("/usr/bin/yes", ["fixture"], timeout: 1, maximumBytes: 16384)
        XCTAssertEqual(result.failure, "output_limit")
        XCTAssertLessThanOrEqual(result.stdout.count + result.stderr.count, 16384)
    }
    func testNonRegularFilesAndSymlinksCannotBlockReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-intent-file-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("regular"), link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try Data("bounded output".utf8).write(to: file)
        XCTAssertEqual(try IntentFile.readPrefix(file, maximum: 7), Data("bounded".utf8))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try IntentFile.readPrefix(link, maximum: 10))
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try IntentFile.readPrefix(fifo, maximum: 10))
    }
    func testInheritedPipeDoesNotRequireEOF() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = IntentProcess.run("/bin/sh", ["-c", "sleep 1 & printf done"], timeout: 0.2)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
    }
}
