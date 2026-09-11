#if canImport(JavaScriptCore)
import XCTest
@testable import OpenComputerUseKit

final class PiBridgeServerTests: XCTestCase {
    private func decode(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testFinalSourceRunsAndReportsOutputThenTerminal() {
        let bridge = OpenComputerUsePiBridgeServer()
        let out = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"hi\");\n","final":true}"#)
        let frames = out.map(decode)
        XCTAssertEqual(frames.first(where: { $0["type"] as? String == "output" })?["text"] as? String, "hi")
        let terminal = frames.first(where: { $0["type"] as? String == "terminal" })
        XCTAssertEqual(terminal?["status"] as? String, "done")
    }

    func testStreamingReportsDonePerStatementThenFinishes() {
        let bridge = OpenComputerUsePiBridgeServer()
        let feed = bridge.handle(line: #"{"op":"source","cell":"c1","source":"globalThis.x = 1;\n","final":false}"#).map(decode)
        XCTAssertEqual(feed.first(where: { $0["type"] as? String == "done" })?["index"] as? Int, 0)

        let final = bridge.handle(line: #"{"op":"source","cell":"c1","source":"globalThis.x = 1;\nwrite(String(globalThis.x));\n","final":true}"#).map(decode)
        XCTAssertEqual(final.first(where: { $0["type"] as? String == "output" })?["text"] as? String, "1")
        XCTAssertEqual(final.first(where: { $0["type"] as? String == "terminal" })?["status"] as? String, "done")
    }

    func testDivergenceFailsCell() {
        let bridge = OpenComputerUsePiBridgeServer()
        _ = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"a\");\n","final":false}"#)
        let out = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"b\");\n","final":false}"#).map(decode)
        let terminal = out.first(where: { $0["type"] as? String == "terminal" })
        XCTAssertEqual(terminal?["status"] as? String, "failed")
        XCTAssertTrue((terminal?["error"] as? String ?? "").contains("diverged"))
    }

    func testAbandonEmitsFailedTerminal() {
        let bridge = OpenComputerUsePiBridgeServer()
        _ = bridge.handle(line: #"{"op":"source","cell":"c1","source":"globalThis.y = 2;\n","final":false}"#)
        let out = bridge.handle(line: #"{"op":"abandon","cell":"c1"}"#).map(decode)
        let terminal = out.first(where: { $0["type"] as? String == "terminal" })
        XCTAssertEqual(terminal?["status"] as? String, "failed")
        XCTAssertTrue((terminal?["error"] as? String ?? "").contains("abandoned"))
    }

    func testClosedCellIgnoresLateFrames() {
        let bridge = OpenComputerUsePiBridgeServer()
        _ = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"x\");\n","final":true}"#)
        XCTAssertTrue(bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"x\");\nwrite(\"y\");\n","final":true}"#).isEmpty)
    }

    func testMalformedIgnored() {
        let bridge = OpenComputerUsePiBridgeServer()
        XCTAssertTrue(bridge.handle(line: "not json").isEmpty)
        XCTAssertTrue(bridge.handle(line: #"{"op":"nope"}"#).isEmpty)
    }
}
#endif
