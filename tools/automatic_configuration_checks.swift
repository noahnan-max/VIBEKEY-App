import Foundation
import VibekeyCore

@main @MainActor enum AutomaticConfigurationChecks {
    static func main() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Vibekey/OwnedProbes/automatic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { fatalError(message) }; checks += 1
        }
        func settle() async throws { try await Task.sleep(nanoseconds: 480_000_000) }
        let directory = root.appendingPathComponent("workflow"), store = WorkflowStore(directory: directory)
        let file = directory.appendingPathComponent("workflows.json")
        let original = try Data(contentsOf: file), originalIDs = store.activeBindings.map(\.id), originalSteps = store.activeBindings[0].steps
        var commits = 0
        store.onLog = { _ in commits += 1 }
        store.selectTrigger("key.0")
        try await settle()
        try check(commits == 0 && Data(contentsOf: file) == original, "Browsing or initialization rewrote saved bindings")
        for code: UInt16 in [0, 11, 8] { store.bindings[0].steps = [WorkflowStep(kind: .shortcut, keyCode: code, modifiers: 0x100000)] }
        try check(store.automaticSavePending && store.activeBindings[0].steps == originalSteps, "Incomplete debounce was activated")
        try await settle()
        try check(commits == 1 && store.activeBindings[0].steps[0].keyCode == 8 && !store.hasUnsavedChanges, "Rapid edits did not save exactly the final value")
        try check(store.activeBindings.map(\.id) == originalIDs && !store.enabled, "Autosave changed identities or implicitly enabled actions")
        let lastGood = try Data(contentsOf: file), active = store.activeBindings
        store.bindings[0].steps = [WorkflowStep(kind: .openURL, argument: "https://")]
        try await settle()
        try check(store.automaticSaveError != nil && store.activeBindings == active && Data(contentsOf: file) == lastGood, "Incomplete input overwrote the last-good configuration")
        store.bindings[0].steps[0].argument = "https://example.com"
        try await settle()
        try check(store.automaticSaveError == nil && store.activeBindings[0].steps[0].argument == "https://example.com", "Corrected input did not automatically recover")
        store.bindings[0].steps[0].argument = "https://example.org"
        let beforeFlush = commits
        try check(store.flushAutomaticSave() && commits == beforeFlush + 1, "Navigation flush lost a completed edit")
        try await settle()
        try check(commits == beforeFlush + 1, "Flushed timer wrote a second time")
        store.bindings[0].steps = [WorkflowStep(kind: .shortcut, keyCode: 9, modifiers: 0x100000)]
        await store.shutdown()
        let reopened = WorkflowStore(directory: directory)
        try check(reopened.activeBindings[0].steps[0].keyCode == 9 && reopened.activeBindings.map(\.id) == originalIDs, "Immediate exit lost configuration")
        try check(!reopened.enabled, "Reopen changed the explicit enable choice")

        let suiteName = "io.github.noahnan-max.VIBEKEY.PresetChecks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let freshDirectory = root.appendingPathComponent("fresh-profile")
        let fresh = WorkflowStore(directory: freshDirectory, preferences: preferences)
        try check(fresh.enabled && fresh.activeBindings.count == 6, "New profile did not load and enable all six controls")
        try check(Set(fresh.activeBindings.map(\.triggerID)) == Set(["key.0", "key.1", "key.2", "knob.press", "knob.left", "knob.right"]), "New profile lacks a physical control")
        try check(fresh.activeBindings[4].steps[0].scrollLines == 19 && fresh.activeBindings[5].steps[0].scrollLines == 18, "Saved scroll amounts were changed")
        let seededFile = freshDirectory.appendingPathComponent("workflows.json"), seededBytes = try Data(contentsOf: seededFile)
        fresh.enabled = false
        let existing = WorkflowStore(directory: freshDirectory, preferences: preferences)
        try check(!existing.enabled && existing.activeBindings == fresh.activeBindings && Data(contentsOf: seededFile) == seededBytes, "Reopen reset the preset or re-enabled disabled actions")
        let explicitlyDisabled = WorkflowStore(directory: root.appendingPathComponent("explicit-disabled"), preferences: preferences)
        try check(!explicitlyDisabled.enabled && explicitlyDisabled.activeBindings.count == 6, "New defaults overrode an explicit disabled preference")
        preferences.removeObject(forKey: "hardwareCustomActionsEnabled.v1")
        let emptyDirectory = root.appendingPathComponent("saved-empty"), emptyFile = emptyDirectory.appendingPathComponent("workflows.json")
        try WorkflowPersistence.save([], to: emptyFile)
        let emptyBytes = try Data(contentsOf: emptyFile), emptyStore = WorkflowStore(directory: emptyDirectory, preferences: preferences)
        try check(emptyStore.bindings.isEmpty && !emptyStore.enabled && Data(contentsOf: emptyFile) == emptyBytes, "Saved empty choices were replaced by first-use defaults")
        let presetWheel = RadialMenuStore(directory: root.appendingPathComponent("fresh-wheel"))
        try check(presetWheel.configuration.enabled && presetWheel.configuration.activation == .knobPress && presetWheel.configuration.items.count == 12 && presetWheel.configuration.pageCount == 2, "Fresh wheel is incomplete or not reachable from knob press")
        try check(presetWheel.configuration.items.map(\.name) == ["窗口总览", "复制", "粘贴", "撤销", "全选", "重做", "打开 GitHub", "进入或退出全屏", "静音切换", "显示全部窗口", "整个屏幕截图", "选择区域截图"], "Wheel order or saved action names changed")
        let portable = try RadialMenuCodec.encode(presetWheel.configuration)
        let portableText = String(decoding: portable, as: UTF8.self)
        try check(!portableText.contains("/Users/") && presetWheel.configuration.items.flatMap(\.steps).allSatisfy { $0.kind != .openURL || $0.argument == "https://github.com" }, "Personal paths or URLs entered a public preset")
        let emptyWheelDirectory = root.appendingPathComponent("empty-wheel")
        try FileManager.default.createDirectory(at: emptyWheelDirectory, withIntermediateDirectories: true)
        let emptyWheelFile = emptyWheelDirectory.appendingPathComponent("radial-menu.json")
        let emptyWheelBytes = try RadialMenuCodec.encode(RadialMenuDocument(schemaVersion: 3, enabled: false))
        try emptyWheelBytes.write(to: emptyWheelFile)
        let emptyWheel = RadialMenuStore(directory: emptyWheelDirectory)
        try check(!emptyWheel.configuration.enabled && emptyWheel.configuration.items.isEmpty && Data(contentsOf: emptyWheelFile) == emptyWheelBytes, "Saved empty wheel was replaced or enabled")
        let brokenDirectory = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        let brokenFile = brokenDirectory.appendingPathComponent("workflows.json"), raw = Data("not a workflow".utf8)
        try raw.write(to: brokenFile)
        let broken = WorkflowStore(directory: brokenDirectory)
        broken.bindings = store.bindings
        try await settle()
        try check(!broken.flushAutomaticSave() && Data(contentsOf: brokenFile) == raw, "Autosave destroyed an unreadable file")

        let radialDirectory = root.appendingPathComponent("radial")
        var reads = 0, failReads = false
        let radial = RadialMenuStore(directory: radialDirectory, readData: { url in
            reads += 1
            if failReads { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        reads = 0
        let radialInitial = try Data(contentsOf: radial.fileURL), originalItems = radial.configuration.items
        radial.selectedID = radial.draft.items.last?.id
        try await settle()
        try check(reads == 0 && Data(contentsOf: radial.fileURL) == radialInitial, "Selecting a wheel sector wrote configuration")
        for name in ["first", "second", "final"] { radial.draft.items[0].name = name }
        try await settle()
        try check(reads == 2 && radial.configuration.items[0].name == "final", "Wheel edits were not coalesced into one verified save")
        try check(radial.configuration.items.map(\.id) == originalItems.map(\.id), "Wheel autosave changed item IDs")
        let goodWheel = try Data(contentsOf: radial.fileURL)
        radial.draft.items[0].name = ""
        try await settle()
        try check(radial.error != nil && Data(contentsOf: radial.fileURL) == goodWheel && radial.configuration.items[0].name == "final", "Empty wheel name overwrote a valid item")
        radial.draft.items[0].name = "fixed"
        radial.draft.activation = .topHold; radial.draft.schemaVersion = 3
        try await settle()
        let readback = try RadialMenuCodec.decode(Data(contentsOf: radial.fileURL))
        try check(radial.error == nil && readback.activation == .topHold && readback.schemaVersion == 3 && readback.items[0].name == "fixed", "Wheel trigger/schema did not auto-save together")
        let fixedBytes = try Data(contentsOf: radial.fileURL)
        failReads = true; radial.draft.items[0].name = "retry"
        try await settle()
        try check(radial.error != nil && radial.configuration.items[0].name == "fixed" && Data(contentsOf: radial.fileURL) == fixedBytes, "Failed read was reported as a saved configuration")
        failReads = false
        try check(radial.flushAutomaticSave() && radial.configuration.items[0].name == "retry", "Retry did not preserve and save the wanted value")
        radial.draft.items.append(RadialMenuItem(name: "new", steps: [WorkflowStep(kind: .shortcut, keyCode: 8, modifiers: 0x100000)]))
        try check(radial.flushAutomaticSave(), "Final wheel flush failed")
        let reopenedRadial = RadialMenuStore(directory: radialDirectory)
        try check(reopenedRadial.configuration == radial.configuration && reopenedRadial.configuration.items.count == RadialMenuStore.defaults.items.count + 1, "Wheel reopen lost final edits")
        try check(reopenedRadial.configuration.items.prefix(originalItems.count).map(\.id) == originalItems.map(\.id), "Appending an item changed earlier identities")
        let futureDirectory = root.appendingPathComponent("future")
        try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        let futureData = Data("{\"schemaVersion\":99,\"enabled\":false,\"items\":[]}".utf8)
        try futureData.write(to: futureDirectory.appendingPathComponent("radial-menu.json"))
        let future = RadialMenuStore(directory: futureDirectory)
        future.draft.items[0].name = "must not overwrite"
        try await settle()
        try check(!future.isReady && !future.flushAutomaticSave() && Data(contentsOf: future.fileURL) == futureData, "Unknown schema was replaced by defaults")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"hostActionsExecuted\":0,\"physicalDeviceWrites\":0,\"realUserDataTouched\":false}")
    }
}
