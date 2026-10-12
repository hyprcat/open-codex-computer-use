import Foundation
import CryptoKit

/// Only internal dictionary-input glue and one catalog-resolved App Intent can be generated.
/// User values are runtime JSON and are never included in signed templates.
enum AppIntentTemplate {
    static func fingerprint(catalog: AppIntentCatalog, intent: DiscoveredAppIntent, keys: [String], teamID: String?) throws -> String {
        let schema: [String: Any] = ["template_version": 9, "bundle": catalog.bundleID, "intent": intent.raw,
                                    "keys": keys.sorted(), "team": teamID ?? ""]
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func workflow(catalog: AppIntentCatalog, intent: DiscoveredAppIntent,
                         keys: [String], teamID: String?) -> [String: Any] {
        func token(_ type: String, output: String? = nil, name: String = "Dictionary Value") -> [String: Any] {
            var value: [String: Any] = ["Type": type]
            if let output { value["OutputUUID"] = output; value["OutputName"] = name }
            return ["WFSerializationType": "WFTextTokenAttachment", "Value": value]
        }
        var actions: [[String: Any]] = []
        var descriptor: [String: Any] = ["AppIntentIdentifier": intent.identifier, "BundleIdentifier": catalog.bundleID, "Name": catalog.appName]
        if let teamID, !teamID.isEmpty { descriptor["TeamIdentifier"] = teamID }
        let intentOutput = UUID().uuidString
        var arguments: [String: Any] = ["AppIntentDescriptor": descriptor, "ShowWhenRun": false, "UUID": intentOutput]
        if !keys.isEmpty {
            let dictionary = UUID().uuidString
            actions.append(["WFWorkflowActionIdentifier": "is.workflow.actions.detect.dictionary",
                            "WFWorkflowActionParameters": ["UUID": dictionary, "WFInput": token("ExtensionInput")]])
            for name in keys.sorted() {
                let value = UUID().uuidString
                actions.append(["WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
                                "WFWorkflowActionParameters": ["UUID": value, "WFDictionaryKey": name,
                                                               "WFInput": token("ActionOutput", output: dictionary, name: "Dictionary"),
                                                               "WFGetDictionaryValueType": "Value"]])
                if intent.parameters.first(where: { $0.name == name })?.kind == .string {
                    arguments[name] = ["WFSerializationType": "WFTextTokenString", "Value": [
                        "string": "\u{FFFC}", "attachmentsByRange": ["{0, 1}": ["Type": "ActionOutput", "OutputUUID": value, "OutputName": "Dictionary Value"]]]]
                } else {
                    arguments[name] = token("ActionOutput", output: value)
                }
            }
        }
        actions.append(["WFWorkflowActionIdentifier": AppIntentExecution.identifier(bundleID: catalog.bundleID, actionID: intent.identifier), "WFWorkflowActionParameters": arguments])
        return ["WFWorkflowClientVersion": "2038.0.6", "WFWorkflowMinimumClientVersion": 900,
                "WFWorkflowMinimumClientVersionString": "900", "WFWorkflowTypes": [],
                "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFDictionaryContentItem", "WFGenericFileContentItem"],
                "WFWorkflowHasShortcutInputVariables": !keys.isEmpty, "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
                "WFWorkflowIcon": ["WFWorkflowIconStartColor": 946986751, "WFWorkflowIconGlyphNumber": 59511],
                "WFWorkflowImportQuestions": [], "WFQuickActionSurfaces": [], "WFWorkflowHasOutputFallback": false,
                "WFWorkflowActions": actions]
    }
}
