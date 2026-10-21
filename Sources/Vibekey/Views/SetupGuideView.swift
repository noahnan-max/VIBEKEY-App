import AppKit
import SwiftUI
import VibekeyCore

struct SetupGuideView:View {
    @ObservedObject var device:DeviceStore
    @ObservedObject var settings:HardwareSettings
    @State private var testEvents:[String]=[]
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Text("开始使用").font(VIFLOWTheme.title)
                VStack(alignment:.leading,spacing:10) {
                    Label("内置日常操作预设",systemImage:"square.grid.2x2").font(VIFLOWTheme.subheading)
                    Text("上键左 Control · 中键回车 · 下键删除 · 左转上滚 · 右转下滚 · 旋钮单击打开轮盘。")
                    Text("轮盘已准备复制、粘贴、窗口总览和截图等 12 项动作。首次使用自动加载，可在对应模块中修改；已有配置继续保留。")
                        .font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).viflowPanel(padding:18)
                step("1","连接 AU05",ready:device.isReady) {
                    HStack {Text(device.connectionDetail);Spacer();Button("重新检测") {device.refresh();settings.refresh()}}
                }
                step("2","允许快捷键与宏",ready:settings.accessibilityGranted) {
                    HStack {Text(settings.accessibilityGranted ? "辅助功能已允许":"在系统设置中为 VIBEKEY 开启辅助功能。");Spacer();Button("打开系统设置") {settings.openAccessibilitySettings()}}
                }
                step("3","测试 AU05 按键",ready:false) {
                    VStack(alignment:.leading,spacing:10) {
                        Text("点击下面的测试框，再试中键回车、下键删除和滚轮。上键默认左 Control，可继续调用已有输入法的快捷功能。")
                        HardwareTestPad(onInput:{testEvents=Array((testEvents+[$0]).suffix(4))}).frame(height:220)
                        Label(testEvents.isEmpty ? "等待按键或滚轮":testEvents.joined(separator:" → "),systemImage:"keyboard").font(VIFLOWTheme.caption).foregroundColor(VIFLOWTheme.secondary)
                    }
                }
                Text("旋钮轮盘：按一下打开，转动选择，再按一下确认。入口在“我的设备 → AU05 → 快捷轮盘”。")
                    .foregroundColor(VIFLOWTheme.secondary)
            }.padding(28).frame(maxWidth:1000,alignment:.leading)
        }.onAppear {settings.refresh()}
    }
    private func step<Content:View>(_ number:String,_ title:String,ready:Bool,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text(number).font(VIFLOWTheme.subheading).frame(width:28,height:28).background(VIFLOWTheme.accentSoft,in:Circle());Text(title).font(VIFLOWTheme.subheading);Spacer();if ready {Image(systemName:"checkmark.circle.fill").foregroundColor(VIFLOWTheme.accent)}}
            content()
        }.viflowPanel(padding:18)
    }
}

struct HardwareTestPad:NSViewRepresentable {
    var onInput:(String)->Void
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
        let editor=HardwareTestTextView(frame:NSRect(x:0,y:0,width:600,height:220))
        editor.font = .systemFont(ofSize:14);editor.isRichText=false;editor.isEditable=true
        editor.isVerticallyResizable=true;editor.autoresizingMask=[.width];editor.textContainer?.widthTracksTextView=true
        editor.textContainerInset=NSSize(width:12,height:12);editor.onInput=onInput
        editor.string=(1...30).map{"测试行 \($0) · 使用 AU05 滚轮上下滚动。"}.joined(separator:"\n")
        editor.setAccessibilityIdentifier("hardware.testPad");scroll.documentView=editor;return scroll
    }
    func updateNSView(_ view:NSScrollView,context:Context) {(view.documentView as? HardwareTestTextView)?.onInput=onInput}
}
final class HardwareTestTextView:NSTextView {
    var onInput:((String)->Void)?
    override func keyDown(with event:NSEvent) {super.keyDown(with:event);onInput?(event.keyCode==36 ? "已收到 Return":event.keyCode==51 ? "已收到 Backspace":"已收到按键")}
    override func flagsChanged(with event:NSEvent) {super.flagsChanged(with:event);if [59,62].contains(event.keyCode) {onInput?((event.keyCode==59 ? "左 Control":"右 Control")+(event.modifierFlags.contains(.control) ? " 按下":" 松开"))}}
    override func scrollWheel(with event:NSEvent) {super.scrollWheel(with:event);onInput?(event.scrollingDeltaY>0 ? "滚轮向上":"滚轮向下")}
}
