import AppKit
import SwiftUI

/// Isolated real Sparkle installation target. Never constructs a hardware store.
@MainActor final class UpdateAcceptanceDelegate: NSObject, NSApplicationDelegate {
    static let updates = AppUpdateStore()
    private var readyToExit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let path = Bundle.main.object(forInfoDictionaryKey: "FixtureDirectory") as? String,
              path.hasPrefix(NSHomeDirectory()+"/Library/Caches/Vibekey/OwnedProbes/update-acceptance-") else { exit(2) }
        let directory = URL(fileURLWithPath: path)
        Self.updates.prepareForInstallation = { [weak self] in
            try? Data("prepared-before-install".utf8).write(to: directory.appendingPathComponent("prepared.txt"))
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.readyToExit = true
            return true
        }
        Self.updates.start()
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            let value: [String: Any] = ["status": "UPDATED_AND_RELAUNCHED", "version": "2", "path": Bundle.main.bundlePath,
                "preparedBeforeReplacement": FileManager.default.fileExists(atPath: directory.appendingPathComponent("prepared.txt").path),
                "physicalDeviceWrites": 0, "productionConfigurationAccess": false]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("result.json"))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

@main @MainActor struct UpdateAcceptanceApp: App {
    @NSApplicationDelegateAdaptor(UpdateAcceptanceDelegate.self) var delegate
    @StateObject private var updates = UpdateAcceptanceDelegate.updates
    var body: some Scene {
        WindowGroup("VIBEKEY 更新验收（隔离）") {
            VStack(alignment: .leading, spacing: 18) {
                Text("签名更新 · 隔离验收").font(.title2)
                Text("当前版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))
                Text("只更新这个测试 App，不连接设备，不访问个人配置。")
                Text(updates.status).font(.caption)
                if updates.hasUpdateBadge { Label("有新版本 · App 内红点", systemImage:"circle.fill").foregroundColor(.red) }
                Button("检查测试更新…") { updates.checkNow() }.disabled(!updates.canCheck)
                if updates.availableVersion != nil {
                    Text(updates.availableNotes).font(.caption)
                    Button("更新并重新启动…") { updates.installAvailableUpdate() }
                }
            }.padding(28).frame(width: 540, height: 360)
        }
    }
}
