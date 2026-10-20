import SwiftUI
import VibekeyCore

@MainActor struct SmartLightingSettingsView: View {
    @ObservedObject var controller: SmartLightingController
    @State private var previewState: SmartLightingState = .awaitingApproval
    @State private var previewBrightness: Double = 8
    @State private var stopping = false
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("Agent 状态灯").font(VIFLOWTheme.subheading)
                Spacer()
                Toggle("跟随 Agent 状态", isOn: Binding(get: { controller.requestedEnabled }, set: { controller.setEnabled($0) }))
                    .toggleStyle(.switch).disabled(stopping || (!controller.deviceReady && !controller.requestedEnabled))
                    .accessibilityIdentifier("lighting.enabled")
                if controller.hasBorrowedSettings && !controller.enabled { Button("重试恢复原灯光") {
                    stopping = true
                    Task { _ = await controller.stopAndRestore(); stopping = false }
                }
                .disabled(stopping || (!controller.enabled && !controller.hasBorrowedSettings))
                .accessibilityIdentifier("lighting.restore") }
            }
            Text(controller.statusText).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("lighting.readback")
            Text("需要审批时优先提醒；关闭后恢复原灯光。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            if let confirmation = controller.lastConfirmation, controller.deviceReady {
                HStack(spacing: 8) {
                    Text("设备参数读回：" + confirmation.mode.title + " · \(confirmation.brightness * 5)%")
                    Text(confirmation.at, style: .time)
                }.font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .accessibilityIdentifier("lighting.hardwareConfirmation")
            }
            Text("运行保持常亮；审批时提高亮度；本轮结束后短暂低亮并恢复。只控制按键与旋钮指示灯，底部充电灯由设备管理。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 12) {
                Text("运行亮度").font(VIFLOWTheme.caption)
                Slider(value: $previewBrightness, in: 0...12, step: 1).frame(maxWidth: 230)
                    .accessibilityIdentifier("lighting.brightnessPreview")
                Text("\(Int(previewBrightness) * 5)%").font(VIFLOWTheme.caption).monospacedDigit().frame(width: 52)
                Button("使用此亮度") { controller.setBrightness(Int(previewBrightness)) }
                    .disabled(stopping || Int(previewBrightness) == controller.brightness)
                    .accessibilityIdentifier("lighting.applyBrightness")
                Spacer(minLength: 0)
            }
            DisclosureGroup("灯光规则与软件示意", isExpanded: $details) {
            VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: previewSymbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(VIFLOWTheme.accent.opacity(previewState == .standby ? 0.4 : 0.45 + previewBrightness / 40))
                    .frame(width: 68, height: 68).background(VIFLOWTheme.muted, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Picker("软件示意", selection: $previewState) {
                        ForEach(SmartLightingState.agentStates, id: \.self) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 310).accessibilityIdentifier("lighting.previewState")
                    Text(SmartLightingPolicy.description(for: previewState)).font(VIFLOWTheme.body)
                    Text("仅软件示意，不写设备，也不代表真实灯色或分区。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                }
                Spacer(minLength: 0)
            }
                VStack(alignment: .leading, spacing: 6) {
                    Text("仅使用已确认的模式与亮度字段，保留工作参数。独立灯位、RGB、呼吸和频率不在本次控制范围内。")
                    Text("开关和亮度记在本机。重连后重新读取原灯光，只跟随当前新鲜状态；设备配置期间暂缓，手动修改后暂停。")
                    Text("审批提示持续到真实状态清除或过期。完成只依据接入事件；一轮回复结束不等于整个任务完成。软件示意图标不会变成设备灯色或图形。")
                    Text("停用会尝试恢复同一连接的原灯光；断开或设置已改变时不会把旧值写回新设备。")
                }.font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).padding(.top, 7)
            }
            }.font(VIFLOWTheme.caption)
        }
        .foregroundColor(VIFLOWTheme.ink).buttonStyle(VIFLOWSecondaryButtonStyle()).viflowPanel(padding: 16)
        .accessibilityIdentifier("lighting.settings")
        .onAppear { previewBrightness = Double(min(12, controller.brightness)) }
    }
    private var previewSymbol: String {
        switch previewState {
        case .awaitingApproval: return "hand.raised.fill"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .running: return "gearshape"
        case .standby: return "lightbulb"
        }
    }
}
