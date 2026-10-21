import AppKit
import SwiftUI
import VibekeyCore

/// Owned display-only inspection. Fixtures use callbacks, never a HID session.
@MainActor enum VibekeyUIProbe {
    static func run(runtime: VibekeyRuntime) async {
        guard runtime.probe else { return }
        let directory = runtime.directory
        var receipt: [String: Any] = ["product": "hardware-controller", "deviceWrites": 0, "microphoneStarted": false, "cloudRequests": 0, "hostActionsExecuted": 0]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.sleep(nanoseconds: 350_000_000)
            guard DeviceProductArtwork.au05Image != nil else { throw ProbeFailure("Complete AU05 3D artwork missing") }
            guard runtime.workflows.bindings.count == 6, runtime.workflows.bindings.allSatisfy({ $0.steps.allSatisfy { $0.kind == .passthrough } }), !runtime.workflows.enabled else { throw ProbeFailure("Six original key defaults were not retained") }
            let deviceFixtures = try (0..<6).map { index in try AU05OnboardShortcut(index: UInt8(index), entries: index >= 4 ? [.init(page:7,usage:index == 4 ? 6:5)] : [.init(page:2,usage:40)]) }
            runtime.onboard.installLayoutFixture(deviceFixtures)
            func workspace(_ section: AU05ConfigurationSection = .keys, destination: VibekeyDestination = .devices, native: Bool = true) -> VibekeyWorkspace {
                VibekeyWorkspace(device: runtime.device, workflows: runtime.workflows, settings: runtime.settings,
                    radialStore: runtime.radialStore, radial: runtime.radial, lighting: runtime.lighting, agentSignals: runtime.agentSignals,
                    onboard: native ? runtime.onboard:nil, initialDestination: destination, initialAU05Section: section)
            }
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                let label = appearance == .aqua ? "light" : "dark"
                for section in AU05ConfigurationSection.allCases {
                    try await snapshot(workspace(section), appearance: appearance, name: "au05-" + section.rawValue + "-" + label, directory: directory)
                }
                try await snapshot(workspace(native:true), appearance: appearance, name:"onboard-keys-"+label,directory:directory)
                try await snapshot(workspace(native:true), appearance: appearance, name:"onboard-keys-minimum-"+label,directory:directory,width:980,height:700)
                let originalSelection = runtime.workflows.selectedID
                runtime.workflows.selectedID = runtime.workflows.bindings.first { $0.triggerID == "knob.right" }?.id
                try await snapshot(workspace(), appearance: appearance, name: "scroll-right-minimum-" + label, directory: directory, width: 980, height: 700)
                try await snapshot(workspace(native:true), appearance: appearance, name:"onboard-scroll-minimum-"+label,directory:directory,width:980,height:700)
                let originalRadial = runtime.radialStore.configuration
                runtime.radialStore.draft.activation = .topHold; runtime.radialStore.draft.schemaVersion = 3; runtime.radialStore.draft.enabled = true
                guard runtime.radialStore.save() else { throw ProbeFailure("Private trigger fixture could not save") }
                runtime.workflows.selectedID = runtime.workflows.bindings.first { $0.triggerID == "key.0" }?.id
                try await snapshot(workspace(), appearance: appearance, name: "hold-trigger-" + label, directory: directory)
                runtime.workflows.selectedID = runtime.workflows.bindings.first { $0.triggerID == "knob.press" }?.id
                try await snapshot(workspace(), appearance: appearance, name: "knob-independent-" + label, directory: directory)
                runtime.radialStore.draft.activation = .knobPress; runtime.radialStore.draft.enabled = true
                guard runtime.radialStore.save() else { throw ProbeFailure("Private single trigger fixture could not save") }
                try await snapshot(workspace(), appearance: appearance, name: "single-trigger-inspector-" + label, directory: directory)
                runtime.radialStore.draft = originalRadial
                guard runtime.radialStore.save() else { throw ProbeFailure("Private trigger fixture could not restore") }
                runtime.workflows.selectedID = originalSelection
                for section in [AU05ConfigurationSection.keys, .radial, .parameters] {
                    try await snapshot(workspace(section), appearance: appearance, name: "au05-" + section.rawValue + "-minimum-" + label, directory: directory, width: 980, height: 700)
                }
                try await snapshot(workspace(destination: .setup), appearance: appearance, name: "setup-" + label, directory: directory)
                try await snapshot(HardwareSettingsView(settings: runtime.settings, updates: runtime.updates), appearance: appearance, name: "settings-" + label, directory: directory, width: 600, height: 700)
            }
            let original = runtime.workflows.bindings
            runtime.workflows.bindings[0].steps = [WorkflowStep(kind: .shortcut, keyCode: 8, modifiers: 0x100000)]
            try await snapshot(workspace(), appearance: .aqua, name: "quick-shortcut", directory: directory)
            let sources = InputSourceCatalog.available
            if let source = sources.first {
                runtime.workflows.bindings[0].steps = [WorkflowStep(kind: .inputSource, argument: source.id)]
                try await snapshot(workspace(), appearance: .aqua, name: "quick-input-source", directory: directory)
            }
            runtime.workflows.bindings = original
            receipt["AU05Sidebar"] = AU05ConfigurationSection.allCases.map(\.rawValue)
            receipt["launchDestination"] = "AU05 keys; AU05-only sidebar"
            receipt["deviceGalleryRemoved"] = true; receipt["nestedSectionTabsRemoved"] = true; receipt["scrollRange"] = "1...50"; receipt["radialActivationModes"] = RadialActivation.allCases.count
            receipt["deviceArtworkLoaded"] = DeviceProductArtwork.au05Image != nil
            receipt["deviceArtworkResource"] = "Devices/au05-3d.png"
            receipt["deviceArtwork"] = "Complete project-authored revision B 3D render; no simplified substitute"
            receipt["nativeSnapshots"] = (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "png" }.count
            receipt["AU05CaptureStarted"] = runtime.device.connected; receipt["result"] = "PASS_NATIVE_RENDERING_ONLY"
        } catch { receipt["result"] = "FAIL"; receipt["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("ui-receipt.json"), options: .atomic) }
        NSApp.terminate(nil)
    }
    private static func snapshot<V:View>(_ view:V,appearance:NSAppearance.Name,name:String,directory:URL,width:CGFloat=1160,height:CGFloat=820) async throws {
        let host=NSHostingView(rootView:view.frame(width:width,height:height).background(VIFLOWTheme.canvas).font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink));host.frame=NSRect(x:0,y:0,width:width,height:height)
        host.appearance=NSAppearance(named:appearance)
        let window=NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=host;window.appearance=host.appearance
        defer {window.contentView=nil}
        host.layoutSubtreeIfNeeded();host.displayIfNeeded();try await Task.sleep(nanoseconds:120_000_000)
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw ProbeFailure("Native image unavailable")}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else {throw ProbeFailure("PNG export unavailable")}
        try data.write(to:directory.appendingPathComponent(name+".png"))
    }
}
private struct ProbeFailure:LocalizedError {let message:String;init(_ message:String){self.message=message};var errorDescription:String? {message}}
