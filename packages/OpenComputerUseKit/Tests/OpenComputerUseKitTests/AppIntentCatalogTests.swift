import XCTest
@testable import OpenComputerUseKit

final class AppIntentCatalogTests: XCTestCase {
    private func catalog(_ changes: [String: Any] = [:], parameters: [[String: Any]]? = nil) throws -> AppIntentCatalog {
        var action: [String: Any] = ["identifier": "Echo", "isDiscoverable": true,
            "title": ["key": "Echo input"], "parameters": parameters ?? [parameter("text", 0), parameter("count", 2), parameter("enabled", 1), parameter("ratio", 7)]]
        action.merge(changes) { _, new in new }
        let root: [String: Any] = ["version": 1, "actions": ["Echo": action]]
        return try AppIntentCatalog.parse(JSONSerialization.data(withJSONObject: root), bundleURL: URL(fileURLWithPath: "/fixture.app"), bundleID: "dev.ocu.Fixture", appName: "Fixture", osVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }
    private func parameter(_ name: String, _ type: Int, optional: Bool = false) -> [String: Any] {
        ["name": name, "isOptional": optional, "valueType": ["primitive": ["wrapper": ["typeIdentifier": type]]]]
    }
    func testReservedBundleNamespaceIsDeniedBeforeMetadataRead() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-intent-policy-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let info: [String: Any] = ["CFBundleIdentifier": "is.workflow.actions", "CFBundlePackageType": "APPL", "CFBundleName": "Test"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try AppIntentCatalog.load(bundleURL: app)) { error in
            guard case ComputerUseError.permissionDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
    func testUnicodeCombiningSequencesCannotEscapeTextBudget() {
        let large = "a" + String(repeating: "\u{0301}", count: 5000)
        XCTAssertLessThanOrEqual(AppIntentCatalog.localized(["key": large])!.utf8.count, 2050)
    }
    func testMetadataCannotOverrideWorkflowIdentity() throws {
        for name in ["AppIntentDescriptor", "UUID", "ShowWhenRun"] {
            let intent = try XCTUnwrap(catalog(parameters: [parameter(name, 0, optional: true)]).intents.first)
            XCTAssertFalse(intent.executionUnsupportedReasons.isEmpty)
            XCTAssertEqual(intent.dictionary["can_execute"] as? Bool, false)
        }
        let intent = try XCTUnwrap(catalog(["outputType": ["primitive": ["wrapper": ["typeIdentifier": 0]]]]).intents.first)
        XCTAssertEqual(intent.outputKind, "string")
    }
    func testStrictJSONScalarsAndMissingUnknownParameters() throws {
        let intent = try XCTUnwrap(catalog().intents.first)
        let valid: [String: Any] = ["text": "中文\ntext", "count": 42, "enabled": true, "ratio": 1.25]
        XCTAssertEqual(try intent.validatedParameters(valid)["count"] as? Int, 42)
        for (key, wrong) in [("count", true as Any), ("count", 1.5 as Any), ("enabled", 1 as Any), ("ratio", Double.infinity as Any), ("text", 2 as Any), ("count", 9_007_199_254_740_992 as Any)] {
            var bad = valid; bad[key] = wrong
            XCTAssertThrowsError(try intent.validatedParameters(bad), key)
        }
        var unknown = valid; unknown["secret"] = "unused"
        XCTAssertThrowsError(try intent.validatedParameters(unknown))
        var missing = valid; missing.removeValue(forKey: "text")
        XCTAssertThrowsError(try intent.validatedParameters(missing))
        var oversized = valid; oversized["text"] = String(repeating: "a", count: 65536)
        XCTAssertThrowsError(try intent.validatedParameters(oversized))
    }
    func testCompilerBooleanDefaultAndOversizedSchema() throws {
        var boolean = parameter("enabled", 1)
        boolean["typeSpecificMetadata"] = ["LNValueTypeSpecificMetadataKeyDefaultValue", ["int": ["wrapper": 1]]]
        let intent = try XCTUnwrap(catalog(parameters: [boolean]).intents.first)
        XCTAssertEqual(try intent.validatedParameters([:])["enabled"] as? Bool, true)
        var large = parameter("text", 0)
        large["typeSpecificMetadata"] = ["LNValueTypeSpecificMetadataKeyDefaultValue", ["string": ["wrapper": String(repeating: "a", count: 200000)]]]
        let largeIntent = try XCTUnwrap(catalog(parameters: [large]).intents.first)
        XCTAssertEqual(largeIntent.dictionary["can_execute"] as? Bool, false)
        XCTAssertTrue(largeIntent.executionUnsupportedReasons.contains("schema_response_too_large"))
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: largeIntent.dictionary).count, 4096)
    }
    func testDefaultsAndOptionalUnsupportedParameters() throws {
        var defaulted = parameter("text", 0)
        defaulted["typeSpecificMetadata"] = ["LNValueTypeSpecificMetadataKeyDefaultValue", ["string": ["wrapper": "default"]]]
        let entity: [String: Any] = ["name": "note", "isOptional": true, "valueType": ["entity": ["wrapper": ["typeName": "Note"]]]]
        let intent = try XCTUnwrap(catalog(parameters: [defaulted, entity]).intents.first)
        XCTAssertTrue(intent.unsupportedReasons.isEmpty)
        XCTAssertEqual(try intent.validatedParameters([:])["text"] as? String, "default")
        XCTAssertThrowsError(try intent.validatedParameters(["note": "arbitrary-id"]))
    }
    func testRequiredEntityCannotBeMarkedExecutableByUnrecognizedDefault() throws {
        let entity: [String: Any] = ["name": "note", "valueType": ["entity": ["wrapper": ["typeName": "Note"]]], "typeSpecificMetadata": ["LNValueTypeSpecificMetadataKeyDefaultValue", ["string": ["wrapper": "id"]]]]
        let intent = try XCTUnwrap(catalog(parameters: [entity]).intents.first)
        XCTAssertTrue(intent.unsupportedReasons.contains("unsupported_required_parameter:note"))
        XCTAssertTrue(intent.parameters[0].required)
    }
    func testPlatformVisibilityAndUnsupportedOutputs() throws {
        XCTAssertTrue(try catalog(["isDiscoverable": false]).intents.isEmpty)
        XCTAssertTrue(try catalog(["visibilityMetadata": ["assistantOnly": true]]).intents.isEmpty)
        for annotation in [["obsoletedVersion": "*"], ["introducedVersion": "16.0"], ["obsoletedVersion": "14.0"]] {
            XCTAssertTrue(try catalog(["availabilityAnnotations": ["LNPlatformNameMACOS": annotation]]).intents[0].unsupportedReasons.contains("not_available_on_this_macos"))
        }
        XCTAssertTrue(try catalog(["outputType": ["entity": ["wrapper": ["typeName": "Note"]]]]).intents[0].unsupportedReasons.contains("unsupported_output_type"))
    }
    func testMalformedMetadataReturnsUnavailableAndDuplicateParametersAreRejected() throws {
        for bytes in [Data("invalid".utf8), Data("{\"version\":2,\"actions\":{}}".utf8)] {
            let result = try AppIntentCatalog.parse(bytes, bundleURL: URL(fileURLWithPath: "/fixture.app"), bundleID: "dev.ocu.Fixture", appName: "Fixture")
            XCTAssertEqual(result.reason, "unsupported_metadata_format")
        }
        XCTAssertTrue(try catalog(parameters: [parameter("text", 0), parameter("text", 0)]).intents[0].unsupportedReasons.contains("duplicate_parameter_metadata"))
    }
    func testRealEnumerationShapeAndStrictChoices() throws {
        let parameter: [String: Any] = ["name": "mode", "valueType": ["linkEnumeration": ["wrapper": ["identifier": "Mode"]]]]
        let root: [String: Any] = ["version": 1, "actions": ["Echo": ["identifier": "Echo", "isDiscoverable": true, "parameters": [parameter]]], "enums": [["identifier": "Mode", "cases": [["identifier": "first"], ["identifier": "second"]]]]]
        let result = try AppIntentCatalog.parse(JSONSerialization.data(withJSONObject: root), bundleURL: URL(fileURLWithPath: "/fixture.app"), bundleID: "dev.ocu.Fixture", appName: "Fixture")
        let intent = try XCTUnwrap(result.intents.first)
        XCTAssertEqual(intent.parameters[0].kind, .enumeration)
        XCTAssertEqual(try intent.validatedParameters(["mode": "second"])["mode"] as? String, "second")
        XCTAssertThrowsError(try intent.validatedParameters(["mode": "unknown"]))
    }
    func testTemplateReceivesFreshInputWithoutPersistingValues() throws {
        let catalog = try catalog(), intent = try XCTUnwrap(catalog.intents.first)
        let first = try intent.validatedParameters(["text": "first secret", "count": 3, "enabled": true, "ratio": 1.5])
        let second = try intent.validatedParameters(["text": "second secret", "count": 9, "enabled": false, "ratio": 2.5])
        let hash = try AppIntentTemplate.fingerprint(catalog: catalog, intent: intent, keys: Array(first.keys), teamID: "TEAM")
        XCTAssertEqual(hash, try AppIntentTemplate.fingerprint(catalog: catalog, intent: intent, keys: Array(second.keys.reversed()), teamID: "TEAM"))
        XCTAssertNotEqual(hash, try AppIntentTemplate.fingerprint(catalog: catalog, intent: intent, keys: ["text"], teamID: "TEAM"))
        let workflow = AppIntentTemplate.workflow(catalog: catalog, intent: intent, keys: Array(first.keys), teamID: "TEAM")
        let data = try PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0)
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(xml.contains("first secret")); XCTAssertFalse(xml.contains("second secret"))
        let actions = try XCTUnwrap(workflow["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.filter { $0["WFWorkflowActionIdentifier"] as? String == "dev.ocu.Fixture.Echo" }.count, 1)
        XCTAssertFalse(xml.contains("runshellscript"))
        XCTAssertTrue(xml.contains("ExtensionInput"))
        XCTAssertTrue((workflow["WFWorkflowInputContentItemClasses"] as? [String])?.contains("WFGenericFileContentItem") == true)
    }
    func testShortcutIdentityAndUnknownFallbackStates() throws {
        let uuid = UUID().uuidString
        let shortcuts = AppIntentExecution.installedShortcuts(Data("OCU 中文 (test) (\(uuid))\ninvalid line\n".utf8))
        XCTAssertEqual(shortcuts.count, 1)
        XCTAssertEqual(shortcuts[0].name, "OCU 中文 (test)")
        let unknown = try AppIntentExecution.state("unknown", reason: "timeout", started: true, isError: true)
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(unknown.primaryText).utf8)) as? [String: Any])
        XCTAssertEqual(value["safe_to_fallback"] as? Bool, false)
        XCTAssertEqual(unknown.isError, true)
    }
}
