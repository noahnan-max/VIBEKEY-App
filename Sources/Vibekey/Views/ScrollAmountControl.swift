import SwiftUI
import VibekeyCore

struct ScrollAmountControl: View {
    @Binding var lines: Int
    var perDetent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(perDetent ? "每转一格滚动" : "滚动行数").font(VIFLOWTheme.body)
                Spacer()
                Stepper("\(lines) 行", value: $lines, in: AU05ActionDefaults.scrollRange)
                    .fixedSize().accessibilityIdentifier("vibekey.scroll.lines")
            }
            Slider(value: Binding(get: { Double(lines) }, set: { lines = Int($0.rounded()) }),
                   in: Double(AU05ActionDefaults.scrollRange.lowerBound)...Double(AU05ActionDefaults.scrollRange.upperBound), step: 1)
                .accessibilityLabel(perDetent ? "每格滚动行数" : "滚动行数")
                .accessibilityIdentifier("vibekey.scroll.amount")
            Text(perDetent ? "范围1–50行，实际距离由当前应用决定；轮盘内仍逐项选择。" : "范围1–50行，实际距离由当前应用决定。")
                .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
