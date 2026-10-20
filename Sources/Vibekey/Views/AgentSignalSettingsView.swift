import SwiftUI
import VibekeyCore

struct AgentSignalSettingsView: View {
    @ObservedObject var store: AgentSignalStore
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("状态来源").font(VIFLOWTheme.subheading)
                Spacer()
                Button("刷新") {store.refresh()}.accessibilityIdentifier("agentSignals.refresh")
            }
            ForEach(AgentSignalSource.allCases) {source in
                HStack {
                    Text(source.title)
                    Spacer()
                    Text(status(source)).foregroundColor(VIFLOWTheme.secondary)
                    if let date = store.lastEvents[source].map({Date(timeIntervalSince1970:$0.occurredAt)}) {
                        Text(date,style:.time).foregroundColor(VIFLOWTheme.secondary)
                    }
                }.font(VIFLOWTheme.body).accessibilityIdentifier("agentSignals.source."+source.rawValue)
            }
            Text(store.desktopStatusText).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("agentSignals.desktopStatus")
            if let simulation = store.simulationTitle {Text(simulation+"（非真实事件）").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.accent)}
            if let error = store.errorMessage {Text(error).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk)}
            DisclosureGroup("接入与自测") {
                VStack(alignment:.leading,spacing:6) {
                    Menu("模拟状态（仅软件预览）") {
                        Button("模拟需要审批") {store.simulate(state:.approvalRequired)}
                        Button("模拟收尾待确认") {store.simulate(state:.stopProposed)}
                        Button("模拟本轮结束") {store.simulate(state:.turnCompleted)}
                        Button("模拟失败") {store.simulate(state:.failed,source:.claude)}
                    }.disabled(store.errorMessage != nil).accessibilityIdentifier("agentSignals.simulate")
                    Text("本轮结束不等于任务完成。过期或无法确认时显示未知。")
                    Text("真实回调用于运行和审批；受支持版本的 Codex 桌面记录只补充状态保鲜与本轮结束。对话正文与工具参数不进入状态记录。")
                    Text("尚未收到真实事件时，自测不会被记为已接入。Codex新hook需在 /hooks 正常审阅与信任。")
                    Text("审批没有独立请求标识时保留待核对；只有同一轮的可靠终态可清除该轮提醒，其他工具或会话完成不会代替审批结果。")
                    Text("Stop 回调只代表开始收尾，仍可能继续工作；它不会触发完成灯。")
                    Text("TaskCompleted 是完成请求，当前不作为已完成灯光。配置安装不等于已接通；运行状态以真实事件为准。")
                }.font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).padding(.top,8)
            }
        }.viflowPanel(padding:16).accessibilityIdentifier("agentSignals.settings")
    }
    private func status(_ source:AgentSignalSource)->String {
        if store.errorMessage != nil {return "未知"}
        if let value = store.sourceSnapshots[source] {
            if value.unresolvedApprovalCount > 0,value.state == .attentionRequired {return "审批待核对"}
            if let state = value.state {return state.title}
            if value.staleSessionCount > 0 {return "已过期 · 未知"}
        }
        if store.lastEvents[source]?.state == .ended {return "会话结束"}
        if store.observedSources.contains(source) {return "暂无新鲜状态"}
        if store.configuredSources.contains(source) {return "已写入配置 · 等待真实事件"}
        return "待真实事件 · 未接入"
    }
}
