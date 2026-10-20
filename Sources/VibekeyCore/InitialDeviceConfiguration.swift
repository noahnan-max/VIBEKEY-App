import Foundation

public enum InitialDeviceConfiguration {
    // Current active Studio AU05 profile and matching six hardware readbacks,
    // captured 2026-10-13. This deliberately preserves the user's custom setup.
    public static let defaults: [WorkflowBinding] = [
        binding("上键 · 左 Control", "key.0", "左 Control", 59),
        binding("中键 · Return", "key.1", "Return", 36),
        binding("下键 · Backspace", "key.2", "Backspace", 51),
        binding("旋钮按下 · 右 Control", "knob.press", "右 Control", 62),
        binding("旋钮左转 · 滚轮向上", "knob.left", "滚轮向上", 0),
        binding("旋钮右转 · 滚轮向下", "knob.right", "滚轮向下", 0)
    ]
    private static func binding(_ name: String, _ trigger: String, _ title: String, _ key: UInt16) -> WorkflowBinding {
        WorkflowBinding(name: name, triggerID: trigger, steps: [WorkflowStep(kind: .passthrough, argument: title, keyCode: key)])
    }
}
