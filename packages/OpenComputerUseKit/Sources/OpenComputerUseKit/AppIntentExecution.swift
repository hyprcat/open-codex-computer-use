import AppKit
import Foundation
import Security
import Darwin

/// Discovered app actions only. No arbitrary shortcut name, workflow or built-in action is accepted.
/// Installation confirmation remains a Shortcuts system step; metadata is not an entitlement.
enum AppIntentExecution {
    static func identifier(bundleID: String, actionID: String) -> String {
        actionID.hasPrefix(bundleID + ".") ? actionID : "\(bundleID).\(actionID)"
    }
    static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1000 && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }
        }
    }

    static func list(app: String, limit: Int = 50, offset: Int = 0) throws -> ToolCallResult {
        let catalog = try AppIntentCatalog.load(app: app)
        var page: [[String: Any]] = [], bytes = 4096
        for intent in catalog.intents.dropFirst(offset).prefix(limit) {
            let value = intent.dictionary
            let size = try JSONSerialization.data(withJSONObject: value).count
            guard bytes + size <= 262144 else { break }
            page.append(value); bytes += size
        }
        return try json(["status": catalog.reason == nil ? "available" : "unavailable",
                         "reason": catalog.reason ?? "", "execution_started": false, "safe_to_fallback": true, "app": catalog.appName, "bundle_id": catalog.bundleID,
                         "intents": page, "next_offset": offset + page.count,
                         "total": catalog.intents.count, "offset": offset,
                         "has_more": offset + page.count < catalog.intents.count])
    }

    struct TemplateRecord: Codable {
        let name: String
        var shortcutID: String?
    }
    struct InstalledShortcut {
        let name: String
        let id: String
    }
    static func installationMatches(_ record: TemplateRecord, shortcuts: [InstalledShortcut]) -> [InstalledShortcut] {
        if let pinnedID = record.shortcutID { return shortcuts.filter { $0.id == pinnedID } }
        return shortcuts.filter { $0.name == record.name }
    }
    static func installedShortcuts(_ data: Data) -> [InstalledShortcut] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let value = String(line)
            guard value.hasSuffix(")"), value.count > 39 else { return nil }
            let suffix = String(value.suffix(38))
            guard suffix.hasPrefix("("), let id = UUID(uuidString: String(suffix.dropFirst().dropLast())) else { return nil }
            let name = String(value.dropLast(39))
            return .init(name: name, id: id.uuidString)
        }
    }

    static func run(app: String, actionID: String, parameters: [String: Any], prepare: Bool = false) throws -> ToolCallResult {
        guard isValidIdentifier(actionID), !actionID.hasPrefix("is.workflow.") else {
            throw ComputerUseError.invalidArguments("action_id must be an app action returned by list_intents")
        }
        let catalog = try AppIntentCatalog.load(app: app)
        let exact = catalog.intents.first(where: { $0.identifier == actionID })?.identifier
        let id = exact ?? (actionID.hasPrefix(catalog.bundleID + ".") ? String(actionID.dropFirst(catalog.bundleID.count + 1)) : actionID)
        guard !identifier(bundleID: catalog.bundleID, actionID: id).hasPrefix("is.workflow.") else {
            throw ComputerUseError.invalidArguments("Built-in Shortcuts actions cannot be executed as App Intents")
        }
        guard let intent = catalog.intents.first(where: { $0.identifier == id }) else {
            return try state("unavailable", reason: catalog.reason ?? "intent_not_found", started: false)
        }
        let unsupportedReasons = intent.executionUnsupportedReasons
        guard unsupportedReasons.isEmpty else {
            return try state("unavailable", reason: unsupportedReasons.joined(separator: ","), started: false)
        }
        if intent.parameters.contains(where: { $0.kind == .unsupported && parameters[$0.name] != nil }) {
            return try state("unavailable", reason: "unsupported_parameter_type", started: false)
        }
        let values = try intent.validatedParameters(parameters)
        let teamID = signingTeam(catalog.bundleURL)
        let fingerprint = try AppIntentTemplate.fingerprint(catalog: catalog, intent: intent, keys: Array(values.keys), teamID: teamID)
        let base = try OCUConfiguration.fileURL(environment: OCUConfiguration.environment).deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent("intent-templates", isDirectory: true)
        let directory = base.appendingPathComponent(fingerprint, isDirectory: true)
        let recordFile = directory.appendingPathComponent("record.json")
        let signed = directory.appendingPathComponent("template.shortcut")
        guard prepare || FileManager.default.fileExists(atPath: recordFile.path) else {
            return try state("needs_approval", reason: "template_not_prepared", started: false,
                             extra: ["next": "Call prepareIntent, then review the system Add Shortcut sheet once."])
        }
        try rejectSymlink(base)
        try rejectSymlink(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFD = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw ComputerUseError.stateUnavailable("Cannot lock Intent template cache") }
        defer { _ = flock(lockFD, LOCK_UN); _ = close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ComputerUseError.stateUnavailable("Intent cache lock must be a regular file")
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            return try state("busy", reason: "template_in_use", started: false,
                             extra: ["next": "Wait for the current preparation or execution to finish."])
        }
        var record: TemplateRecord?
        if FileManager.default.fileExists(atPath: recordFile.path) {
            try rejectSymlink(directory)
            try rejectSymlink(recordFile)
            let data = try boundedRead(recordFile, maximum: 4096)
            record = try JSONDecoder().decode(TemplateRecord.self, from: data)
            guard let record, record.name.hasPrefix("OCU "), record.name.utf8.count <= 200,
                  !record.name.contains("/"), !record.name.contains("\\"), !record.name.contains("\n"),
                  record.shortcutID == nil || UUID(uuidString: record.shortcutID!) != nil else {
                throw ComputerUseError.stateUnavailable("Invalid generated Intent template record")
            }
        }
        guard prepare || record != nil else {
            return try state("needs_approval", reason: "template_not_prepared", started: false,
                             extra: ["next": "Call prepareIntent with these parameter names, then confirm the system Add Shortcut sheet once."])
        }
        let installed = IntentProcess.run("/usr/bin/shortcuts", ["list", "--show-identifiers"], timeout: 3)
        guard installed.succeeded else {
            return try state("unavailable", reason: installed.failure ?? "shortcuts_list_failed", started: false,
                             extra: ["diagnostic": installed.diagnostic])
        }
        let shortcuts = installedShortcuts(installed.stdout)
        if var current = record {
            let matches = installationMatches(current, shortcuts: shortcuts)
            if matches.count == 1 {
                current.shortcutID = matches[0].id
                try writeRecord(current, to: recordFile)
                if prepare { return try state("ready", reason: "", started: false, extra: ["shortcut_id": matches[0].id]) }
                return try execute(shortcutID: matches[0].id, parameters: values)
            }
            if matches.count > 1 { return try state("unavailable", reason: "ambiguous_generated_shortcut", started: false) }
            // An approved identity was deleted. Explicit preparation must create a new
            // name and pin, rather than adopting a different shortcut with the old name.
            if prepare && current.shortcutID != nil { record = nil }
        }
        guard prepare else {
            return try state("needs_approval", reason: "generated_shortcut_not_installed", started: false)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectSymlink(base)
        try rejectSymlink(directory)
        if record == nil {
            let label = String(decoding: catalog.appName.filter { $0.isLetter || $0.isNumber || " _-".contains($0) }.utf8.prefix(60), as: UTF8.self)
            let actionLabel = String(decoding: id.utf8.prefix(80), as: UTF8.self)
            record = .init(name: "OCU \(label) \(actionLabel) \(UUID().uuidString.prefix(8))", shortcutID: nil)
            try writeRecord(record!, to: recordFile)
        }
        let workflow = AppIntentTemplate.workflow(catalog: catalog, intent: intent, keys: Array(values.keys), teamID: teamID)
        let unsigned = directory.appendingPathComponent("unsigned.shortcut")
        defer { try? FileManager.default.removeItem(at: unsigned) }
        try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0).write(to: unsigned, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unsigned.path)
        // Filename is the import title. It contains no caller values or user-supplied path.
        let namedSigned = directory.appendingPathComponent(record!.name + ".shortcut")
        let sign = IntentProcess.run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me", "--input", unsigned.path, "--output", namedSigned.path], timeout: 20)
        guard sign.succeeded else {
            return try state("unavailable", reason: sign.failure ?? "signing_failed", started: false,
                             extra: ["diagnostic": sign.diagnostic])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namedSigned.path)
        if FileManager.default.fileExists(atPath: signed.path) { try FileManager.default.removeItem(at: signed) }
        try FileManager.default.copyItem(at: namedSigned, to: signed)
        let opened = IntentProcess.run("/usr/bin/open", ["-a", "Shortcuts", namedSigned.path], timeout: 2)
        return try state("needs_approval", reason: opened.succeeded ? "confirm_add_shortcut" : "open_import_failed", started: false,
                         extra: ["file": namedSigned.path, "shortcut": record!.name,
                                 "next": "Review and add the generated shortcut in Shortcuts. Then runIntent again with fresh parameters. No Intent has run."])
    }

    private static func execute(shortcutID: String, parameters: [String: Any]) throws -> ToolCallResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json"), output = directory.appendingPathComponent("output.txt")
        try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]).write(to: input)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let result = IntentProcess.run("/usr/bin/shortcuts", ["run", shortcutID, "--input-path", input.path, "--output-path", output.path, "--output-type", "public.utf8-plain-text"], timeout: 20)
        guard result.succeeded else {
            let started = result.failure != "launch_failed"
            return try state(started ? "unknown" : "failed", reason: result.failure ?? "workflow_error", started: started,
                             extra: ["diagnostic": result.diagnostic,
                                     "next": "Check whether the operation happened before retrying or using the GUI."], isError: true)
        }
        var text = "", truncated = false
        if FileManager.default.fileExists(atPath: output.path) {
            guard let data = try? boundedRead(output, maximum: 65537) else {
                return try state("unknown", reason: "output_read_failed", started: true, isError: true)
            }
            truncated = data.count > 65536
            text = String(decoding: data.prefix(65536), as: UTF8.self)
        }
        return try state("completed", reason: "", started: true,
                         extra: ["output": text, "output_truncated": truncated, "shortcut_id": shortcutID])
    }
    static func state(_ status: String, reason: String, started: Bool,
                      extra: [String: Any] = [:], isError: Bool = false) throws -> ToolCallResult {
        var result = extra
        result["status"] = status; result["reason"] = reason; result["execution_started"] = started
        result["safe_to_fallback"] = !started && ["unavailable", "needs_approval"].contains(status)
        return try json(result, isError: isError)
    }
    static func json(_ value: Any, isError: Bool = false) throws -> ToolCallResult {
        let result = ToolCallResult.text(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
        return ToolCallResult(content: result.content, isError: isError)
    }
    private static func signingTeam(_ url: URL) -> String? {
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
    private static func writeRecord(_ record: TemplateRecord, to url: URL) throws {
        try rejectSymlink(url.deletingLastPathComponent())
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func rejectSymlink(_ url: URL) throws {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw ComputerUseError.stateUnavailable("Intent template cache must not be a symlink")
        }
    }
    private static func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        return try IntentFile.readPrefix(url, maximum: maximum)
    }
}
