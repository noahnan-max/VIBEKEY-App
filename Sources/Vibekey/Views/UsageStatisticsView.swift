import SwiftUI
import VibekeyCore

struct UsageStatisticsView: View {
    @ObservedObject var store: UsageStatisticsStore
    @State private var weeksBack = 0
    @State private var selectedDate: Date?
    @State private var settingsExpanded = false
    private var totals: UsageStatisticsDay { store.displayLedger.totals }
    private var hasData: Bool { totals.sessions > 0 }
    private var hasCharacterData: Bool { totals.hasCharacterCoverage }
    private let calendar = Calendar.current
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if store.preferences.observationConsentVersion != 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("开启这台 Mac 的使用统计").font(VIFLOWTheme.subheading)
                        Text("开启后，在你使用 AU05 语音输入时，本机只读观察原输入框中出现的文字，仅保存字数、时长和来源汇总。不录音、不保存原文、不上传统计；无法读取时会单独标注时长估算。你可以随时关闭，历史汇总会保留。")
                            .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("开启本机统计") { store.setCollectionEnabled(true) }
                            .buttonStyle(VIFLOWPrimaryButtonStyle()).disabled(!store.canChangePreferences)
                            .accessibilityIdentifier("vibekey.usage.enable-consent")
                    }.viflowPanel(padding: 16).accessibilityIdentifier("vibekey.usage.consent")
                }
                if let live = store.liveSummary {
                    Text(live).font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(VIFLOWTheme.muted, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("vibekey.usage.live")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metric("累计收录量 · 含估算", value: hasCharacterData ? totals.totalCharacters.formatted() : "—", unit: hasCharacterData ? "字" : "",
                           detail: "观察 \(totals.observedCharacters.formatted()) · 时长估算 \(totals.estimatedCharacters.formatted())")
                    metric("估算节省时间", value: hasCharacterData ? duration(savedSeconds) : "—", unit: "",
                           detail: "按 \(store.preferences.typingCharactersPerMinute) 字/分减去已计字数的操作时长")
                    metric("麦克风使用时长", value: hasData ? duration(totals.operationSeconds) : "—", unit: "", detail: "自动识别麦克风启停，包含停顿；旧记录保留原口径")
                    metric("语音操作次数", value: hasData ? totals.sessions.formatted() : "—", unit: hasData ? "次" : "",
                           detail: "其中 \(totals.unavailableSessions) 次未取得字数")
                }
                activity
                HStack(spacing: 8) {
                    Circle().fill(store.isObserving ? VIFLOWTheme.accent : VIFLOWTheme.secondary).frame(width: 6, height: 6)
                    Text(store.status).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    Spacer()
                    Toggle("自动统计", isOn: Binding(get: { store.collectionEnabled }, set: { store.setCollectionEnabled($0) }))
                        .toggleStyle(.switch).controlSize(.small).disabled(!store.canChangePreferences)
                        .accessibilityIdentifier("vibekey.usage.enabled")
                }
                DisclosureGroup("统计设置与口径", isExpanded: $settingsExpanded) { configuration.padding(.top, 12) }
                    .viflowPanel(padding: 16)
                Text("主动开启后，自动统计 VIBEKEY 麦克风的输入，无需设置按键或操作方式。已收录文字实时累计，后续删改不扣回；本段进度计入当前显示，结束后只入账一次。原文仅在内存短暂使用，不录音、不改写输入。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = store.error { Text(error).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.errorInk) }
            }.padding(24).frame(maxWidth: 1000, alignment: .leading)
        }.accessibilityIdentifier("vibekey.usage.page")
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("使用统计").font(VIFLOWTheme.title)
            Text("看见每一天的输入积累").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
        }
    }
    private func metric(_ title: String, value: String, unit: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(VIFLOWTheme.font(27, weight: .semibold)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(VIFLOWTheme.caption) }
            }
            Text(title).font(VIFLOWTheme.body)
            Text(detail).font(VIFLOWTheme.font(10.5)).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 88, alignment: .leading).padding(17)
            .background(VIFLOWTheme.muted, in: RoundedRectangle(cornerRadius: 14))
    }
    private var activity: some View {
        let streak = store.displayLedger.streaks()
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                dayMetric("活跃天数", value: streak.active)
                dayMetric("当前连续天数", value: streak.current)
                dayMetric("最长连续天数", value: streak.longest)
            }
            HStack {
                Text("每日输入量").font(VIFLOWTheme.subheading)
                Spacer()
                Text(rangeLabel).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                Button { weeksBack += 4; selectedDate = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).disabled(weeksBack >= 104).help("更早四周").accessibilityLabel("更早四周")
                Button { weeksBack = max(0, weeksBack - 4); selectedDate = nil } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(weeksBack == 0).help("较近四周").accessibilityLabel("较近四周")
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 7) {
                        VStack(spacing: 5) {
                            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { Text($0).font(VIFLOWTheme.font(9)).frame(width: 12, height: 14).foregroundColor(VIFLOWTheme.secondary) }
                        }
                        HStack(alignment: .top, spacing: 5) {
                            ForEach(0..<28, id: \.self) { week in
                                VStack(spacing: 5) {
                                    ForEach(0..<7, id: \.self) { day in cell(dateFor(week * 7 + day)) }
                                    Text(monthLabel(week)).font(VIFLOWTheme.font(9)).foregroundColor(VIFLOWTheme.secondary)
                                        .fixedSize().frame(width: 14, height: 14, alignment: .leading)
                                }
                            }
                            Color.clear.frame(width: 1, height: 1).id("usage.latest")
                        }
                    }.padding(.vertical, 3)
                }.onAppear { proxy.scrollTo("usage.latest", anchor: .trailing) }
            }
            HStack(spacing: 5) {
                Text("较少").font(VIFLOWTheme.font(10))
                ForEach(0..<5, id: \.self) { n in RoundedRectangle(cornerRadius: 3).fill(intensity(n)).frame(width: 12, height: 12) }
                Text("较多").font(VIFLOWTheme.font(10))
                Spacer()
                Text("斜线 = 未记录").font(VIFLOWTheme.font(10))
            }.foregroundColor(VIFLOWTheme.secondary)
            Divider()
            Text(selectedDate.map(dayDescription) ?? "点选格子查看当天的观察量与估算量；空心格代表未来日期。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("vibekey.usage.day-detail")
        }.padding(20).background(VIFLOWTheme.muted, in: RoundedRectangle(cornerRadius: 14))
    }
    private func dayMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hasCharacterData ? value.formatted() : "—").font(VIFLOWTheme.font(24, weight: .semibold)).monospacedDigit()
                if hasCharacterData { Text("天").font(VIFLOWTheme.caption) }
            }
            Text(title).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func cell(_ date: Date) -> some View {
        let day = store.displayLedger.days[UsageStatisticsLedger.dayKey(date)]
        let future = calendar.startOfDay(for: date) > calendar.startOfDay(for: Date())
        return Button { selectedDate = date } label: {
            ZStack {
                if future { RoundedRectangle(cornerRadius: 3).stroke(VIFLOWTheme.controlBorder, lineWidth: 0.6) }
                else if let day, day.hasCharacterCoverage { RoundedRectangle(cornerRadius: 3).fill(intensity(level(day.totalCharacters))) }
                else {
                    RoundedRectangle(cornerRadius: 3).fill(VIFLOWTheme.surface)
                    UsageHatch().stroke(VIFLOWTheme.controlBorder, lineWidth: 0.65).clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }.frame(width: 14, height: 14)
        }.buttonStyle(.plain).help(dayDescription(date)).accessibilityLabel(dayDescription(date))
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自动跟随 AU05 / VIBEKEY 麦克风的实际启停。任何按键、按住或单击用法均无需设置；麦克风未使用时，普通按键不产生统计。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
            Toggle("读不到文字时，允许按麦克风使用时长估算", isOn: preference(\.estimateWhenUnavailable))
            HStack {
                Stepper("估算口述速度：\(store.preferences.spokenCharactersPerMinute) 字/分", value: preference(\.spokenCharactersPerMinute), in: 60...500, step: 10)
                Spacer(minLength: 24)
                Stepper("打字基准：\(store.preferences.typingCharactersPerMinute) 字/分", value: preference(\.typingCharactersPerMinute), in: 10...500, step: 10)
            }
            Text("按文字出现时的累计收录量计数，空白不计；不等待最终润色，后续删减不扣回，相同草稿不整段重复累加。语音浮窗造成的焦点变化会重试原输入框；仍读不到时按实际麦克风时长估算并标注。密码框不估字数，估算仍包含停顿与会议时间。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func preference<T>(_ keyPath: WritableKeyPath<UsageStatisticsPreferences, T>) -> Binding<T> {
        Binding(get: { store.preferences[keyPath: keyPath] }, set: { value in store.update { $0[keyPath: keyPath] = value } })
    }
    private var savedSeconds: Double { Double(totals.totalCharacters) / Double(store.preferences.typingCharactersPerMinute) * 60 - totals.countedOperationSeconds }
    private func duration(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "−" : "", n = abs(seconds)
        return sign + (n >= 3600 ? String(format: "%.1f 小时", n / 3600) : String(format: "%.1f 分钟", n / 60))
    }
    private func intensity(_ n: Int) -> Color { n == 0 ? VIFLOWTheme.border : VIFLOWTheme.accent.opacity([0, 0.25, 0.45, 0.7, 1][n]) }
    private func level(_ n: Int) -> Int { n == 0 ? 0 : n <= 500 ? 1 : n <= 2000 ? 2 : n <= 4000 ? 3 : 4 }
    private var end: Date { calendar.date(byAdding: .day, value: 7 - calendar.component(.weekday, from: Date()) - weeksBack * 7, to: calendar.startOfDay(for: Date()))! }
    private func dateFor(_ index: Int) -> Date { calendar.date(byAdding: .day, value: index - 195, to: end)! }
    private var rangeLabel: String { let f = DateFormatter(); f.dateFormat = "yyyy/M/d"; return f.string(from: dateFor(0)) + " — " + f.string(from: end) }
    private func monthLabel(_ week: Int) -> String {
        (0..<7).compactMap { day -> String? in let date = dateFor(week * 7 + day); return calendar.component(.day, from: date) == 1 ? "\(calendar.component(.month, from: date))月" : nil }.first ?? ""
    }
    private func dayDescription(_ date: Date) -> String {
        let key = UsageStatisticsLedger.dayKey(date)
        if date > end || calendar.startOfDay(for: date) > calendar.startOfDay(for: Date()) { return key + " · 未来日期" }
        guard let day = store.displayLedger.days[key] else { return key + " · 未记录，非零次使用" }
        if !day.hasCharacterCoverage { return "\(key) · 记录 \(day.sessions) 次操作，字数未取得" }
        return "\(key) · 观察 \(day.observedCharacters) 字 · 估算 \(day.estimatedCharacters) 字 · \(day.sessions) 次操作"
    }
}

private struct UsageHatch: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in for x in stride(from: -rect.height, through: rect.width, by: 5) { p.move(to: CGPoint(x: x, y: rect.height)); p.addLine(to: CGPoint(x: x + rect.height, y: 0)) } }
    }
}
