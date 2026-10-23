import AppKit
import SwiftUI
import VibekeyCore

enum VibekeyDestination: String, CaseIterable, Identifiable {
    case statistics, devices, setup
    var id: String { rawValue }
}

struct VibekeyWorkspace: View {
    @ObservedObject var device: DeviceStore
    @ObservedObject var workflows: WorkflowStore
    @ObservedObject var settings: HardwareSettings
    @ObservedObject var radialStore: RadialMenuStore
    @ObservedObject var radial: RadialMenuController
    @ObservedObject var lighting: SmartLightingController
    @ObservedObject var agentSignals: AgentSignalStore
    var onboard: AU05OnboardStore?
    var batteryNotifications: BatteryNotificationController?
    var updateAvailable = false
    var usage: UsageStatisticsStore?
    @State private var destination: VibekeyDestination
    @State private var au05Section: AU05ConfigurationSection

    init(device: DeviceStore, workflows: WorkflowStore, settings: HardwareSettings,
         radialStore: RadialMenuStore, radial: RadialMenuController, lighting: SmartLightingController, agentSignals: AgentSignalStore,
         onboard: AU05OnboardStore? = nil, initialDestination: VibekeyDestination = .statistics,
         initialAU05Section: AU05ConfigurationSection = .keys,
         batteryNotifications: BatteryNotificationController? = nil, updateAvailable: Bool = false,
         usage: UsageStatisticsStore? = nil) {
        self.device = device; self.workflows = workflows; self.settings = settings
        self.radialStore = radialStore; self.radial = radial; self.lighting = lighting; self.agentSignals = agentSignals
        self.onboard = onboard
        self.batteryNotifications = batteryNotifications
        self.updateAvailable = updateAvailable
        self.usage = usage
        _destination = State(initialValue: usage == nil && initialDestination == .statistics ? .devices : initialDestination)
        _au05Section = State(initialValue: initialAU05Section)
    }
    var body: some View {
        VStack(spacing: 0) {
        if let batteryNotifications {BatteryAlertBanner(device:device,notifications:batteryNotifications)}
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(VIFLOWTheme.border).frame(width: 1)
            ZStack {
                deviceContent
                    .opacity(destination == .devices ? 1 : 0)
                    .allowsHitTesting(destination == .devices).accessibilityHidden(destination != .devices)
                if destination == .setup { SetupGuideView(device: device, settings: settings).background(VIFLOWTheme.canvas) }
                if destination == .statistics, let usage { UsageStatisticsView(store: usage).background(VIFLOWTheme.canvas) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(VIFLOWTheme.canvas)
        }
        }.font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink).tint(VIFLOWTheme.accent)
            .buttonStyle(VIFLOWSecondaryButtonStyle()).frame(minWidth: 980, minHeight: 700)
            .onChange(of: destination) {
                if $0 != .devices, radial.previewMode { radial.cancel() }
                _ = NSApp.windows.first(where: { $0.identifier?.rawValue == "vibekey.main" })?.makeFirstResponder(nil)
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { BrandMark().frame(width: 28, height: 28); Text("VIBEKEY").font(VIFLOWTheme.font(22, weight: .bold)).tracking(0.6).foregroundColor(VIFLOWTheme.accent) }
                .padding(.horizontal, 20).padding(.top, 23).padding(.bottom, 22)
            HStack(spacing: 10) {
                DeviceProductArtwork(product: .au05, compact: true).frame(width: 30, height: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text("VIBEKEY / AU05").font(VIFLOWTheme.font(14, weight: .semibold))
                    Text(device.connectionLabel).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                }
            }.padding(.horizontal, 20).padding(.bottom, 18)
            BatteryDeviceSummary(device: device).padding(.horizontal, 12).padding(.bottom, 14)
            Rectangle().fill(VIFLOWTheme.border).frame(height: 1).padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if usage != nil {
                        navigationRow("使用统计", symbol: "chart.bar.xaxis", selected: destination == .statistics,
                                      identifier: "vibekey.navigation.statistics") { destination = .statistics }
                            .padding(.top, 12)
                    }
                    Text("设备功能").font(VIFLOWTheme.font(12, weight: .medium)).foregroundColor(VIFLOWTheme.secondary)
                        .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 7)
                    ForEach(AU05ConfigurationSection.allCases) { section in
                        navigationRow(section.title, symbol: section.symbol, selected: destination == .devices && au05Section == section,
                                      identifier: "vibekey.navigation.au05." + section.rawValue, detail: section.runsOnMac ? "Mac" : nil) { destination = .devices; au05Section = section }
                    }
                }.padding(.horizontal, 12)
            }
            Rectangle().fill(VIFLOWTheme.border).frame(height: 1).padding(.horizontal, 16)
            VStack(spacing: 4) {
                navigationRow("开始使用", symbol: "checklist", selected: destination == .setup, identifier: "vibekey.navigation.setup") { destination = .setup }
                OpenSettingsButton(hasUpdate: updateAvailable)
            }.padding(.horizontal, 12).padding(.vertical, 12)
        }.frame(width: VIFLOWTheme.sidebarWidth).background(VIFLOWTheme.surface)
    }
    private func navigationRow(_ title: String, symbol: String, selected: Bool, identifier: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).frame(width: 18); Text(title); Spacer(minLength: 0)
                if let detail { Text(detail).font(VIFLOWTheme.caption).foregroundColor(selected ? VIFLOWTheme.filledInk : VIFLOWTheme.secondary) }
            }
        }.buttonStyle(VIFLOWNavigationButtonStyle(selected: selected))
            .accessibilityIdentifier(identifier).accessibilityValue(selected ? "已选中" : "未选中")
    }
    private var deviceContent: some View {
        DeviceView(device: device, workflows: workflows, radialStore: radialStore, radial: radial, lighting: lighting, agentSignals: agentSignals,
                   onboard: onboard, batteryNotifications: batteryNotifications, section: $au05Section)
    }
}

struct BrandMark: View {
    var body: some View { Image(nsImage: VibekeyBrand.symbol).resizable().renderingMode(.template).scaledToFit().foregroundColor(VIFLOWTheme.accent).accessibilityLabel("VIBEKEY") }
}

struct DeviceEventsView:View {
    @ObservedObject var device:DeviceStore
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Text("事件与连接").font(VIFLOWTheme.title);Spacer();Button("刷新") {device.refresh()}}
            Text(device.connectionDetail).foregroundColor(VIFLOWTheme.secondary)
            Text(device.lastEvent).font(VIFLOWTheme.subheading)
            ScrollView {
                VStack(alignment:.leading,spacing:9) {
                    ForEach(Array(device.events.enumerated()),id:\.offset) {_,line in Text(line).font(.system(size:12,design:.monospaced)).textSelection(.enabled)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            }.viflowPanel(padding:0)
        }.padding(28)
    }
}
