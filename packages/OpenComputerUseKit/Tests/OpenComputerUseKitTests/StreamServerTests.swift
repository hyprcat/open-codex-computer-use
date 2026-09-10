#if canImport(JavaScriptCore)
import XCTest
@testable import OpenComputerUseKit

final class StreamServerTests: XCTestCase {
    private func decode(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testBeginFeedFinishFlow() {
        let server = OpenComputerUseStreamServer()
        XCTAssertEqual(decode(server.handle(line: #"{"op":"begin","cell":"c1"}"#))["ok"] as? Bool, true)

        let feed = decode(server.handle(line: #"{"op":"feed","cell":"c1","source":"write(\"hi\");\n"}"#))
        XCTAssertEqual(feed["completed"] as? Int, 1)
        XCTAssertEqual(feed["failed"] as? Bool, false)

        let finish = decode(server.handle(line: #"{"op":"finish","cell":"c1"}"#))
        let result = finish["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "hi")
    }

    func testDivergenceReported() {
        let server = OpenComputerUseStreamServer()
        _ = server.handle(line: #"{"op":"begin","cell":"c1"}"#)
        _ = server.handle(line: #"{"op":"feed","cell":"c1","source":"write(\"a\");\n"}"#)
        let feed = decode(server.handle(line: #"{"op":"feed","cell":"c1","source":"write(\"b\");\n"}"#))
        XCTAssertEqual(feed["failed"] as? Bool, true)
        XCTAssertTrue((feed["error"] as? String ?? "").contains("diverged"))
    }

    func testAbandonReportsResult() {
        let server = OpenComputerUseStreamServer()
        _ = server.handle(line: #"{"op":"begin","cell":"c1"}"#)
        _ = server.handle(line: #"{"op":"feed","cell":"c1","source":"write(\"a\");\n"}"#)
        let abandon = decode(server.handle(line: #"{"op":"abandon","cell":"c1"}"#))
        let result = abandon["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
    }

    func testResetOk() {
        let server = OpenComputerUseStreamServer()
        XCTAssertEqual(decode(server.handle(line: #"{"op":"reset"}"#))["ok"] as? Bool, true)
    }

    func testMalformedAndUnknown() {
        let server = OpenComputerUseStreamServer()
        XCTAssertNotNil(decode(server.handle(line: "not json"))["error"])
        XCTAssertNotNil(decode(server.handle(line: #"{"op":"nope"}"#))["error"])
        XCTAssertEqual(server.handle(line: "   "), "")
    }

    func testPersistentScopeAcrossCells() {
        let server = OpenComputerUseStreamServer()
        _ = server.handle(line: #"{"op":"begin","cell":"a"}"#)
        _ = server.handle(line: #"{"op":"finish","cell":"a","source":"globalThis.shared = 7;\n"}"#)
        _ = server.handle(line: #"{"op":"begin","cell":"b"}"#)
        let finish = decode(server.handle(line: #"{"op":"finish","cell":"b","source":"write(String(globalThis.shared));\n"}"#))
        let content = (finish["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "7")
    }
}
#endif
