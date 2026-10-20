import Foundation
import XCTest
@testable import VibekeyCore

final class WorkflowValidationTests: XCTestCase {
    func testRejectsUnsafeAndAmbiguousURLs() {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "shortcuts://run-shortcut?name=x",
                     "https://", "https://user:password@example.com", "https://example.com\n", "https://exa mple.com",
                     "https://exa%20mple.com", "https://example.com:65536"] {
            XCTAssertNotNil(WorkflowStep(kind: .openURL, argument: text).validationError)
        }
        XCTAssertNil(WorkflowStep(kind: .openURL, argument: "https://example.com/path?q=hello%20world").validationError)
    }

    func testShortcutArgumentsKeepMetacharactersInOneValue() throws {
        let name = "Focus; $(touch /tmp/should-not-exist) \"work\""
        XCTAssertEqual(try WorkflowValidation.shortcutArguments(for: name), ["run", name])
        for name in ["", " ", "--help", "x\u{0}y", "name\nother"] {
            XCTAssertThrowsError(try WorkflowValidation.shortcutArguments(for: name))
        }
    }

    func testKeyboardRejectsOutOfRangeAndUnknownFlags() {
        XCTAssertNotNil(WorkflowStep(keyCode: 128).validationError)
        XCTAssertNotNil(WorkflowStep(keyCode: UInt16.max).validationError)
        XCTAssertNotNil(WorkflowStep(modifiers: 1).validationError)
        XCTAssertNil(WorkflowStep(keyCode: 36, modifiers: 0x00100000 | 0x00020000).validationError)
    }

    func testDelayAndTotalRuntimeAreBounded() {
        for seconds in [-1.0, 30.01, .infinity, .nan] {
            XCTAssertNotNil(WorkflowStep(kind: .delay, seconds: seconds).validationError)
        }
        XCTAssertThrowsError(try WorkflowValidation.validate((0..<5).map { _ in WorkflowStep(kind: .delay, seconds: 30) }))
        XCTAssertThrowsError(try WorkflowValidation.validate((0..<7).map { _ in WorkflowStep(kind: .runShortcut, argument: "Focus") }))
        XCTAssertNoThrow(try WorkflowValidation.validate([WorkflowStep(kind: .delay, seconds: 0), WorkflowStep(kind: .toggleMute)]))
    }

    func testInvalidLaterStepRejectsWholeMacro() {
        let steps = [WorkflowStep(kind: .openApp, argument: "com.apple.TextEdit"),
                     WorkflowStep(kind: .openURL, argument: "file:///tmp/private")]
        XCTAssertThrowsError(try WorkflowValidation.validate(steps)) { error in
            XCTAssertTrue(error.localizedDescription.contains("第 2 步"))
        }
    }

    func testRejectsDuplicateStepIdentifiersAndExcessSteps() {
        let step = WorkflowStep(kind: .delay, seconds: 0)
        XCTAssertThrowsError(try WorkflowValidation.validate([step, step]))
        XCTAssertThrowsError(try WorkflowValidation.validate((0..<65).map { _ in WorkflowStep(kind: .delay, seconds: 0) }))
        XCTAssertThrowsError(try WorkflowValidation.validate([WorkflowStep]()))
    }

    func testApplicationRequiresBundleIDOrExistingAbsoluteApp() {
        for text in ["Safari", "./Some.app", "/tmp/vibekey-uninstalled-\(UUID().uuidString).app", "com.apple.Safari --args", "com..apple"] {
            XCTAssertNotNil(WorkflowStep(kind: .openApp, argument: text).validationError)
        }
        XCTAssertNil(WorkflowStep(kind: .openApp, argument: "com.apple.Safari").validationError)
    }

    func testContextBindingsAllowFallbackButRejectAmbiguousDuplicates() {
        let global = binding(trigger: "key1")
        let app = binding(trigger: "key1", app: "com.apple.Safari")
        XCTAssertNoThrow(try WorkflowValidation.validate([global, app]))
        XCTAssertThrowsError(try WorkflowValidation.validate([global, binding(trigger: "key1")]))
        XCTAssertThrowsError(try WorkflowValidation.validate([app, binding(trigger: "key1", app: "COM.APPLE.SAFARI")]))
        var duplicateIdentity = binding(trigger: "key2")
        duplicateIdentity.id = global.id
        XCTAssertThrowsError(try WorkflowValidation.validate([global, duplicateIdentity]))
        XCTAssertThrowsError(try WorkflowValidation.validate([binding(trigger: "key1", app: "Safari")]))
    }

    func testPersistenceRoundTripAndPrivateFileMode() throws {
        try withTemporaryFile { url in
            XCTAssertEqual(try WorkflowPersistence.load(from: url), [])
            let bindings = [binding(trigger: "key1"), binding(trigger: "key1", app: "com.apple.Safari")]
            try WorkflowPersistence.save(bindings, to: url)
            XCTAssertEqual(try WorkflowPersistence.load(from: url), bindings)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try WorkflowPersistence.save([], to: url)
            XCTAssertEqual(try WorkflowPersistence.load(from: url), [])
        }
    }

    func testCorruptFileIsNeverOverwrittenOnSave() throws {
        try withTemporaryFile { url in
            let badData = Data("{broken".utf8)
            try badData.write(to: url)
            XCTAssertThrowsError(try WorkflowPersistence.load(from: url))
            XCTAssertThrowsError(try WorkflowPersistence.save([binding(trigger: "key1")], to: url))
            XCTAssertEqual(try Data(contentsOf: url), badData)
        }
    }

    func testFutureVersionIsNeverOverwrittenOnSave() throws {
        try withTemporaryFile { url in
            let future = Data("{\"schemaVersion\":2,\"bindings\":[]}".utf8)
            try future.write(to: url)
            XCTAssertThrowsError(try WorkflowPersistence.save([binding(trigger: "key1")], to: url))
            XCTAssertEqual(try Data(contentsOf: url), future)
        }
    }

    func testInvalidSavePreservesLastGoodDocument() throws {
        try withTemporaryFile { url in
            let good = binding(trigger: "key1")
            try WorkflowPersistence.save([good], to: url)
            let original = try Data(contentsOf: url)
            XCTAssertThrowsError(try WorkflowPersistence.save([good, binding(trigger: "key1")], to: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    private func binding(trigger: String, app: String = "") -> WorkflowBinding {
        WorkflowBinding(name: "测试工作流", triggerID: trigger, applicationBundleID: app,
                        steps: [WorkflowStep(kind: .delay, seconds: 0)])
    }

    private func withTemporaryFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibekey-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("workflows.json"))
    }
}
