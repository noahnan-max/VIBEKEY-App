import AppKit
import Combine
import SwiftUI
import VibekeyCore
import UserNotifications

@main @MainActor struct VibekeyApp:App {
    @NSApplicationDelegateAdaptor(VibekeyDelegate.self) private var delegate
    private let runtime=VibekeyRuntime.shared
    @StateObject private var launch=VibekeyRuntime.shared.launch
    @StateObject private var updates=VibekeyRuntime.shared.updates
    @StateObject private var settings=VibekeyRuntime.shared.settings
    @StateObject private var device=VibekeyRuntime.shared.device
    var body:some Scene {
        WindowGroup("VIBEKEY",id:"main") {
            workspace.disabled(settings.suspended)
                .background(MainWindowMarker().frame(width:0,height:0).allowsHitTesting(false))
                .background(MainWindowActions {delegate.reopenMain=$0}.frame(width:0,height:0).allowsHitTesting(false))
                .onAppear {
                    if runtime.probe || launch.background {
                        NSApp.windows.filter{$0.identifier?.rawValue == "vibekey.main"}.forEach{$0.orderOut(nil)}
                    }
                }
        }.defaultSize(width:1160,height:820)
            .commands {
                CommandGroup(replacing:.newItem) {}
                CommandGroup(after:.appInfo) { Button("检查更新…") {SettingsPresentation.show();updates.checkNow()}.disabled(!updates.canCheck) }
                CommandMenu("设备") {
                    Button("刷新设备状态") {runtime.device.refresh()}.keyboardShortcut("r",modifiers:.command).disabled(settings.suspended)
                    Button("取消当前宏") {runtime.workflows.cancel();runtime.radial.cancel()}
                }
            }
        Settings {HardwareSettingsView(settings:settings,updates:updates).disabled(settings.suspended)}
        MenuBarExtra {
            Group {
            Text("VIBEKEY · 设备控制")
            Text("关窗后继续运行；从此菜单退出才停止。")
            Text(device.snapshot.batteryPercent.map { "设备电量 \($0)%" + (device.batteryIsFresh(at: Date()) ? "" : " · 非实时") } ?? "电量未读取")
            }
            if let warning = device.batteryWarning(at: Date()) { Text(warning.message) }
            Button("打开我的设备") {delegate.showMain()}
            Divider()
            Button("取消当前宏") {runtime.workflows.cancel();runtime.radial.cancel()}
            Button(updates.hasUpdateBadge ? "App 设置… · 有新版本" : "设置…") {SettingsPresentation.show()}
            Button("检查更新…") {SettingsPresentation.show();updates.checkNow()}.disabled(!updates.canCheck)
            Divider();Button("退出 VIBEKEY") {NSApp.terminate(nil)}
        } label:{
            ZStack(alignment:.topTrailing) {
                Image(nsImage:VibekeyBrand.menuBarIdle)
                if updates.hasUpdateBadge { Circle().fill(Color(nsColor:.systemRed)).frame(width:5,height:5).offset(x:2,y:-2) }
            }.accessibilityLabel(updates.hasUpdateBadge ? "VIBEKEY，有新版本" : "VIBEKEY").help("VIBEKEY · 设备控制")
        }
        .menuBarExtraStyle(.menu)
    }
    private var workspace:some View {
        VibekeyWorkspace(device:runtime.device,workflows:runtime.workflows,settings:runtime.settings,radialStore:runtime.radialStore,radial:runtime.radial,lighting:runtime.lighting,agentSignals:runtime.agentSignals,onboard:runtime.onboard,batteryNotifications:runtime.batteryNotifications,updateAvailable:updates.hasUpdateBadge)
    }
}

@MainActor final class VibekeyRuntime {
    static let shared=VibekeyRuntime()
    let probe:Bool
    let directory:URL
    private let ownership:RuntimeOwnership.Lease
    let device:DeviceStore
    let workflows:WorkflowStore
    let settings:HardwareSettings
    let launch=AppLaunchState()
    let updates:AppUpdateStore
    let radialStore:RadialMenuStore
    let radial:RadialMenuController
    let lighting:SmartLightingController
    let agentSignals:AgentSignalStore
    let onboard:AU05OnboardStore
    let batteryNotifications:BatteryNotificationController?
    private init() {
        probe=CommandLine.arguments.contains("--ui-probe")
        updates=AppUpdateStore(live:!probe)
        let argument=CommandLine.arguments.first{$0.hasPrefix("--probe-directory=")}.map{URL(fileURLWithPath:String($0.dropFirst("--probe-directory=".count)))}
        if probe {
            guard let argument,argument.standardizedFileURL.path.hasPrefix(NSHomeDirectory()+"/Library/Caches/Vibekey/OwnedProbes/") else {fputs("Owned probe directory required.\n",stderr);exit(2)}
            directory=argument
        } else {directory=VibekeyPaths.applicationSupport}
        ownership=Self.acquire(directory:directory,probe:probe)
        let device=DeviceStore();self.device=device
        batteryNotifications=probe ? nil:BatteryNotificationController(center:.current(),isCurrent:{ alert in
            device.batteryIsFresh(at:Date()) && device.batteryWarning(at:Date()) == alert.warning && device.lastBatteryAlert == alert
        })
        workflows=WorkflowStore(directory:probe ? directory:nil);settings=HardwareSettings(preferences:probe ? nil:.standard)
        radialStore=RadialMenuStore(directory:probe ? directory:nil)
        radial=RadialMenuController(store:radialStore,observeWorkspace:!probe)
        lighting=SmartLightingController(adapter:.init(read:{id in try await device.readLighting(connection:id)},apply:{request,permit in try await device.applyLighting(request,permit:permit)}), preferences:probe ? nil:.standard)
        agentSignals=AgentSignalStore(directory:probe ? directory.appendingPathComponent("AgentSignals",isDirectory:true):nil, desktopReader:probe ? nil:CodexDesktopStatusReader())
        onboard=AU05OnboardStore(device:device,directory:directory,preferences:probe ? nil:.standard)
    }
    private static func acquire(directory:URL,probe:Bool)->RuntimeOwnership.Lease {
        do {
            switch try RuntimeOwnership.acquire(directory:directory.appendingPathComponent("Runtime",isDirectory:true)) {
            case .acquired(let lease):return lease
            case .alreadyOwned:
                if !probe,!CommandLine.arguments.contains("--background"),let identifier=Bundle.main.bundleIdentifier {
                    let peers=NSRunningApplication.runningApplications(withBundleIdentifier:identifier).filter{!$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier}
                    if peers.count==1 {peers[0].activate(options:[.activateAllWindows,.activateIgnoringOtherApps])}
                }
                fputs("VIBEKEY is already running; no second device owner started.\n",stderr);exit(0)
            }
        } catch {
            if !probe {
                NSApplication.shared.setActivationPolicy(.regular)
                let alert=NSAlert();alert.messageText="VIBEKEY 暂时无法启动";alert.informativeText=error.localizedDescription;alert.addButton(withTitle:"退出");alert.runModal()
            }
            exit(2)
        }
    }
}

@MainActor private struct MainWindowActions:View {
    @Environment(\.openWindow) private var openWindow
    let install:(@escaping ()->Void)->Void
    var body:some View {Color.clear.onAppear {install {NSApp.setActivationPolicy(.regular);openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}}}
}

@MainActor final class VibekeyDelegate:NSObject,NSApplicationDelegate {
    var reopenMain:(()->Void)?
    private var runtime:VibekeyRuntime?
    private var subscriptions:Set<AnyCancellable>=[]
    private var statusTimer:Timer?
    private var notificationPermissionObserver:NSObjectProtocol?
    private var closingObserver:NSObjectProtocol?
    private var lightingBackup:URL?
    private let interaction=HardwareInteractionDiagnostics()
    private let originals=AU05OriginalActions()
    private var router=HardwareBindingRouter()
    private var preparingExit=false,exitPrepared=false
    private var lastLightingEventKey:String?
    private var lastHardwareInput="等待按键"
    func applicationDidFinishLaunching(_ notification:Notification) {
        let runtime=VibekeyRuntime.shared;self.runtime=runtime
        runtime.launch.readLoginEvent()
        NSApp.setActivationPolicy(runtime.launch.background ? .accessory:.regular)
        let device=runtime.device,settings=runtime.settings,workflows=runtime.workflows,radial=runtime.radial
        device.onLowBatteryAlert = { [weak notifications=runtime.batteryNotifications] alert in
            guard let notifications else {return}
            Task { @MainActor in await notifications.deliver(alert) }
        }
        if let notifications=runtime.batteryNotifications {
            Task {await notifications.refreshPermission()}
            notificationPermissionObserver=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak notifications] _ in
                guard let notifications else {return}
                Task { @MainActor in await notifications.refreshPermission() }
            }
        }
        settings.applyAppearance()
        runtime.onboard.canApply = { !ShortcutRecordingButton.isAnyRecording }
        runtime.onboard.onConfigurationChanged = { [weak self] in
            self?.originals.releaseAll()
            self?.writeStatus()
        }
        radial.forward={[weak self] id,pressed in self?.forward(id,pressed:pressed)}
        radial.replayMiddleTap={[weak self] flags in
            guard let self,!preparingExit,!runtime.probe else {return}
            forward("key.1",pressed:true,physicalFlagsOverride:flags);forward("key.1",pressed:false,physicalFlagsOverride:flags)
        }
        radial.replayTap = {[weak self] id,flags in
            self?.forward(id,pressed:true,physicalFlagsOverride:flags);self?.forward(id,pressed:false,physicalFlagsOverride:flags)
        }
        radial.hardwareEligible={[weak self] in
            guard let self else {return false}
            return !runtime.probe && !settings.suspended && settings.accessibilityGranted && device.isReady && !workflows.running && !originals.hasHeldModifier && !ShortcutRecordingButton.isAnyRecording
        }
        radial.previewEligible={!settings.suspended && !workflows.running}
        radial.onLog={[weak device] in device?.log($0)}
        originals.onFailure={[weak device] in device?.error=$0}
        workflows.onLog={[weak device] in device?.log($0)}
        device.onTrigger={[weak self] id,pressed in
            guard let self,!preparingExit else {return}
            lastHardwareInput=id+(pressed ? " 按下":" 松开");radial.handleHardware(id,pressed:pressed);writeStatus()
        }
        device.onControlLoss={[weak self] in self?.resetInputs()}
        installLighting(runtime)
        if !runtime.probe {
            radial.startObservingWorkspace()
            interaction.start {[weak self] in self?.writeStatus()}
            runtime.onboard.start();device.start()
            runtime.agentSignals.start()
            runtime.updates.prepareForInstallation = { [weak self] in await self?.prepareForUpdate() ?? false }
            runtime.updates.start()
            runtime.launch.hideInitialWindows()
            closingObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:nil,queue:.main) { [weak self] notification in
                guard let window=notification.object as? NSWindow else {return}
                Task { @MainActor [weak self,weak window] in
                    guard let self,let window,self.runtime?.probe == false,!self.preparingExit else {return}
                    let otherVisible=NSApp.windows.contains {$0 !== window && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)}
                    if !otherVisible {NSApp.setActivationPolicy(.accessory)}
                }
            }
            let timer=Timer(timeInterval:1,repeats:true) {[weak self] _ in
                guard let owner=self else {return};Task {@MainActor in
                    // Window restoration can finish after the launch callback.
                    runtime.launch.hideInitialWindows()
                    owner.writeStatus()
                }
            }
            statusTimer=timer;RunLoop.main.add(timer,forMode:.common)
            writeStatus()
            if !runtime.launch.background {NSApp.activate(ignoringOtherApps:true)}
        } else {Task {await VibekeyUIProbe.run(runtime:runtime)}}
    }
    private func forward(_ id:String,pressed:Bool,physicalFlagsOverride:UInt64? = nil) {
        guard let runtime,!preparingExit,!runtime.probe else {return}
        let context=NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let binding=runtime.workflows.customBinding(for:id,applicationBundleID:context)
        switch router.route(id,pressed:pressed,customBinding:binding?.id) {
        case .original:originals.handleOnboard(id,pressed:pressed,configuration:runtime.onboard.configuration(for:id),physicalFlagsOverride:physicalFlagsOverride)
        case .custom(let identifier):if let binding,binding.id==identifier {
            if binding.steps.count == 1, let step = binding.steps.first, step.kind == .scrollUp || step.kind == .scrollDown {
                originals.scroll(step,physicalFlagsOverride:physicalFlagsOverride)
            } else {runtime.workflows.run(binding)}
        }
        case .consumed:break
        }
    }
    private func resetInputs() {runtime?.radial.cancel(reason:.ownershipChanged);router.reset();originals.releaseAll();runtime?.workflows.cancel()}
    private func installLighting(_ runtime:VibekeyRuntime) {
        let device=runtime.device,lighting=runtime.lighting
        lighting.onConfirmation = { [weak self] in self?.recordLightingConfirmation($0) }
        lighting.prepareBorrow = { [weak self] value in
            guard let self else {throw ControlError.unavailable}
            try self.backupLighting(value)
        }
        device.onManualLightingChange={[weak lighting] in lighting?.manualLightingWillChange()}
        var previousConnection:UUID?,previousReady=false
        Publishers.Merge(device.$connectionID.map{_ in ()},device.$diagnostics.map{_ in ()}).receive(on:RunLoop.main).sink {[weak self,weak device,weak lighting] _ in
            guard let self,let device,previousConnection != device.connectionID || previousReady != device.isReady else {return}
            previousConnection=device.connectionID;previousReady=device.isReady
            lighting?.setConnection(id:device.connectionID,ready:device.isReady)
            applyAgentLighting(runtime.agentSignals.physicalSnapshot,force:true)
        }.store(in:&subscriptions)
        device.$editing.sink {[weak self,weak lighting] editing in lighting?.setDevicePriority(editing || self?.preparingExit == true)}.store(in:&subscriptions)
        lighting.$enabled.removeDuplicates().receive(on:RunLoop.main).sink {[weak self] enabled in
            if enabled {self?.applyAgentLighting(runtime.agentSignals.physicalSnapshot,force:true)}
        }.store(in:&subscriptions)
        runtime.agentSignals.$physicalSnapshot.removeDuplicates().sink {[weak self] in self?.applyAgentLighting($0)}.store(in:&subscriptions)
    }
    private func applyAgentLighting(_ snapshot:AgentSignalSnapshot,force:Bool=false) {
        guard !snapshot.isSimulation else {return}
        let key=(snapshot.state?.rawValue ?? "unknown")+":"+(snapshot.selectedEventID ?? "none")
        guard force || key != lastLightingEventKey else {return};lastLightingEventKey=key
        let state:SmartLightingState
        switch snapshot.state {
        case .approvalRequired,.attentionRequired:state = .awaitingApproval
        case .running,.stopProposed:state = .running
        case .turnCompleted,.taskCompleted:state = .completed
        case .failed,.interrupted:state = .failed
        case .ended,.none:state = .standby
        }
        runtime?.lighting.updateState(state)
    }
    private func writeStatus() {
        guard let runtime,!runtime.probe else {return}
        let directory=runtime.directory.appendingPathComponent("Diagnostics",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let path=directory.appendingPathComponent("hardware-status.json")
            let status:[String:Any]=["at":ISO8601DateFormatter().string(from:Date()),"version":runtime.settings.version,"writerPID":ProcessInfo.processInfo.processIdentifier,
                "architecture":"hardware-controller","lifecycle":preparingExit || exitPrepared ? "exiting":"running","phase":runtime.workflows.running ? "macroRunning":"idle",
                "deviceShortcutMode":true,"deviceShortcutCount":runtime.onboard.configurations.count,"deviceShortcutBusy":runtime.onboard.isBusy,"deviceShortcutPending":runtime.onboard.hasPendingChanges,"deviceShortcutRecoveryRequired":runtime.onboard.recoveryRequired,
                "accessibility":runtime.settings.accessibilityGranted,"au05Ready":runtime.device.isReady,"receiverAuthenticated":runtime.device.diagnostics.authenticated,
                "lastHardwareInput":lastHardwareInput,"originalKeyEvents":originals.keyEventCount,"originalScrollEvents":originals.scrollEventCount,
                "customActionsEnabled":runtime.workflows.enabled,"radialEnabled":runtime.radialStore.configuration.enabled,"radialItems":runtime.radialStore.configuration.items.count,
                "radialVisible":runtime.radial.isPresented,
                "suspended":runtime.settings.suspended,"interaction":interaction.snapshot,
                "batteryPercent":runtime.device.snapshot.batteryPercent as Any? ?? NSNull(),
                "batteryReadAt":runtime.device.snapshot.lastBatteryReadAt.map { ISO8601DateFormatter().string(from:$0) } as Any? ?? NSNull(),
                "batteryFresh":runtime.device.batteryIsFresh(at:Date()),
                "lightingFollowRequested":runtime.lighting.requestedEnabled,"lightingActive":runtime.lighting.enabled,
                "lightingStatus":runtime.lighting.status.rawValue,"lightingState":runtime.lighting.state.rawValue,
                "agentState":runtime.agentSignals.physicalSnapshot.state?.rawValue as Any? ?? NSNull(),
                "agentLastEventAt":runtime.agentSignals.physicalSnapshot.lastEventAt.map { ISO8601DateFormatter().string(from:$0) } as Any? ?? NSNull(),
                "activationPolicy":NSApp.activationPolicy().rawValue,
                "loginLaunch":runtime.launch.launchedAtLogin,"backgroundLaunch":runtime.launch.background,
                "launchAtLoginEnabled":runtime.settings.loginItem.enabled,
                "ordinaryWindowCount":NSApp.windows.filter {$0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)}.count,
                "shortcutRecording":ShortcutRecordingButton.isAnyRecording,"radialActivation":runtime.radialStore.configuration.activation.rawValue,"baseScrollLines":AU05ActionDefaults.scrollLines]
            try JSONSerialization.data(withJSONObject:status,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        } catch {}
    }
    private func backupLighting(_ value:SmartLightingSnapshot) throws {
        guard let runtime,!runtime.probe else {throw ControlError.unavailable}
        let folder=runtime.directory.appendingPathComponent("LightingBackups",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard (try folder.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else {throw ControlError.unavailable}
        let path=folder.appendingPathComponent(UUID().uuidString+".json")
        let object:[String:Any]=["schemaVersion":1,"at":ISO8601DateFormatter().string(from:Date()),"version":runtime.settings.version,
            "device":"AU05","mode":value.mode.rawValue,"brightness":value.brightness,"rawPayload":value.rawPayload]
        let data=try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:path,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        guard try Data(contentsOf:path) == data else {throw ControlError.unavailable}
        lightingBackup=path
    }
    private func recordLightingConfirmation(_ confirmation:SmartLightingController.Confirmation) {
        guard let runtime,!runtime.probe else {return}
        let folder=runtime.directory.appendingPathComponent("Diagnostics",isDirectory:true)
        let path=folder.appendingPathComponent("agent-lighting-confirmations.json")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            guard (try? folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,
                  (try? path.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {return}
            var entries:[[String:Any]]=[]
            if FileManager.default.fileExists(atPath:path.path) {
                let info=try FileManager.default.attributesOfItem(atPath:path.path)
                guard ((info[.size] as? NSNumber)?.intValue ?? Int.max) <= 128*1024 else {return}
                let data=try Data(contentsOf:path)
                guard let old=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      old["schemaVersion"] as? Int == 1,let rows=old["observations"] as? [[String:Any]] else {return}
                entries=Array(rows.suffix(63))
            }
            entries.append(["at":ISO8601DateFormatter().string(from:confirmation.at),"state":confirmation.state?.rawValue as Any? ?? NSNull(),
                "mode":confirmation.mode.rawValue,"brightness":confirmation.brightness,"restored":confirmation.restored,
                "rawPayload":confirmation.rawPayload,"backupFile":lightingBackup?.lastPathComponent as Any? ?? NSNull(),
                "wroteSettings":confirmation.wroteSettings,"agentState":runtime.agentSignals.physicalSnapshot.state?.rawValue as Any? ?? NSNull(),
                "agentEventHash":runtime.agentSignals.physicalSnapshot.selectedEventID as Any? ?? NSNull()])
            let value:[String:Any]=["schemaVersion":1,"version":runtime.settings.version,"observations":entries]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        } catch {runtime.device.log("灯光参数已读回，诊断记录未能保存。")}
    }
    func showMain() {
        runtime?.launch.revealMainWindow()
        NSApp.setActivationPolicy(.regular)
        if let window=NSApp.windows.first(where:{$0.identifier?.rawValue == "vibekey.main"}) {window.deminiaturize(nil);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
        else {reopenMain?()}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        if AppLaunchState.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent) {
            runtime?.launch.readLoginEvent(); runtime?.launch.hideInitialWindows(); return false
        }
        showMain();return false
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard let runtime else {return .terminateNow}
        if runtime.probe {return .terminateNow}
        if exitPrepared {writeStatus();return .terminateNow}
        guard !preparingExit else {return .terminateCancel}
        guard !runtime.onboard.recoveryRequired else {runtime.device.error="设备配置尚未恢复，请先处理设备备份。";showMain();return .terminateCancel}
        NSApp.windows.filter{$0.identifier?.rawValue == "vibekey.main"}.forEach{_ = $0.makeFirstResponder(nil)}
        preparingExit=true;runtime.settings.suspended=true;resetInputs();writeStatus()
        runtime.lighting.setDevicePriority(true)
        Task { if await finishPreparingExit(runtime) { NSApp.terminate(nil) } }
        return .terminateCancel
    }
    private func prepareForUpdate() async -> Bool {
        guard let runtime, !preparingExit, !runtime.onboard.recoveryRequired else { return false }
        NSApp.windows.filter { $0.identifier?.rawValue == "vibekey.main" }.forEach { _ = $0.makeFirstResponder(nil) }
        preparingExit = true; runtime.settings.suspended = true; resetInputs(); writeStatus()
        runtime.lighting.setDevicePriority(true)
        return await finishPreparingExit(runtime)
    }
    private func finishPreparingExit(_ runtime: VibekeyRuntime) async -> Bool {
        guard await runtime.onboard.flush() else { cancelExit("设备快捷键尚未自动保存，请处理后再退出。"); return false }
        guard await runtime.device.flushAutomaticChanges() else { cancelExit("设备配置尚未处理完，请稍后重试退出。"); return false }
        guard runtime.workflows.flushAutomaticSave(), runtime.radialStore.flushAutomaticSave() else { cancelExit("快捷键或轮盘设置尚未自动保存，请处理后再退出。"); return false }
        await runtime.workflows.shutdown(); await runtime.radial.prepareForExit()
        runtime.lighting.setDevicePriority(false)
        let restored = await runtime.lighting.stopAndRestore(preserveEnabledIntent: true)
        guard restored != .deferred && restored != .unconfirmed else {
            cancelExit("退出前原灯光尚未恢复，请在 Agent 状态灯中重试。"); return false
        }
        do {
            try await runtime.device.restoreForExit(); exitPrepared = true; return true
        } catch { cancelExit("设备恢复未确认：" + error.localizedDescription); return false }
    }

    private func cancelExit(_ message:String) {
        runtime?.device.error=message;preparingExit=false;runtime?.settings.suspended=false;runtime?.lighting.setDevicePriority(false);writeStatus();showMain()
    }
    func applicationWillTerminate(_ notification:Notification) {interaction.stop();statusTimer?.invalidate();if let notificationPermissionObserver {NotificationCenter.default.removeObserver(notificationPermissionObserver)};if let closingObserver {NotificationCenter.default.removeObserver(closingObserver)};runtime?.radial.shutdown();runtime?.agentSignals.stop()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
}
