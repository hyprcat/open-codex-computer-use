import Foundation

/// The feeder-integration server: a newline-delimited JSON (JSONL) protocol over
/// stdio that lets an agent runtime drive the `js` streaming engine as the model's
/// tool call streams. One process is one persistent runtime session. See
/// docs/references/js-stream-protocol.md for the wire contract.
///
/// Requests (feeder -> runtime), one JSON object per line, each with `op`:
///   {"op":"begin","cell":"<id>"}
///   {"op":"feed","cell":"<id>","source":"<full code so far>"}
///   {"op":"finish","cell":"<id>","source":"<final code>"}   // source optional
///   {"op":"abandon","cell":"<id>"}
///   {"op":"reset"}
/// Responses (runtime -> feeder), one JSON object per line, echoing `op` and `cell`.
public final class OpenComputerUseStreamServer {
    private let dispatcher: ComputerUseToolDispatcher

    public init(service: ComputerUseService = ComputerUseService()) {
        self.dispatcher = ComputerUseToolDispatcher(service: service)
    }

    public init(dispatcher: ComputerUseToolDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Handle one request line and return one response line (no trailing newline).
    /// Empty input returns an empty string (nothing to emit).
    public func handle(line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let data = trimmed.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let op = object["op"] as? String else {
            return Self.encode(["error": "each request must be a JSON object with an \"op\""])
        }

        let cell = object["cell"] as? String
        switch op {
        case "begin":
            guard let cell else { return Self.encode(["op": op, "error": "begin requires \"cell\""]) }
            dispatcher.streamBegin(id: cell)
            return Self.encode(["op": "begin", "cell": cell, "ok": true])
        case "feed":
            guard let cell, let source = object["source"] as? String else {
                return Self.encode(["op": op, "error": "feed requires \"cell\" and \"source\""])
            }
            let progress = dispatcher.streamFeed(id: cell, source: source)
            return Self.encode([
                "op": "feed",
                "cell": cell,
                "completed": progress.completed,
                "failed": progress.failed,
                "error": progress.error ?? NSNull(),
            ])
        case "finish":
            guard let cell else { return Self.encode(["op": op, "error": "finish requires \"cell\""]) }
            let result = dispatcher.streamFinish(id: cell, source: object["source"] as? String)
            return Self.encode(["op": "finish", "cell": cell, "result": result.asDictionary])
        case "abandon":
            guard let cell else { return Self.encode(["op": op, "error": "abandon requires \"cell\""]) }
            let result = dispatcher.streamAbandon(id: cell)
            return Self.encode(["op": "abandon", "cell": cell, "result": result.asDictionary])
        case "reset":
            dispatcher.streamReset()
            return Self.encode(["op": "reset", "ok": true])
        default:
            return Self.encode(["error": "unknown op: \(op)"])
        }
    }

    /// Read requests from stdin line by line and write responses to stdout,
    /// unbuffered, until stdin closes.
    public func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        while let line = readLine(strippingNewline: true) {
            let response = handle(line: line)
            if !response.isEmpty {
                print(response)
            }
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"failed to encode response\"}"
        }
        return text
    }
}
