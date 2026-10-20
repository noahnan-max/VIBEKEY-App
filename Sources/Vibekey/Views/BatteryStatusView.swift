import SwiftUI
import VibekeyCore

/// Always visible below the selected AU05, without borrowing another device's
/// battery reading. Compact enough for the existing sidebar width.
struct BatteryDeviceSummary: View {
    @ObservedObject var device: DeviceStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let reading = device.snapshot.batteryReading
            let fresh = device.batteryIsFresh(at: context.date)
            let warning = device.batteryWarning(at: context.date)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: symbol(reading, fresh:fresh))
                        .accessibilityHidden(true)
                    Text(reading?.percent.map { "\($0)%" } ?? "电量未读取")
                        .font(VIFLOWTheme.subheading).monospacedDigit()
                    Spacer(minLength: 0)
                    if warning != nil {Image(systemName:"exclamationmark.triangle.fill").accessibilityHidden(true)}
                }
                .foregroundColor(warning == nil ? VIFLOWTheme.ink : VIFLOWTheme.errorInk)
                Text(summary(reading, fresh: fresh, low: warning != nil))
                    .font(VIFLOWTheme.caption).foregroundColor(warning == nil ? VIFLOWTheme.secondary : VIFLOWTheme.errorInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VIFLOWTheme.muted, in: RoundedRectangle(cornerRadius: VIFLOWTheme.controlRadius))
        }
        .accessibilityIdentifier("vibekey.device-selector.battery")
    }
    private func summary(_ reading: BatteryReading?, fresh: Bool, low: Bool) -> String {
        guard let reading else { return "设备就绪后自动读取" }
        guard fresh else { return "上次读数 · 非实时" }
        if reading.isFull == true { return "已充满 · 自动刷新" }
        if reading.isCharging == true { return "充电中 · 自动刷新" }
        if low { return "低电量，请连接充电" }
        if reading.isCharging == false { return "未充电 · 自动刷新" }
        return "充电状态未确认"
    }
    private func symbol(_ reading: BatteryReading?, fresh: Bool) -> String {
        guard let reading, let percent=reading.percent else {return "battery.0"}
        if reading.isCharging == true && fresh {return "battery.100.bolt"}
        if percent <= 10 {return "battery.0"}
        if percent <= 25 {return "battery.25"}
        if percent <= 50 {return "battery.50"}
        if percent <= 75 {return "battery.75"}
        return "battery.100"
    }
}

/// Uses the same fonts, surfaces and warning ink as the surrounding device UI.
/// A timeline ages the sample even when no further HID packet arrives.
struct BatteryStatusView: View {
    @ObservedObject var device: DeviceStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let reading = device.snapshot.batteryReading
            let fresh = device.batteryIsFresh(at: context.date)
            let warning = device.batteryWarning(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label("设备电量", systemImage: symbol(reading, fresh: fresh))
                        .font(VIFLOWTheme.subheading)
                    Spacer(minLength: 12)
                    Text(reading?.percent.map { "\($0)%" } ?? "未确认")
                        .font(VIFLOWTheme.subheading).monospacedDigit()
                        .accessibilityIdentifier("vibekey.battery.percent")
                    Text(state(reading, fresh: fresh))
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                        .accessibilityIdentifier("vibekey.battery.state")
                }
                if let warning {
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(VIFLOWTheme.body).foregroundColor(VIFLOWTheme.errorInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("vibekey.battery.warning")
                }
                if let reading {
                    Text((fresh ? "电量读回 " : "上次电量 · 非实时 ") + reading.readAt.formatted(date: .omitted, time: .standard))
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                        .accessibilityIdentifier("vibekey.battery.read-at")
                }
                if let error = device.batteryReadError {
                    Text(error).font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("连接就绪时每 30 秒刷新；未充电时 ≤20% 提醒，≤10% 加强提醒。设备自报低电量也会提醒，充电或充满时暂停提醒。")
                    .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(VIFLOWTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .viflowPanel(padding: 20)
        }
        .accessibilityIdentifier("vibekey.battery.status")
    }
    private func state(_ reading: BatteryReading?, fresh: Bool) -> String {
        guard let reading else { return "等待读取" }
        guard fresh else { return "非实时" }
        guard reading.percent != nil else { return "电量值未确认" }
        if reading.isFull == true { return "已充满" }
        if reading.isCharging == true { return "充电中" }
        if reading.isCharging == false, reading.isFull == false { return "未充电" }
        return "充电状态未确认"
    }
    private func symbol(_ reading: BatteryReading?, fresh: Bool) -> String {
        guard fresh, let reading, let percent = reading.percent else { return "battery.0" }
        if reading.isCharging == true { return "battery.100.bolt" }
        if percent <= 10 { return "battery.0" }
        if percent <= 25 { return "battery.25" }
        if percent <= 50 { return "battery.50" }
        if percent <= 75 { return "battery.75" }
        return "battery.100"
    }
}
