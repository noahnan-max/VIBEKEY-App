import Foundation

public struct HardwareTrigger: Identifiable {
    public let id: String
    public let title: String
    public let pressed: Bool
    public static let available = [
        HardwareTrigger(id: "key.0", title: "上方按键", pressed: true),
        HardwareTrigger(id: "key.1", title: "中间按键", pressed: true),
        HardwareTrigger(id: "key.2", title: "下方按键", pressed: true),
        HardwareTrigger(id: "knob.press", title: "旋钮按下", pressed: true),
        HardwareTrigger(id: "knob.left", title: "旋钮向左", pressed: true),
        HardwareTrigger(id: "knob.right", title: "旋钮向右", pressed: true)
    ]
    public static func resolve(position: UInt8, status: UInt8) -> HardwareTrigger? {
        // registerVibeKey descriptor at main image 0x10094f6d0...720.
        // Rotation is an impulse, including status 0. Unknown raw statuses must
        // not become a synthetic key-down just because they are nonzero.
        guard status == 0 || status == 1 else { return nil }
        let id: String
        switch position {
        case 0...2: id = "key.\(position)"
        case 3: id = "knob.press"
        case 4: id = "knob.right"
        case 5: id = "knob.left"
        default: return nil
        }
        guard let descriptor = available.first(where: { $0.id == id }) else { return nil }
        return HardwareTrigger(id: id, title: descriptor.title, pressed: position >= 4 || status == 1)
    }
}
