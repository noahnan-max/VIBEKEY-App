import Foundation
import VibekeyCore

@main @MainActor enum PublicUpgradeChecks {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1
    }
    static func main() throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Vibekey/OwnedProbes/public-upgrade-" + UUID().uuidString)
        let suite = "io.github.noahnan-max.VIBEKEY.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for file in ["workflows.json", "radial-menu.json"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(file), to: old.appendingPathComponent(file))
        }
        let workflowBytes = try Data(contentsOf: old.appendingPathComponent("workflows.json"))
        let radialBytes = try Data(contentsOf: old.appendingPathComponent("radial-menu.json"))
        preferences.set(false, forKey: "hardwareCustomActionsEnabled.v1")
        let workflows = WorkflowStore(directory: old, preferences: preferences)
        let radial = RadialMenuStore(directory: old)
        check(workflows.bindings.count == 1 && workflows.bindings[0].name == "Synthetic old public profile", "Released custom workflow loads")
        check(!workflows.enabled && !radial.configuration.enabled, "Existing off switches retained")
        check(radial.configuration.items.count == 1 && radial.configuration.activation == .knobPress,
              "Released radial profile retained: \(radial.error ?? "no error"); items \(radial.configuration.items.count)")
        check(workflows.flushAutomaticSave() && radial.flushAutomaticSave(), "No-change flush succeeds")
        check(try Data(contentsOf: old.appendingPathComponent("workflows.json")) == workflowBytes, "Workflow bytes unchanged")
        check(try Data(contentsOf: old.appendingPathComponent("radial-menu.json")) == radialBytes, "Radial bytes unchanged")
        try workflows.reserveSmartConfiguration()
        check(try workflows.readSmartConfiguration() == workflows.bindings, "Smart reader sees existing configuration")
        workflows.endSmartConfiguration()

        preferences.removeObject(forKey: "hardwareCustomActionsEnabled.v1")
        let fresh = root.appendingPathComponent("fresh")
        let initial = WorkflowStore(directory: fresh, preferences: preferences)
        let initialRadial = RadialMenuStore(directory: fresh)
        check(initial.bindings.count == 6 && initial.enabled, "First use keeps all six enabled daily presets")
        check(initialRadial.configuration.items.count == 12 && initialRadial.configuration.enabled, "First use keeps 12 radial presets")
        preferences.set(false, forKey: "hardwareCustomActionsEnabled.v1")
        check(!WorkflowStore(directory: root.appendingPathComponent("explicit-off"), preferences: preferences).enabled, "Explicit disabled choice wins over first-use default")
        let empty = root.appendingPathComponent("existing-empty")
        try WorkflowPersistence.save([], to: empty.appendingPathComponent("workflows.json"))
        check(WorkflowStore(directory: empty, preferences: preferences).bindings.isEmpty, "Existing intentionally empty profile is not reseeded")

        for (index, data) in [Data("{broken".utf8), Data("{\"schemaVersion\":99,\"bindings\":[]}".utf8)].enumerated() {
            let folder = root.appendingPathComponent("invalid-workflow-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("workflows.json"); try data.write(to: path)
            let blocked = WorkflowStore(directory: folder, preferences: preferences)
            blocked.add()
            check(!blocked.flushAutomaticSave(), "Malformed/future workflows cannot autosave")
            check(try Data(contentsOf: path) == data, "Malformed/future workflows preserved")
        }
        var unknown = try JSONSerialization.jsonObject(with: workflowBytes) as! [String: Any]
        var bindings = unknown["bindings"] as! [[String: Any]], steps = bindings[0]["steps"] as! [[String: Any]]
        steps[0]["kind"] = "futureHardwareAction"; bindings[0]["steps"] = steps; unknown["bindings"] = bindings
        let unknownDirectory = root.appendingPathComponent("unknown-kind")
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
        let unknownPath = unknownDirectory.appendingPathComponent("workflows.json")
        let unknownBytes = try JSONSerialization.data(withJSONObject: unknown); try unknownBytes.write(to: unknownPath)
        let unknownStore = WorkflowStore(directory: unknownDirectory, preferences: preferences)
        check(!unknownStore.flushAutomaticSave() && unknownStore.error != nil, "Unknown device action blocks overwrite")
        check(try Data(contentsOf: unknownPath) == unknownBytes, "Unknown action document kept intact")
        for (index, data) in [Data("{broken".utf8), Data("{\"schemaVersion\":99,\"enabled\":true,\"items\":[]}".utf8)].enumerated() {
            let folder = root.appendingPathComponent("invalid-radial-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("radial-menu.json"); try data.write(to: path)
            let blocked = RadialMenuStore(directory: folder); blocked.draft.enabled = true
            check(!blocked.flushAutomaticSave() && !blocked.isReady, "Malformed/future radial data cannot autosave")
            check(try Data(contentsOf: path) == data, "Malformed/future radial file preserved")
        }
        let lighting = try SmartLightingSnapshot(connectionID: UUID(), payload: [0, 0, 1, 8] + Array(repeating: 7, count: 20))
        let ordinary = try SmartLightingWriteRequest(expected: lighting, target: lighting, purpose: .restore)
        let forced = try SmartLightingWriteRequest(expected: lighting, target: lighting, purpose: .restore, force: true)
        check(ordinary.frames.isEmpty && !forced.frames.isEmpty, "Explicit restore can reassert unchanged lighting after an uncertain write")
        check(forced.steps.last?.target == lighting && forced.steps.allSatisfy { $0.target.workRecords == lighting.workRecords }, "Forced restore retains opaque lighting bytes")
        print("PASS: \(checks) released-public configuration preservation and first-use checks; host input 0")
    }
}
