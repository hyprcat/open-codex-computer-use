import Foundation

/// Bridges pi_agent_rust's speculative python-tool wire to the in-process `js`
/// streaming engine, so the pi brain drives Open Computer Use with sPTC: pi streams
/// a tool call's `code` as the model generates it, and each newly-complete statement
/// runs at once. This speaks pi's SPTC_WIRE frame dialect instead of the `{op}` JSONL
/// of `OpenComputerUseStreamServer`; both front-ends drive the same engine
/// (`ComputerUseToolDispatcher.stream*`). See docs/references/js-stream-protocol.md.
///
/// Frames in (pi -> bridge, one JSON object per line on stdin):
///   {"op":"source","cell":"<id>","source":"<full code so far>","final":<bool>}
///   {"op":"abandon","cell":"<id>"}
///   {"op":"reply","id":"<id>","result":{...}}   // host-tool reply; unused here, ignored
/// Frames out (bridge -> pi, one JSON object per line on stdout):
///   {"type":"ready","pid":<int>}                                  // once, at start
///   {"type":"done","cell":"<id>","index":<int>}                   // per completed statement
///   {"type":"output","cell":"<id>","text":"<str>"}                // text the code wrote
///   {"type":"image","cell":"<id>","data":"<b64>","mimeType":"<str>"}
///   {"type":"terminal","cell":"<id>","status":"done"|"failed","error":"<str>"?}
public final class OpenComputerUsePiBridgeServer {
    private let dispatcher: ComputerUseToolDispatcher
    private var begun: Set<String> = []
    private var reported: [String: Int] = [:]
    private var closed: Set<String> = []

    public init(service: ComputerUseService = ComputerUseService()) {
        self.dispatcher = ComputerUseToolDispatcher(service: service)
    }

    public init(dispatcher: ComputerUseToolDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Handle one request line; return zero or more response lines (no trailing newline).
    public func handle(line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let data = trimmed.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let op = object["op"] as? String else {
            return []
        }

        switch op {
        case "source":
            guard let cell = object["cell"] as? String, let source = object["source"] as? String else {
                return []
            }
            let final = (object["final"] as? Bool) ?? false
            return handleSource(cell: cell, source: source, final: final)
        case "abandon":
            guard let cell = object["cell"] as? String, !closed.contains(cell) else { return [] }
            _ = dispatcher.streamAbandon(id: cell)
            let ran = reported[cell] ?? 0
            close(cell)
            return [Self.encode(["type": "terminal", "cell": cell, "status": "failed",
                                 "error": "abandoned after \(ran) statements"])]
        case "reply":
            return []
        default:
            return []
        }
    }

    private func handleSource(cell: String, source: String, final: Bool) -> [String] {
        guard !closed.contains(cell) else { return [] }
        if begun.insert(cell).inserted {
            dispatcher.streamBegin(id: cell)
            reported[cell] = 0
        }

        if final {
            let result = dispatcher.streamFinish(id: cell, source: source)
            var lines = drainResult(cell: cell, result: result)
            let isError = (result.asDictionary["isError"] as? Bool) ?? false
            lines.append(Self.encode(["type": "terminal", "cell": cell,
                                      "status": isError ? "failed" : "done"]))
            close(cell)
            return lines
        }

        let progress = dispatcher.streamFeed(id: cell, source: source)
        var lines: [String] = []
        let already = reported[cell] ?? 0
        if progress.completed > already {
            for index in already..<progress.completed {
                lines.append(Self.encode(["type": "done", "cell": cell, "index": index]))
            }
            reported[cell] = progress.completed
        }
        if progress.failed {
            lines.append(Self.encode(["type": "terminal", "cell": cell, "status": "failed",
                                      "error": progress.error ?? "statement failed"]))
            close(cell)
        }
        return lines
    }

    private func drainResult(cell: String, result: ToolCallResult) -> [String] {
        guard let content = result.asDictionary["content"] as? [[String: Any]] else { return [] }
        var lines: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    lines.append(Self.encode(["type": "output", "cell": cell, "text": text]))
                }
            case "image":
                if let base64 = block["data"] as? String {
                    lines.append(Self.encode(["type": "image", "cell": cell, "data": base64,
                                              "mimeType": block["mimeType"] as? String ?? "image/png"]))
                }
            default:
                break
            }
        }
        return lines
    }

    private func close(_ cell: String) {
        closed.insert(cell)
        begun.remove(cell)
        reported[cell] = nil
    }

    /// Read frames from stdin, write frames to stdout unbuffered, until stdin closes.
    public func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        print(Self.encode(["type": "ready", "pid": Int(ProcessInfo.processInfo.processIdentifier)]))
        while let line = readLine(strippingNewline: true) {
            for response in handle(line: line) {
                print(response)
            }
        }
        // The run is over (pi closed the wire): bring any windows parked on the agent's
        // virtual display back to where the user had them.
        AgentDisplay.shared.restoreAll()
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8) else {
            return "{\"type\":\"terminal\",\"status\":\"failed\",\"error\":\"encode failed\"}"
        }
        return text
    }
}
