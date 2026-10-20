import SwiftUI

/// Hit targets follow the AU05 product render's 188 × 692 coordinate space.
/// Selecting a part opens its editor; this view never executes a hardware action.
struct AU05HardwarePreview: View {
    var selectedTriggerID: String? = nil
    var onSelect: (String) -> Void
    private let scale: CGFloat = 390 / 692

    var body: some View {
        ZStack(alignment:.topLeading) {
            DeviceProductArtwork(product:.au05)
                .frame(width:188 * scale,height:390).position(x:92,y:195)
            target("knob.press",title:"旋钮 · 按下",size:164 * scale,circular:true)
                .position(x:92,y:210 * scale)
            target("key.0",title:"上键",size:118 * scale)
                .position(x:92,y:370 * scale)
            target("key.1",title:"中键",size:118 * scale)
                .position(x:92,y:484 * scale)
            target("key.2",title:"下键",size:118 * scale)
                .position(x:92,y:598 * scale)
            rotation("knob.left",title:"左转",symbol:"arrow.counterclockwise")
                .position(x:17,y:210 * scale)
            rotation("knob.right",title:"右转",symbol:"arrow.clockwise")
                .position(x:167,y:210 * scale)
        }.frame(width:184,height:390)
            .accessibilityElement(children:.contain)
            .accessibilityLabel("AU05 按键位置")
            .accessibilityIdentifier("vibekey.device.hardware-map")
    }

    private func target(_ id:String,title:String,size:CGFloat,circular:Bool=false)->some View {
        let selected=selectedTriggerID == id
        return Button {onSelect(id)} label: {
            ZStack {
                RoundedRectangle(cornerRadius:circular ? size/2 : 6)
                    .fill(selected ? VIFLOWTheme.accent.opacity(0.10) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius:circular ? size/2 : 6)
                        .stroke(selected ? VIFLOWTheme.accent : Color.clear,lineWidth:2.5)
                        .allowsHitTesting(false))
                if circular {Text("按下").font(VIFLOWTheme.caption).foregroundColor(selected ? VIFLOWTheme.accent : Color(white: 0.75))}
            }.frame(width:size,height:size)
                .contentShape(RoundedRectangle(cornerRadius:circular ? size/2 : 6))
        }.buttonStyle(.plain).help("选择\(title)的配置")
            .accessibilityLabel(title).accessibilityValue(selected ? "已选中":"未选中")
            .accessibilityIdentifier("hardware."+id)
    }

    private func rotation(_ id:String,title:String,symbol:String)->some View {
        let selected=selectedTriggerID == id
        return Button {onSelect(id)} label: {
            VStack(spacing:4) {
                Image(systemName:symbol).font(.system(size:17,weight:.medium))
                Text(title).font(VIFLOWTheme.caption)
            }.frame(width:30,height:52)
                .foregroundColor(selected ? VIFLOWTheme.accent : VIFLOWTheme.secondary)
                .background(selected ? VIFLOWTheme.accentSoft : VIFLOWTheme.surface,in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help("选择旋钮\(title)的配置")
            .accessibilityLabel("旋钮 · "+title).accessibilityValue(selected ? "已选中":"未选中")
            .accessibilityIdentifier("hardware."+id)
    }
}
