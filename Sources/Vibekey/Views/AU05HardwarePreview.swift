import SwiftUI

/// Hit targets follow the complete 3D render's projected 320 × 1000 canvas.
/// Selecting a part opens its editor; this view never executes a hardware action.
struct AU05HardwarePreview: View {
    var selectedTriggerID: String? = nil
    var onSelect: (String) -> Void
    private let scale: CGFloat = 390 / AU05ArtworkLayout.size.height

    var body: some View {
        ZStack(alignment:.topLeading) {
            DeviceProductArtwork(product:.au05)
                .frame(width:AU05ArtworkLayout.size.width * scale,height:390).position(x:92,y:195)
            target("knob.press",title:"旋钮 · 按下",part:AU05ArtworkLayout.knob,circular:true)
                .position(project(AU05ArtworkLayout.knob.center))
            target("key.0",title:"上键",part:AU05ArtworkLayout.keys[0])
                .position(project(AU05ArtworkLayout.keys[0].center))
            target("key.1",title:"中键",part:AU05ArtworkLayout.keys[1])
                .position(project(AU05ArtworkLayout.keys[1].center))
            target("key.2",title:"下键",part:AU05ArtworkLayout.keys[2])
                .position(project(AU05ArtworkLayout.keys[2].center))
            rotation("knob.left",title:"左转",symbol:"arrow.counterclockwise")
                .position(x:17,y:AU05ArtworkLayout.knob.center.y * scale)
            rotation("knob.right",title:"右转",symbol:"arrow.clockwise")
                .position(x:167,y:AU05ArtworkLayout.knob.center.y * scale)
        }.frame(width:184,height:390)
            .accessibilityElement(children:.contain)
            .accessibilityLabel("AU05 按键位置")
            .accessibilityIdentifier("vibekey.device.hardware-map")
    }

    private func project(_ point:CGPoint)->CGPoint {
        CGPoint(x:92 + (point.x - AU05ArtworkLayout.size.width / 2) * scale,y:point.y * scale)
    }

    private func target(_ id:String,title:String,part:AU05ArtworkLayout.Part,circular:Bool=false)->some View {
        let selected=selectedTriggerID == id
        let width=part.size.width * scale, height=part.size.height * scale
        let radius=circular ? min(width,height)/2 : 6
        return Button {onSelect(id)} label: {
            ZStack {
                RoundedRectangle(cornerRadius:radius)
                    .fill(selected ? VIFLOWTheme.accent.opacity(0.10) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius:radius)
                        .stroke(selected ? VIFLOWTheme.accent : Color.clear,lineWidth:2.5)
                        .allowsHitTesting(false))
                if circular {Text("按下").font(VIFLOWTheme.caption).foregroundColor(selected ? VIFLOWTheme.accent : Color(white: 0.75))}
            }.frame(width:width,height:height)
                .contentShape(RoundedRectangle(cornerRadius:radius))
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
