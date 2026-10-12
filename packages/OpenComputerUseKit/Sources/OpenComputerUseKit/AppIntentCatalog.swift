import AppKit
import Foundation
import CoreFoundation

/// Empirical Xcode App Intents metadata, read only from the requested installed app.
/// This is a versioned compatibility surface, not a public discovery API.
struct AppIntentParameter {
    enum Kind: String { case string, boolean, integer, number, enumeration, unsupported }
    let name: String
    let title: String
    let kind: Kind
    let required: Bool
    let defaultValue: Any?
    let choices: [String]
    let rawType: [String: Any]

    var dictionary: [String: Any] {
        var value: [String: Any] = ["name": name, "title": title, "type": kind.rawValue,
                                    "required": required]
        if !choices.isEmpty { value["choices"] = choices }
        if let defaultValue { value["default"] = defaultValue }
        if kind == .unsupported { value["metadata_type"] = String(decoding: rawType.keys.sorted().joined(separator: ",").utf8.prefix(160), as: UTF8.self) }
        return value
    }
}

struct DiscoveredAppIntent {
    let identifier: String
    let title: String
    let description: String
    let parameters: [AppIntentParameter]
    let outputType: [String: Any]
    let opensApp: Bool
    let unsupportedReasons: [String]
    let raw: [String: Any]
    var outputKind: String {
        if outputType.isEmpty { return "none" }
        let primitive = outputType["primitive"] as? [String: Any]
        let wrapper = primitive?["wrapper"] as? [String: Any]
        switch wrapper?["typeIdentifier"] as? Int {
        case 0: return "string"
        case 1: return "boolean"
        case 2: return "integer"
        case 7: return "number"
        default: return String(decoding: outputType.keys.sorted().joined(separator: ",").utf8.prefix(160), as: UTF8.self)
        }
    }
    var executionUnsupportedReasons: [String] {
        let size = (try? JSONSerialization.data(withJSONObject: parameters.map(\.dictionary)).count) ?? Int.max
        return unsupportedReasons + (size > 196608 ? ["schema_response_too_large"] : [])
    }
    var dictionary: [String: Any] {
        let reasons = executionUnsupportedReasons
        return ["id": identifier, "title": title, "description": description,
         "parameters": reasons.contains("schema_response_too_large") ? [] : parameters.map(\.dictionary), "output_type": outputKind,
         "open_app_when_run": opensApp, "can_execute": reasons.isEmpty,
         "unsupported_reasons": reasons]
    }

    func validatedParameters(_ supplied: [String: Any]) throws -> [String: Any] {
        let names = Set(parameters.map(\.name))
        guard Set(supplied.keys).isSubset(of: names) else {
            throw ComputerUseError.invalidArguments("Unknown Intent parameter; use list_intents to read its schema")
        }
        var result: [String: Any] = [:]
        for parameter in parameters {
            guard let value = supplied[parameter.name] ?? parameter.defaultValue, !(value is NSNull) else {
                if parameter.required { throw ComputerUseError.invalidArguments("Missing Intent parameter: \(parameter.name)") }
                continue
            }
            switch parameter.kind {
            case .string:
                guard let string = value as? String, string.utf8.count <= 65536 else { throw invalid(parameter) }
            case .enumeration:
                guard let string = value as? String, parameter.choices.contains(string) else { throw invalid(parameter) }
            case .boolean:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid(parameter) }
            case .integer, .number:
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else { throw invalid(parameter) }
                if parameter.kind == .integer {
                    guard abs(number.doubleValue) <= 9_007_199_254_740_991,
                          number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw invalid(parameter) }
                }
            case .unsupported:
                throw ComputerUseError.stateUnavailable("Unsupported Intent parameter type: \(parameter.name)")
            }
            result[parameter.name] = value
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard data.count <= 65536 else { throw ComputerUseError.invalidArguments("Intent parameters exceed 64 KiB") }
        return result
    }
    private func invalid(_ parameter: AppIntentParameter) -> ComputerUseError {
        .invalidArguments("Intent parameter \(parameter.name) must have type \(parameter.kind.rawValue)")
    }
}

struct AppIntentCatalog {
    let bundleURL: URL
    let bundleID: String
    let appName: String
    let intents: [DiscoveredAppIntent]
    let reason: String?
    let metadata: Data
    static let maximumMetadataBytes = 16 * 1024 * 1024

    static func load(app query: String) throws -> Self {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 1000 else { throw ComputerUseError.invalidArguments("app must be a name or bundle identifier") }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
            ?? (try? AppDiscovery.resolveRunning(query))?.runningApplication.bundleURL
            ?? AppDiscovery.applicationURL(named: query, maximumEntries: 2000,
                deadline: ProcessInfo.processInfo.systemUptime + 2)
        guard let url else { throw ComputerUseError.appNotFound(query) }
        return try load(bundleURL: url)
    }

    static func load(bundleURL: URL) throws -> Self {
        guard let bundle = Bundle(url: bundleURL), let bundleID = bundle.bundleIdentifier,
              AppIntentExecution.isValidIdentifier(bundleID) else {
            throw ComputerUseError.stateUnavailable("Cannot identify this installed application")
        }
        guard bundleID != "is.workflow", !bundleID.hasPrefix("is.workflow."),
              !AppSafetyPolicy.isBlocked(bundleIdentifier: bundleID.lowercased()) else {
            throw AppSafetyPolicy.permissionDenied(bundleIdentifier: bundleID)
        }
        let discoveredName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let appName = String(decoding: discoveredName.utf8.prefix(160), as: UTF8.self)
        let url = bundleURL.appendingPathComponent("Contents/Resources/Metadata.appintents/extract.actionsdata")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init(bundleURL: bundleURL, bundleID: bundleID, appName: appName, intents: [], reason: "no_app_intents_metadata", metadata: Data())
        }
        let data = try IntentFile.readPrefix(url, maximum: maximumMetadataBytes + 1)
        guard data.count <= maximumMetadataBytes else { throw ComputerUseError.stateUnavailable("App Intent metadata exceeds 16 MiB") }
        return try parse(data, bundleURL: bundleURL, bundleID: bundleID, appName: appName)
    }

    static func parse(_ data: Data, bundleURL: URL, bundleID: String, appName: String,
                      osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> Self {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["version"] as? Int == 1, let actions = root["actions"] as? [String: [String: Any]], actions.count <= 1000 else {
            return .init(bundleURL: bundleURL, bundleID: bundleID, appName: appName, intents: [], reason: "unsupported_metadata_format", metadata: data)
        }
        let enums = root["enums"] as? [[String: Any]] ?? []
        var intents: [DiscoveredAppIntent] = []
        for id in actions.keys.sorted() {
            guard let action = actions[id], AppIntentExecution.isValidIdentifier(id),
                  id.utf8.count <= 256, action["identifier"] as? String == id,
                  action["isDiscoverable"] as? Bool == true else { continue }
            let visibility = action["visibilityMetadata"] as? [String: Any] ?? [:]
            if visibility["assistantOnly"] as? Bool == true || visibility["isDiscoverable"] as? Bool == false { continue }
            let rawParameters = action["parameters"] as? [[String: Any]] ?? []
            var reasons: [String] = []
            if !availableOnMac(action, osVersion: osVersion) { reasons.append("not_available_on_this_macos") }
            if rawParameters.count > 64 { reasons.append("too_many_parameters") }
            var parameters: [AppIntentParameter] = []
            for p in rawParameters.prefix(64) {
                guard let name = p["name"] as? String, AppIntentExecution.isValidIdentifier(name), name.utf8.count <= 256,
                      let type = p["valueType"] as? [String: Any] else { reasons.append("invalid_parameter_metadata"); continue }
                if ["AppIntentDescriptor", "UUID", "ShowWhenRun"].contains(name) {
                    reasons.append("reserved_parameter_name:\(name)")
                }
                var kind = AppIntentParameter.Kind.unsupported
                var choices: [String] = []
                if let primitive = type["primitive"] as? [String: Any], let wrapper = primitive["wrapper"] as? [String: Any] {
                    switch wrapper["typeIdentifier"] as? Int {
                    case 0: kind = .string
                    case 1: kind = .boolean
                    case 2: kind = .integer
                    case 7: kind = .number
                    default: break
                    }
                } else if let enumeration = type["linkEnumeration"] as? [String: Any],
                          let wrapper = enumeration["wrapper"] as? [String: Any], let typeName = wrapper["identifier"] as? String,
                          let definition = enums.first(where: { $0["identifier"] as? String == typeName }) {
                    choices = (definition["cases"] as? [[String: Any]] ?? []).compactMap { $0["identifier"] as? String }
                    if !choices.isEmpty, choices.count <= 256, Set(choices).count == choices.count,
                       choices.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) { kind = .enumeration }
                }
                var defaultValue = primitiveDefault(p["typeSpecificMetadata"] as? [Any] ?? [])
                // Xcode can encode a Bool default as an integer static value.
                if kind == .boolean, let number = defaultValue as? NSNumber,
                   [0.0, 1.0].contains(number.doubleValue) { defaultValue = number.boolValue }
                let required = p["isOptional"] as? Bool != true && (defaultValue == nil || kind == .unsupported)
                if kind == .unsupported && required { reasons.append("unsupported_required_parameter:\(name)") }
                parameters.append(.init(name: name, title: localized(p["title"]) ?? name, kind: kind,
                                        required: required, defaultValue: kind == .unsupported ? nil : defaultValue, choices: choices, rawType: type))
            }
            if Set(parameters.map(\.name)).count != parameters.count { reasons.append("duplicate_parameter_metadata") }
            let outputType = action["outputType"] as? [String: Any] ?? [:]
            if !outputType.isEmpty {
                let primitive = outputType["primitive"] as? [String: Any]
                let wrapper = primitive?["wrapper"] as? [String: Any]
                if ![0, 1, 2, 7].contains(wrapper?["typeIdentifier"] as? Int ?? -1) { reasons.append("unsupported_output_type") }
            }
            let descriptionMetadata = action["descriptionMetadata"] as? [String: Any]
            intents.append(.init(identifier: id, title: localized(action["title"]) ?? id,
                                 description: localized(descriptionMetadata?["descriptionText"]) ?? "",
                                 parameters: parameters, outputType: outputType,
                                 opensApp: action["openAppWhenRun"] as? Bool ?? false,
                                 unsupportedReasons: reasons, raw: action))
        }
        return .init(bundleURL: bundleURL, bundleID: bundleID, appName: appName, intents: intents, reason: nil, metadata: data)
    }

    static func localized(_ value: Any?) -> String? {
        if let string = value as? String { return String(decoding: string.utf8.prefix(2048), as: UTF8.self) }
        guard let value = value as? [String: Any], let key = value["key"] as? String else { return nil }
        return String(decoding: key.utf8.prefix(2048), as: UTF8.self)
    }
    private static func primitiveDefault(_ values: [Any]) -> Any? {
        guard let index = values.firstIndex(where: { ($0 as? String) == "LNValueTypeSpecificMetadataKeyDefaultValue" }),
              values.indices.contains(index + 1), let object = values[index + 1] as? [String: Any] else { return nil }
        for key in ["string", "bool", "int", "double"] {
            if let box = object[key] as? [String: Any], let value = box["wrapper"], !(value is NSNull) { return value }
        }
        return nil
    }
    private static func availableOnMac(_ action: [String: Any], osVersion: OperatingSystemVersion) -> Bool {
        let annotations = action["availabilityAnnotations"] as? [String: [String: Any]] ?? [:]
        guard let mac = annotations["LNPlatformNameMACOS"] else { return true }
        if mac["obsoletedVersion"] as? String == "*" { return false }
        let current = [osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion]
        func version(_ value: Any?) -> [Int]? {
            guard let string = value as? String, string != "*" else { return nil }
            let pieces = string.split(separator: ".").compactMap { Int($0) }
            guard !pieces.isEmpty else { return nil }
            return Array((pieces + [0, 0]).prefix(3))
        }
        if let introduced = version(mac["introducedVersion"]), current.lexicographicallyPrecedes(introduced) { return false }
        if let obsoleted = version(mac["obsoletedVersion"]), !current.lexicographicallyPrecedes(obsoleted) { return false }
        return true
    }
}
