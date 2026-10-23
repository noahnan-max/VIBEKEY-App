import AppKit
import SwiftUI
import VibekeyCore

@MainActor enum UsageStatisticsUIProbe {
    private static var fixtureWindow: NSWindow?
    static func run(runtime: VibekeyRuntime) async {
        let directory = runtime.directory
        var result: [String: Any] = ["deviceStarted": false, "externalInputRead": false, "microphoneStarted": false]
        do {
            var fixture = UsageStatisticsLedger(); fixture.startedAt = Calendar.current.date(byAdding: .day, value: -100, to: Date())
            for n in 0..<100 where n % 9 != 0 || n < 4 {
                let at = Calendar.current.date(byAdding: .day, value: -n, to: Date())!
                fixture.record(at: at, seconds: Double(60 + n * 3), characters: 200 + n * 47,
                               source: n % 4 == 0 ? .estimated : .observed)
            }
            fixture.preferences.enabled = true; fixture.preferences.observationConsentVersion = 1
            runtime.usage.installFixture(fixture)
            func workspace() -> VibekeyWorkspace {
                VibekeyWorkspace(device: runtime.device, workflows: runtime.workflows, settings: runtime.settings,
                    radialStore: runtime.radialStore, radial: runtime.radial, lighting: runtime.lighting, agentSignals: runtime.agentSignals,
                    onboard: runtime.onboard, initialDestination: .statistics, usage: runtime.usage)
            }
            for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
                for size in [NSSize(width: 1160, height: 820), NSSize(width: 980, height: 700)] {
                    try await snapshot(workspace(), appearance: appearance, directory: directory,
                        name: "usage-\(appearance == .aqua ? "light" : "dark")-\(Int(size.width))", size: size)
                }
            }
            runtime.usage.installFixture(UsageStatisticsLedger())
            try await snapshot(workspace(), appearance: .aqua, directory: directory, name: "usage-empty", size: NSSize(width: 1160, height: 820))
            runtime.usage.installFixture(fixture)
            runtime.usage.installLiveFixture(characters: 42, seconds: 8)
            try await snapshot(workspace(), appearance: .aqua, directory: directory, name: "usage-live", size: NSSize(width: 1160, height: 820))
            result["liveReceivedCharacters"] = runtime.usage.displayLedger.totals.totalCharacters - fixture.totals.totalCharacters
            result["liveSummary"] = runtime.usage.liveSummary
            runtime.usage.installFixture(fixture)
            result["result"] = "PASS_NATIVE_RENDERING_ONLY"; result["statisticsFirst"] = true
            result["sourceSeparation"] = ["observed": fixture.totals.observedCharacters, "estimated": fixture.totals.estimatedCharacters]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("usage-ui-receipt.json"))
            if CommandLine.arguments.contains("--usage-interactive") {
                NSApp.setActivationPolicy(.regular)
                let window = NSWindow(contentRect: NSRect(x: 150, y: 100, width: 1160, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.title = "使用统计 · 隔离验收（合成数据）"
                window.contentView = NSHostingView(rootView: workspace().overlay(alignment: .bottomTrailing) {
                    Text("合成数据 · 隔离验收 · 不读取外部输入").font(.caption).padding(8).background(VIFLOWTheme.muted)
                })
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); fixtureWindow = window
                Task { @MainActor in
                    for n in 1...24 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        runtime.usage.installLiveFixture(characters: n * 7, seconds: Double(n) / 2)
                    }
                }
                return
            }
        } catch {
            result["result"] = "FAIL"; result["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject: result).write(to: directory.appendingPathComponent("usage-ui-receipt.json"))
        }
        NSApp.terminate(nil)
    }
    private static func snapshot<V: View>(_ view: V, appearance: NSAppearance.Name, directory: URL, name: String, size: NSSize) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(VIFLOWTheme.canvas))
        host.frame = NSRect(origin: .zero, size: size); host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; window.appearance = host.appearance
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
