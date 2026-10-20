import SwiftUI
import VibekeyCore

/// A visual selector only. Editing and executing supply separate callbacks.
struct RadialWheelDiagram:View {
    let items:[RadialMenuItem]
    let selectedSlot:Int?
    var diameter:CGFloat = 336
    let centerHeading:String
    let centerTitle:String
    let centerCaption:String
    var centerSymbol:String?
    var centerAction:(()->Void)?
    var canAdd = false
    var identifierPrefix = "radial.slot."
    let onSelect:(Int)->Void
    var onAdd:(()->Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body:some View {
        ZStack {
            Circle().fill(VIFLOWTheme.surface).shadow(color:.black.opacity(0.12),radius:10,y:3)
            ForEach(0..<8) {slot in
                let item = slot < items.count ? items[slot] : nil
                let adding = canAdd && slot == items.count
                let title = item.map{$0.name.isEmpty ? "未命名" : $0.name} ?? (adding ? "添加" : "空位置")
                let selected = selectedSlot == slot && item != nil
                let angle = Double(slot)*Double.pi/4-Double.pi/2
                let shift:CGFloat = selected ? 4 : 0
                Button {
                    if item != nil {onSelect(slot)}
                    else if adding {onAdd?()}
                } label: {
                    ZStack {
                        RadialSector(slot:slot).fill(selected ? VIFLOWTheme.filled : VIFLOWTheme.surface)
                        RadialSector(slot:slot).stroke(VIFLOWTheme.border,lineWidth:1)
                        if item != nil || adding {
                            VStack(spacing:6) {
                                Image(systemName:item.map(RadialMenuView.symbol) ?? "plus")
                                    .font(.system(size:20,weight:.medium))
                                Text(title)
                                    .font(.system(size:11,weight:.medium)).lineLimit(2).multilineTextAlignment(.center)
                                    .frame(width:diameter*0.215,height:30)
                            }.foregroundColor(selected ? VIFLOWTheme.filledInk : VIFLOWTheme.ink)
                                .position(x:diameter/2+diameter/3*CGFloat(cos(angle)),y:diameter/2+diameter/3*CGFloat(sin(angle)))
                        }
                    }.frame(width:diameter,height:diameter).contentShape(RadialSector(slot:slot))
                }.buttonStyle(.plain).contentShape(RadialSector(slot:slot))
                    .offset(x:shift*CGFloat(cos(angle)),y:shift*CGFloat(sin(angle)))
                    .opacity(item == nil && !adding ? 0.35 : 1)
                    .disabled(item == nil && !adding)
                    .accessibilityLabel(adding ? "添加轮盘项目" : title)
                    .accessibilityValue(selected ? "已选中" : "")
                    .accessibilityIdentifier(identifierPrefix+String(slot))
            }
            if let centerAction {
                Button(action:centerAction) {center}.buttonStyle(.plain).contentShape(Circle())
                    .accessibilityLabel("关闭轮盘")
            } else {center.allowsHitTesting(false)}
        }.frame(width:diameter,height:diameter)
            .animation(reduceMotion ? nil : .easeOut(duration:0.1),value:selectedSlot)
    }
    private var center:some View {
        VStack(spacing:5) {
            Text(centerHeading).font(.system(size:10,weight:.semibold)).foregroundColor(VIFLOWTheme.secondary)
            Text(centerTitle).font(.system(size:14,weight:.semibold)).lineLimit(2).multilineTextAlignment(.center)
            HStack(spacing:7) {
                Text(centerCaption).font(.system(size:11,design:.monospaced))
                if let centerSymbol {Image(systemName:centerSymbol).font(.system(size:9,weight:.medium))}
            }.foregroundColor(VIFLOWTheme.secondary)
        }.frame(width:diameter*0.34,height:diameter*0.34).background(VIFLOWTheme.surface,in:Circle())
            .foregroundColor(VIFLOWTheme.ink)
    }
}
