import Foundation

public enum HardwareBindingDecision:Equatable {
    case original,custom(UUID),consumed
}

/// Freeze the owner at key-down. A saved mapping change cannot leave an old
/// modifier held or send an original Return alongside a custom macro.
public struct HardwareBindingRouter {
    private enum Owner {case original,custom}
    private var held:[String:Owner]=[:]
    public init() {}
    public mutating func reset() {held.removeAll()}
    public mutating func route(_ id:String,pressed:Bool,customBinding:UUID?)->HardwareBindingDecision {
        if id=="knob.left" || id=="knob.right" {
            return pressed ? customBinding.map{.custom($0)} ?? .original : .consumed
        }
        guard ["key.0","key.1","key.2","knob.press"].contains(id) else {return .consumed}
        if pressed {
            guard held[id]==nil else {return .consumed}
            if let customBinding {held[id] = .custom;return .custom(customBinding)}
            held[id] = .original;return .original
        }
        guard let owner=held.removeValue(forKey:id) else {return .consumed}
        switch owner {case .original:return .original;case .custom:return .consumed}
    }
}
