import AppKit
import SwiftUI
import VibekeyCore

private final class RadialPanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}
@MainActor final class RadialMenuOverlay {
    let panel:NSPanel
    static let size = NSSize(width:380,height:410)
    init(controller:RadialMenuController) {
        panel = RadialPanel(contentRect:NSRect(origin:.zero,size:Self.size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isFloatingPanel = true;panel.level = .floating;panel.hidesOnDeactivate = false
        panel.isOpaque = false;panel.backgroundColor = .clear;panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let view = RadialScrollHostingView(rootView:RadialMenuView(controller:controller))
        view.rotate = {[weak controller] in controller?.rotate($0)}
        panel.contentView = view
    }
    static func placement(anchor:NSPoint,visibleFrame:NSRect)->NSRect {
        let x = min(max(anchor.x-size.width/2,visibleFrame.minX+8),max(visibleFrame.minX+8,visibleFrame.maxX-size.width-8))
        let y = min(max(anchor.y-size.height/2,visibleFrame.minY+8),max(visibleFrame.minY+8,visibleFrame.maxY-size.height-8))
        return NSRect(origin:NSPoint(x:x,y:y),size:size)
    }
    func show(at point:NSPoint) {
        (panel.contentView as? RadialScrollHostingView<RadialMenuView>)?.resetScroll()
        let frame = (NSScreen.screens.first{$0.frame.contains(point)} ?? NSScreen.main)?.visibleFrame
        if let frame {panel.setFrame(Self.placement(anchor:point,visibleFrame:frame),display:false)}
        panel.orderFrontRegardless()
    }
    func hide() {(panel.contentView as? RadialScrollHostingView<RadialMenuView>)?.resetScroll();panel.orderOut(nil)}
    func close() {panel.contentView = nil;panel.close()}
    var geometry:(visible:Bool,key:Bool,main:Bool,frame:NSRect) {(panel.isVisible,panel.isKeyWindow,panel.isMainWindow,panel.frame)}
}

struct RadialSector:Shape {
    let slot:Int
    func path(in rect:CGRect)->Path {
        let center = CGPoint(x:rect.midX,y:rect.midY),outer = min(rect.width,rect.height)/2,inner = outer*0.38
        let angle = Double(slot)*45-90,gap = 1.2
        let start = Angle.degrees(angle-22.5+gap),end = Angle.degrees(angle+22.5-gap)
        var p = Path()
        p.addArc(center:center,radius:outer,startAngle:start,endAngle:end,clockwise:false)
        p.addLine(to:CGPoint(x:center.x+inner*CGFloat(cos(end.radians)),y:center.y+inner*CGFloat(sin(end.radians))))
        p.addArc(center:center,radius:inner,startAngle:end,endAngle:start,clockwise:true)
        p.closeSubpath();return p
    }
}

struct RadialMenuView:View {
    @ObservedObject var controller:RadialMenuController
    var body:some View {
        VStack(spacing:8) {
            if let view = controller.presentation {
                let isPreview = controller.previewMode
                RadialWheelDiagram(items:view.items,selectedSlot:view.slotIndex,
                    centerHeading:isPreview ? "预览" : "VIBEKEY",centerTitle:view.selectedItem.name,
                    centerCaption:"\(view.pageIndex+1) / \(view.pageCount)",centerSymbol:"xmark",centerAction:{controller.dismissFromDiagram(session:view.session)},
                    onSelect:{slot in
                        controller.chooseFromDiagram(session:view.session,preview:isPreview,index:view.pageIndex*8+slot)
                    })
                Text(controller.previewMode ? "预览 · 转动试选，确认不执行" : controller.activation.instruction)
                    .font(.system(size:11,weight:.medium)).foregroundColor(VIFLOWTheme.ink)
                    .padding(.horizontal,12).padding(.vertical,6).background(VIFLOWTheme.surface,in:Capsule())
            }
        }.padding(20).frame(width:RadialMenuOverlay.size.width,height:RadialMenuOverlay.size.height)
            .foregroundColor(VIFLOWTheme.ink)
    }
    static func symbol(_ item:RadialMenuItem)->String {
        if WindowOverviewAction.matches(item.steps) {return "macwindow.on.rectangle"}
        guard item.steps.count == 1,let step = item.steps.first else {return "square.stack.3d.up"}
        switch step.kind {
        case .shortcut:
            guard step.modifiers & 0x00100000 != 0 else {return "keyboard"}
            switch step.keyCode {
            case 8:return "doc.on.doc"
            case 9:return "doc.on.clipboard"
            case 6:return step.modifiers & 0x00020000 != 0 ? "arrow.uturn.forward" : "arrow.uturn.backward"
            case 0:return "rectangle.dashed"
            case 7:return "scissors"
            default:return "command"
            }
        case .openApp:return "app"
        case .openURL:return "globe"
        case .runShortcut:return "bolt"
        case .volumeUp:return "speaker.wave.3"
        case .volumeDown:return "speaker.wave.1"
        case .toggleMute:return "speaker.slash"
        case .delay:return "clock"
        case .passthrough:return "circle"
        case .inputSource:return "character.bubble"
        case .scrollUp:return "arrow.up"
        case .scrollDown:return "arrow.down"
        }
    }
}
