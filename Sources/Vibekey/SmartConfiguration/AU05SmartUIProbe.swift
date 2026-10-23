import AppKit
import SwiftUI
import VibekeyCore

/// Loopback and synthetic-state only. No live key, cloud, HID or macro execution.
@MainActor enum AU05SmartUIProbe {
    private struct Failure: Error { let message: String }
    private static let canary = "FIXTURE_PRIVATE_MACRO_NEVER_UPLOAD"
    private static let fixtureKey = "fixture-only-value-not-a-secret"

    @MainActor private final class Fixture {
        let host: WorkflowStore
        let connection = UUID()
        var shortcuts: [AU05OnboardShortcut]
        var lights: [UInt8] = [0, 0, 2, 13] + Array(repeating: 3, count: 20)
        var follow = false
        var writes = 0
        init(directory: URL) throws {
            host = WorkflowStore(directory: directory)
            host.bindings = [WorkflowBinding(name: "Synthetic private macro", triggerID: "key.2",
                steps: [WorkflowStep(kind: .runShortcut, argument: AU05SmartUIProbe.canary)])]
            guard host.flushAutomaticSave() else { throw Failure(message: "Synthetic host seed did not persist") }
            shortcuts = try (0..<6).map { try AU05OnboardShortcut(index: UInt8($0), entries: [.init(page: 2, usage: 40)]) }
        }
        func snapshot() throws -> AU05SmartSnapshot {
            AU05SmartSnapshot(connectionID: connection, firmware: "4.5.1", shortcuts: shortcuts,
                lightingPayload: lights, workflows: try host.readSmartConfiguration(),
                workflowsEnabled: host.enabled, agentLightingEnabled: follow, knobPressReserved: false)
        }
        var adapter: AU05SmartAdapter {
            .init(read: { try self.snapshot() },
                  writeShortcut: { self.shortcuts[Int($0.index)] = $0; self.writes += 1 },
                  writeLighting: { _, value in self.lights = value.rawPayload; self.writes += 1 },
                  writeHost: { before, after in
                    try self.host.reserveSmartConfiguration()
                    defer { self.host.endSmartConfiguration() }
                    try self.host.writeSmartConfiguration(expected: before.workflows, desired: after.workflows,
                        expectedEnabled: before.workflowsEnabled, desiredEnabled: after.workflowsEnabled)
                    self.follow = after.agentLightingEnabled; self.writes += 1
                  })
        }
    }

    static func run(runtime: VibekeyRuntime) async {
        guard runtime.probe else { return }
        let directory = runtime.directory
        var report: [String: Any] = ["physicalDeviceWrites": 0, "hostInputPosted": 0,
            "cloudRequests": 0, "realKeychainDataReads": 0, "realKeychainMetadataReads": 0]
        do {
            guard !runtime.device.connected,
                  !CommandLine.arguments.dropFirst().contains(where: {
                      $0.hasPrefix("--au05-") && $0 != "--au05-smart-probe"
                  }),
                  let base = CommandLine.arguments.first(where: { $0.hasPrefix("--smart-fixture-base=") })
                    .map({ String($0.dropFirst("--smart-fixture-base=".count)) }),
                  let url = URLComponents(string: base), url.scheme == "http", url.host == "127.0.0.1",
                  url.port != nil, url.user == nil, url.password == nil, url.query == nil,
                  url.fragment == nil, url.path.isEmpty else { throw Failure(message: "Loopback-only probe arguments required") }
            let modelDirectory = directory.appendingPathComponent("SyntheticModel", isDirectory: true)
            guard !FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("model.json").path) else {
                throw Failure(message: "Fresh fixture model directory required")
            }
            // hasKey must short-circuit when there are no saved model settings.
            let model = SmartConfigurationStore(directory: modelDirectory)
            model.baseURL = base + "/v1"; model.model = "au05-native-fixture"; model.apiKeyInput = fixtureKey
            let fixtureDirectory = directory.appendingPathComponent("SyntheticHost", isDirectory: true)
            let fixture = try Fixture(directory: fixtureDirectory)
            let store = AU05SmartConfigurationStore(model: model, device: runtime.device, onboard: runtime.onboard,
                workflows: fixture.host, lighting: runtime.lighting, radial: runtime.radialStore,
                directory: directory, fixture: fixture.adapter)
            let original = try fixture.snapshot()
            let context = String(decoding: try JSONSerialization.data(withJSONObject: AU05SmartModel.context(original)), as: UTF8.self)
            guard !context.contains(canary), !context.contains(original.connectionID.uuidString) else {
                throw Failure(message: "Synthetic private context leaked")
            }
            model.testConnection(); try await waitModel(model)
            guard model.error == nil, model.modelReady, fixture.writes == 0 else {
                throw Failure(message: "AU05 loopback connection test did not verify")
            }
            report["connectionTestZeroWrites"] = true
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                try await image(AU05SmartConfigurationView(store: store), appearance: appearance, directory: directory,
                    name: "smart-settings-\(appearance == .aqua ? "light" : "dark")", width: 820, height: 760)
            }
            store.request = "上键设为F20；中键宏为Command+C、等待0.3秒、Command+V；灯光全亮亮度8。其他不改。"
            store.generate(); try await waitStore(store)
            guard let prepared = store.prepared, prepared.hasChanges, fixture.writes == 0,
                  prepared.desired.shortcuts[0].recordedShortcut?.keyCode == 90,
                  prepared.desired.workflows.first(where: { $0.triggerID == "key.1" })?.steps.count == 3,
                  try prepared.desired.lighting.mode == .allOn, try prepared.desired.lighting.brightness == 8 else {
                throw Failure(message: store.error ?? "AU05 preview did not match synthetic request")
            }
            guard !prepared.acknowledgements.isEmpty, !store.canApply else {
                throw Failure(message: "Impact confirmation gate missing")
            }
            store.apply(); try await waitStore(store)
            guard fixture.writes == 0, try fixture.snapshot() == original else {
                throw Failure(message: "Unconfirmed apply changed synthetic state")
            }
            report["previewZeroWrites"] = true; report["unconfirmedApplyZeroWrites"] = true
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                for size in [(820, 900), (720, 680)] {
                    try await image(AU05SmartConfigurationView(store: store), appearance: appearance, directory: directory,
                        name: "au05-preview-\(appearance == .aqua ? "light" : "dark")-\(size.0)",
                        width: size.0, height: size.1)
                }
            }
            store.acknowledged = true
            guard store.canApply else { throw Failure(message: "Confirmed synthetic plan cannot apply") }
            store.apply(); try await waitStore(store)
            guard store.error == nil, store.verification != nil, let backup = store.lastBackup,
                  try store.archive.load(backup) == original,
                  try fixture.snapshot() == prepared.desired else { throw Failure(message: "Complete apply/backup readback mismatch") }
            let cold = WorkflowStore(directory: fixtureDirectory)
            guard cold.activeBindings == prepared.desired.workflows else { throw Failure(message: "Cold host-file readback mismatch") }
            report["backupAndCompleteReadback"] = true; report["coldHostFileReadback"] = true
            store.restore(); try await waitStore(store)
            let restored = WorkflowStore(directory: fixtureDirectory)
            guard store.error == nil, try fixture.snapshot() == original,
                  restored.activeBindings == original.workflows, !runtime.device.connected,
                  !FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("model.json").path) else {
                throw Failure(message: "Synthetic restore or isolation failed")
            }
            report["restoreAllFields"] = true; report["privateMacroAndIDExcluded"] = true
            report["fixtureWrites"] = fixture.writes; report["nativeSnapshots"] = 6
            report["actualButtonClick"] = "NOT_RUN_PROGRAMMATIC_CONFIRMATION_GATE_ONLY"
            report["result"] = "PASS_AU05_NATIVE_LOOPBACK_SYNTHETIC_TRANSACTION"
        } catch {
            report["result"] = "FAIL"
            report["error"] = (error as? Failure)?.message ?? error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? SmartPrivateFiles.write(data, to: directory.appendingPathComponent("au05-smart-receipt.json"))
        }
        NSApp.terminate(nil)
    }
    private static func waitModel(_ model: SmartConfigurationStore) async throws {
        let deadline = Date().addingTimeInterval(35)
        while model.isBusy {
            guard Date() < deadline else { throw Failure(message: "Model fixture timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private static func waitStore(_ store: AU05SmartConfigurationStore) async throws {
        let deadline = Date().addingTimeInterval(35)
        while store.isBusy {
            guard Date() < deadline else { throw Failure(message: "Synthetic transaction timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private static func image<V: View>(_ view: V, appearance: NSAppearance.Name, directory: URL,
                                      name: String, width: Int, height: Int) async throws {
        let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: CGFloat(height)))
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try await Task.sleep(nanoseconds: 120_000_000)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "Native render unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "PNG export failed") }
        try bytes.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
