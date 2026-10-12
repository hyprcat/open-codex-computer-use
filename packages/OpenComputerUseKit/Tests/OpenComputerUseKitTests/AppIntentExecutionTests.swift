import XCTest
@testable import OpenComputerUseKit

final class AppIntentExecutionTests: XCTestCase {
    func testIdentifierJoinsBundleAndIntent() {
        XCTAssertEqual(AppIntentExecution.identifier(bundleID: "com.apple.Notes", actionID: "CreateNote"), "com.apple.Notes.CreateNote")
        XCTAssertEqual(AppIntentExecution.identifier(bundleID: "com.apple.Notes", actionID: "com.apple.Notes.CreateNote"), "com.apple.Notes.CreateNote")
        XCTAssertEqual(AppIntentExecution.identifier(bundleID: "x", actionID: "is.workflow.actions.alert"), "x.is.workflow.actions.alert")
    }

    func testRunRefusesBuiltInShortcutsActions() {
        XCTAssertThrowsError(try AppIntentExecution.run(app: "is.workflow", actionID: "is.workflow.actions.runshellscript", parameters: [:]))
    }

    func testRenameRetainsPinAndDeletedIdentityCannotAdoptSameNameClone() {
        let record = AppIntentExecution.TemplateRecord(name: "OCU Fixture Original", shortcutID: "approved-id")
        let renamed = AppIntentExecution.InstalledShortcut(name: "Renamed", id: "approved-id")
        let clone = AppIntentExecution.InstalledShortcut(name: record.name, id: "different-id")
        XCTAssertEqual(AppIntentExecution.installationMatches(record, shortcuts: [renamed, clone]).first?.id, "approved-id")
        XCTAssertTrue(AppIntentExecution.installationMatches(record, shortcuts: [clone]).isEmpty)
        let pending = AppIntentExecution.TemplateRecord(name: record.name, shortcutID: nil)
        XCTAssertEqual(AppIntentExecution.installationMatches(pending, shortcuts: [clone, clone]).count, 2)
    }
    func testIdentifierValidationRejectsPathCharacters() {
        XCTAssertTrue(AppIntentExecution.isValidIdentifier("com.apple.Notes.CreateNote"))
        XCTAssertTrue(AppIntentExecution.isValidIdentifier("is.workflow.actions.run-shortcut_2"))
        for action in ["../../x", "a/b", "a\nb", "..", "com.example..", ".", " ", "", "a b"] {
            XCTAssertFalse(AppIntentExecution.isValidIdentifier(action), action)
        }
    }
}
