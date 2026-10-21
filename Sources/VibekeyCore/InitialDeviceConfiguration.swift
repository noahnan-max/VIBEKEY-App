import Foundation

public enum InitialDeviceConfiguration {
    // Portable daily-use preset based on the saved AU05 profile. It contains
    // no personal app paths, account identifiers or device writes.
    public static let defaults: [WorkflowBinding] = [
        binding("上键 · 左 Control", "key.0", WorkflowStep(kind: .shortcut, keyCode: 59)),
        binding("中键 · Return", "key.1", WorkflowStep(kind: .passthrough, argument: "Return", keyCode: 36)),
        binding("下键 · Backspace", "key.2", WorkflowStep(kind: .passthrough, argument: "Backspace", keyCode: 51)),
        binding("旋钮按下 · 右 Control", "knob.press", WorkflowStep(kind: .passthrough, argument: "右 Control", keyCode: 62)),
        binding("旋钮左转 · 滚轮向上", "knob.left", WorkflowStep(kind: .scrollUp, scrollLines: 19)),
        binding("旋钮右转 · 滚轮向下", "knob.right", WorkflowStep(kind: .scrollDown, scrollLines: 18))
    ]
    public static var radialMenu: RadialMenuDocument {
        func key(_ name: String, _ code: UInt16, _ flags: UInt64 = 0x00100000) -> RadialMenuItem {
            RadialMenuItem(name: name, steps: [WorkflowStep(kind: .shortcut, keyCode: code, modifiers: flags)])
        }
        return RadialMenuDocument(schemaVersion: 3, enabled: true, items: [
            WindowOverviewAction.item, key("复制", 8), key("粘贴", 9), key("撤销", 6), key("全选", 0),
            key("重做", 6, 0x00120000),
            RadialMenuItem(name: "打开 GitHub", steps: [WorkflowStep(kind: .openURL, argument: "https://github.com")]),
            key("进入或退出全屏", 3, 0x00140000),
            RadialMenuItem(name: "静音切换", steps: [WorkflowStep(kind: .toggleMute)]),
            key("显示全部窗口", 126, 0x00040000), key("整个屏幕截图", 20, 0x00120000),
            key("选择区域截图", 21, 0x00120000)
        ], activation: .knobPress)
    }
    private static func binding(_ name: String, _ trigger: String, _ step: WorkflowStep) -> WorkflowBinding {
        WorkflowBinding(name: name, triggerID: trigger, steps: [step])
    }
}
