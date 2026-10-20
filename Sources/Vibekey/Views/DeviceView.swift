import SwiftUI
import VibekeyCore

enum AU05ConfigurationSection: String, CaseIterable, Identifiable {
    case keys, radial, agent, parameters
    var id: String { rawValue }
    var runsOnMac: Bool { self == .radial || self == .agent }
    var title: String {
        switch self {
        case .keys: return "按键与旋钮"
        case .radial: return "快捷轮盘"
        case .agent: return "Agent 状态灯"
        case .parameters: return "设备设置"
        }
    }
    var symbol: String {
        switch self {
        case .keys: return "keyboard"
        case .radial: return "circle.grid.2x2"
        case .agent: return "lightbulb"
        case .parameters: return "slider.horizontal.3"
        }
    }
}

enum AU05KeyEditor: String, CaseIterable, Identifiable {
    case shortcut, workflow
    var id: String { rawValue }
    var title: String { self == .shortcut ? "快捷键" : "宏与工作流" }
}

struct DeviceView: View {
    @ObservedObject var device: DeviceStore
    @ObservedObject var workflows: WorkflowStore
    @ObservedObject var radialStore: RadialMenuStore
    @ObservedObject var radial: RadialMenuController
    private var radialEnabled: Bool { radialStore.configuration.enabled }
    var lighting:SmartLightingController?
    var agentSignals:AgentSignalStore?
    var onboard: AU05OnboardStore?
    var batteryNotifications: BatteryNotificationController?
    @Binding private var section: AU05ConfigurationSection
    private let onTransientDraftChange: (Bool) -> Void
    @State private var selectedTriggerID = "key.0"
    @State private var keyEditor: AU05KeyEditor
    @State private var brightnessDraft: Double?
    @State private var brightnessDirty = false
    @State private var brightnessEditing = false
    @State private var brightnessSaveTask: Task<Void, Never>?
    init(device: DeviceStore, workflows: WorkflowStore, radialStore:RadialMenuStore, radial:RadialMenuController, lighting:SmartLightingController? = nil, agentSignals:AgentSignalStore? = nil, onboard:AU05OnboardStore? = nil, batteryNotifications:BatteryNotificationController? = nil, initialSection:AU05ConfigurationSection = .keys, initialKeyEditor:AU05KeyEditor = .shortcut, section:Binding<AU05ConfigurationSection>? = nil, onTransientDraftChange:@escaping (Bool)->Void = {_ in}) {
        self.device = device; self.workflows = workflows
        self.radialStore = radialStore; self.radial = radial
        self.lighting=lighting;self.agentSignals=agentSignals
        self.onboard = onboard
        self.batteryNotifications = batteryNotifications
        _section=section ?? .constant(initialSection)
        _keyEditor = State(initialValue: initialKeyEditor)
        self.onTransientDraftChange=onTransientDraftChange
        let existing = workflows.bindings.first { $0.id == workflows.selectedID }?.triggerID
        let initial = existing.flatMap { id in HardwareTrigger.available.contains(where: { $0.id == id }) ? id : nil } ?? "key.0"
        _selectedTriggerID = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if section.runsOnMac {
                Text("此功能由 Mac 执行。关窗后在菜单栏继续运行，从菜单退出 VIBEKEY 后暂停。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vibekey.device.mac-feature")
            }
            Group {
                switch section {
                case .keys: keyWorkspace
                case .radial:
                    GeometryReader { geometry in
                        ScrollView {
                            RadialMenuSettingsView(store:radialStore,controller:radial)
                                .frame(height:max(520,geometry.size.height)).padding(.trailing,4)
                        }
                    }
                case .agent:
                    ScrollView {
                        VStack(alignment:.leading,spacing:18) {
                            if let lighting {SmartLightingSettingsView(controller:lighting)}
                            else {Text("状态灯未载入。").foregroundColor(VIFLOWTheme.secondary)}
                            if let agentSignals {AgentSignalSettingsView(store:agentSignals)}
                        }.padding(.trailing,4)
                    }
                case .parameters:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            BatteryStatusView(device:device)
                            if let batteryNotifications {BatteryNotificationSettingsView(controller:batteryNotifications)}
                            settings.viflowPanel(padding: 20)
                            deviceInformation
                            DisclosureGroup("连接诊断") {
                                DeviceEventsView(device:device).frame(height:360)
                            }.viflowPanel(padding:16)
                        }.padding(.trailing, 4)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = device.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vibekey.device.error")
            }
        }
        .padding(24)
        .font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.ink)
        .onAppear {
            synchronizeBrightness(device.snapshot.lightBrightness, reset: true)
            synchronizeSelection()
        }
        .onChange(of: selectedBindingTriggerID) { _ in synchronizeSelection() }
        .onChange(of: device.snapshot.lightBrightness) { synchronizeBrightness($0) }
        .onChange(of: brightnessDirty) { onTransientDraftChange($0) }
        .onChange(of: brightnessDraft) { _ in
            brightnessSaveTask?.cancel()
            guard brightnessDirty, !brightnessEditing else { return }
            brightnessSaveTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                applyBrightness()
            }
        }
        .onDisappear { brightnessSaveTask?.cancel(); applyBrightness(); onTransientDraftChange(false) }
        .onChange(of: device.connected) { connected in
            if connected { synchronizeBrightness(device.snapshot.lightBrightness, reset: true) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title).font(VIFLOWTheme.title)
                Text(sectionHint).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(device.isReady ? VIFLOWTheme.accent : VIFLOWTheme.secondary).frame(width: 6, height: 6)
                    Text(device.connectionLabel).font(VIFLOWTheme.caption)
                }
                Button { device.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(!device.connected || device.editing)
                    .accessibilityIdentifier("vibekey.device.refresh")
            }
        }
    }

    private var keyWorkspace: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 12) {
                AU05HardwarePreview(selectedTriggerID: selectedTriggerID, onSelect: selectTrigger)
                Text("点击要设置的位置")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }.frame(width: 184)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(selectedTriggerTitle).font(VIFLOWTheme.title)
                        .accessibilityIdentifier("vibekey.device.selected-trigger")
                    if let onboard {
                        Picker("配置内容", selection: $keyEditor) {
                            ForEach(AU05KeyEditor.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("vibekey.device.key-editor")
                        if keyEditor == .shortcut {
                            AU05OnboardEditorView(store: onboard, triggerID: selectedTriggerID)
                            if hasMacWorkflow {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(workflows.enabled ? "此键还有已启用的 Mac 工作流，会按应用范围优先执行。" : "此键已配置 Mac 工作流，目前未启用。")
                                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Button("查看工作流") { keyEditor = .workflow }
                                        .accessibilityIdentifier("vibekey.device.show-workflow")
                                }
                            }
                        } else {
                            Text("工作流保存在这台 Mac，启用后按应用范围执行。关窗后继续运行；从菜单退出后使用此键的设备快捷键。")
                                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("vibekey.device.workflow-storage")
                            WorkflowEditorView(store: workflows, device: device, triggerID: selectedTriggerID, detailed: true,
                                radialEnabled: radialEnabled, radialTriggerID: radialStore.configuration.activation.triggerID,
                                radialUsesHold: radialStore.configuration.activation.requiresHold)
                        }
                    } else { enhancedKeyEditor }
                }.padding(.trailing, 4)
            }
            .id(selectedTriggerID)
            .accessibilityIdentifier("vibekey.device.key-inspector")
        }
    }
    private var hasMacWorkflow: Bool {
        workflows.activeBindings.contains { $0.triggerID == selectedTriggerID && $0.steps.contains { $0.kind != .passthrough } }
    }
    @ViewBuilder private var enhancedKeyEditor: some View {
        if radialEnabled && selectedTriggerID == radialStore.configuration.activation.triggerID { triggerPreference }
        else { Text(selectedTriggerHint).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary) }
        if !(radialEnabled && selectedTriggerID == radialStore.configuration.activation.triggerID && !radialStore.configuration.activation.requiresHold) {
            WorkflowEditorView(store: workflows, device: device, triggerID: selectedTriggerID, radialEnabled: radialEnabled,
                radialTriggerID: radialStore.configuration.activation.triggerID, radialUsesHold: radialStore.configuration.activation.requiresHold)
        }
    }

    private var deviceInformation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 36) {
                metric("固件版本", value: device.snapshot.firmware ?? "未读取")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(device.lastEvent).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = device.snapshot.lastReadAt {
                    Text((device.isReady ? "最后读回 " : "上次读回 · 非实时 ") + date.formatted(date: .omitted, time: .standard))
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                } else {
                    Text("等待读取设备设置").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).viflowPanel(padding: 20)
    }

    private func selectTrigger(_ id: String) {
        guard HardwareTrigger.available.contains(where: { $0.id == id }) else { return }
        selectedTriggerID = id
        // Browsing must never append a passthrough binding or save configuration.
        if selectedBindingTriggerID != id {
            let matching = workflows.bindings.filter { $0.triggerID == id }
            workflows.selectedID = (matching.first { $0.applicationBundleID.isEmpty } ?? matching.first)?.id
        }
    }
    private var selectedBindingTriggerID: String? { workflows.bindings.first { $0.id == workflows.selectedID }?.triggerID }
    private func synchronizeSelection() {
        if let id = selectedBindingTriggerID, HardwareTrigger.available.contains(where: { $0.id == id }) { selectedTriggerID = id }
    }
    private var selectedTriggerTitle: String {
        switch selectedTriggerID {
        case "key.0": return "上键"
        case "key.1": return "中键"
        case "key.2": return "下键"
        case "knob.press": return "旋钮 · 按下"
        case "knob.left": return "旋钮 · 左转"
        case "knob.right": return "旋钮 · 右转"
        default: return "按键配置"
        }
    }
    private var selectedTriggerHint: String {
        switch selectedTriggerID {
        case "key.1": return "基础动作：Return。"
        case "key.2": return radialEnabled && radialStore.configuration.activation.cancelTriggerID == "key.2" ? "基础动作：退格；轮盘内用于取消。" : "基础动作：退格。"
        case "knob.press": return radialEnabled ? "基础动作：右 Control；轮盘内用于确认。" : "基础动作：右 Control。"
        case "knob.left": return radialEnabled ? "轮盘关闭时执行下方动作，打开时选择上一项。" : "每格的动作由下方设置决定。"
        case "knob.right": return radialEnabled ? "轮盘关闭时执行下方动作，打开时选择下一项。" : "每格的动作由下方设置决定。"
        default: return "基础动作：左 Control，可调用已有输入法。"
        }
    }
    private var sectionHint: String {
        switch section {
        case .keys: return "选择一个按键或旋钮，设置快捷键、宏与工作流。"
        case .radial: return "上、中、下键和旋钮都支持单击或长按触发。"
        case .agent: return "用灯光查看 Agent 的任务与审批状态。"
        case .parameters: return "开关与选项自动应用；亮度结束调整后自动写入。"
        }
    }
    private var triggerPreference: some View {
        let activation = radialStore.configuration.activation
        return VStack(alignment: .leading, spacing: 10) {
            Text("当前轮盘入口：" + activation.title).font(VIFLOWTheme.subheading)
            Text(activation.requiresHold ? "短按执行下方动作，长按打开轮盘。" : "单击打开轮盘；触发按键和方式都可以更改。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            RadialTriggerPicker(store: radialStore, disabled: radial.isPresented || radial.executing)
            HStack {
                Text(radialStore.automaticSaveMessage).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                Button("停用轮盘并设置此按键") { radialStore.draft.enabled = false }
                    .buttonStyle(.borderless).disabled(radial.isPresented || radial.executing || !radialStore.isReady)
                    .accessibilityIdentifier("vibekey.device.release-radial-trigger")
            }
            if let error = radialStore.error { Text(error).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk) }
        }.viflowPanel(padding: 16)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(spacing: 15) {
                setting("触感反馈", detail: "按键与旋钮的震动反馈") {
                    if let value = device.snapshot.motor, [0, 255].contains(value) {
                        Toggle("触感反馈", isOn: Binding(get: { device.snapshot.motor == 255 }, set: device.setHaptics)).labelsHidden().toggleStyle(.switch)
                    } else { Text(device.snapshot.motor.map { "未知值 \($0)" } ?? "未读取").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary) }
                }
                Divider()
                setting("麦克风降噪", detail: "降低麦克风的背景噪声") {
                    readPicker("降噪", value: device.snapshot.noiseReduction,
                               options: [(0, "关闭"), (1, "开启")],
                               supportsWrite: device.snapshot.noiseLow != nil && device.snapshot.noiseHigh != nil,
                               action: device.setNoise)
                        .accessibilityIdentifier("vibekey.device.noise")
                }
                Divider()
                setting("休眠时间", detail: "空闲后进入休眠") {
                    readPicker("休眠时间", value: device.snapshot.sleepSeconds,
                               options: [(0, "关闭休眠"), (3600, "1 小时"), (7200, "2 小时"), (10800, "3 小时"), (14400, "4 小时")],
                               action: device.setSleep)
                        .accessibilityIdentifier("vibekey.device.sleep")
                }
                Divider()
                setting("指示灯模式", detail: "设备指示灯的显示方式") {
                    readPicker("指示灯模式", value: device.snapshot.lightMode,
                               options: [(0, "全灭"), (1, "全亮"), (2, "工作模式")], action: device.setLightMode)
                        .accessibilityIdentifier("vibekey.device.light-mode")
                }
                Divider()
                setting("灯光亮度", detail: "仅在全亮模式下使用") {
                    brightnessControl
                }
            }
            .disabled(!canModify)
            if device.editing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在写入并读回核对…").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                }
            } else if !device.isReady {
                Text("设备暂未就绪，已暂停设置修改。现有值为上次读回。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var brightnessControl: some View {
        if let actual = device.snapshot.lightBrightness, (0...20).contains(actual) {
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { brightnessDraft ?? Double(actual) }, set: { value in
                        brightnessDraft = value.rounded()
                        brightnessDirty = Int(value.rounded()) != actual
                        device.stageBrightness(Int(value.rounded()))
                    }), in: 0...20, onEditingChanged: { editing in
                        brightnessEditing = editing; brightnessSaveTask?.cancel()
                        if !editing { applyBrightness() }
                    })
                    .frame(minWidth: 68)
                    .accessibilityLabel("全亮亮度")
                    .accessibilityIdentifier("vibekey.device.brightness-draft")
                    Text("\(Int((brightnessDraft ?? Double(actual)) * 5))%")
                        .font(VIFLOWTheme.caption).monospacedDigit().frame(width: 45, alignment: .trailing)
                }
                Text(brightnessDirty ? (device.error == nil ? "正在自动应用…" : "自动应用未完成") : "当前亮度 \(actual * 5)%")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                if brightnessDirty, device.error != nil {
                    Button("重试") { applyBrightness() }.controlSize(.small)
                        .accessibilityIdentifier("vibekey.device.brightness-retry")
                }
            }
        } else {
            Text(device.snapshot.lightBrightness.map { "未知值 \($0)" } ?? "未读取")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
        }
    }

    private var canModify: Bool { device.isReady && !device.editing }
    @MainActor private func applyBrightness() {
        guard brightnessDirty, device.isReady, let value = brightnessDraft else { return }
        let target = Int(value)
        guard (0...20).contains(target), target != device.snapshot.lightBrightness else { return }
        device.requestBrightness(target)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            Text(value).font(VIFLOWTheme.font(16, weight: .semibold)).monospacedDigit()
        }
    }

    private func setting<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(VIFLOWTheme.body)
                Text(detail).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().frame(width: 200, alignment: .trailing)
        }
    }

    private func readPicker(_ title: String, value: Int?, options: [(Int, String)], supportsWrite: Bool = true,
                            action: @escaping (Int) -> Void) -> some View {
        let known = value.map { current in options.contains { $0.0 == current } } ?? false
        return Picker(title, selection: Binding(get: { value ?? -1 }, set: { target in
            guard canModify, supportsWrite, known, options.contains(where: { $0.0 == target }), target != value else { return }
            action(target)
        })) {
            if let value, !known { Text("未知值 \(value)").tag(value) }
            if value == nil { Text("未读取").tag(-1) }
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
        .labelsHidden().frame(width: 180).disabled(!known || !supportsWrite)
    }

    private func synchronizeBrightness(_ value: Int?, reset: Bool = false) {
        guard let value, (0...20).contains(value) else { brightnessDraft = nil; brightnessDirty = false; return }
        if reset || !brightnessDirty {
            brightnessDraft = Double(value)
            brightnessDirty = false
        } else if brightnessDraft == Double(value) {
            brightnessDirty = false
        }
    }
}
