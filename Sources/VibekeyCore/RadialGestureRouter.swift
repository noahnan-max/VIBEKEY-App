import Foundation

public struct RadialHoldToken: Equatable, Hashable {
    public let session: UUID
    public let press: UInt64
    public init(session: UUID, press: UInt64) { self.session = session; self.press = press }
}

public struct RadialPresentation: Equatable {
    public let session: RadialHoldToken
    public let allItems: [RadialMenuItem]
    public let globalSelectedIndex: Int
    public var selectedIndex: Int { globalSelectedIndex }
    public var totalCount: Int { allItems.count }
    public var selectedItem: RadialMenuItem { allItems[selectedIndex] }
    public var pageIndex: Int { selectedIndex / RadialMenuValidation.itemsPerPage }
    public var slotIndex: Int { selectedIndex % RadialMenuValidation.itemsPerPage }
    public var pageCount: Int { (allItems.count + 7) / 8 }
    public var items: [RadialMenuItem] { pageItems }
    public var pageItems: [RadialMenuItem] {
        let start = pageIndex * 8
        return Array(allItems[start..<min(start + 8, allItems.count)])
    }
    public init(session: RadialHoldToken, items: [RadialMenuItem], selectedIndex: Int = 0) throws {
        try RadialMenuValidation.validate(RadialMenuDocument(items: items))
        guard items.indices.contains(selectedIndex) else { throw RadialMenuError.invalid("轮盘没有可选的当前位置。") }
        self.init(session: session, allItems: items, globalSelectedIndex: selectedIndex)
    }
    fileprivate init(session: RadialHoldToken, allItems: [RadialMenuItem], globalSelectedIndex: Int) {
        self.session = session; self.allItems = allItems; self.globalSelectedIndex = globalSelectedIndex
    }
}

public enum RadialDismissReason: String, Equatable {
    case cancelled, confirmed, upperKey, ineligible, disabled, configurationChanged
    case disconnected, ownershipChanged, windowClosed, permissionChanged, targetChanged, invalidTime, reset
}

/// These are instructions to the owner, never side effects performed by Core.
public enum RadialGestureEffect: Equatable {
    case forward(id: String, pressed: Bool)
    case scheduleHold(token: RadialHoldToken, deadline: TimeInterval)
    case cancelHold(token: RadialHoldToken)
    case replayMiddleTap(modifiers: UInt64)
    case replayTap(id: String, modifiers: UInt64)
    case show(RadialPresentation)
    case move(RadialPresentation)
    case execute(session: RadialHoldToken, item: RadialMenuItem)
    case dismiss(session: RadialHoldToken, reason: RadialDismissReason)
}

/// All times come from the caller's monotonic clock. Eligibility includes busy
/// state, permissions, physical modifiers and the frozen foreground target.
/// Feed every recognized down/up through this router, even while disabled.
/// reset discards actions but retains consumed-down ownership until its up.
public struct RadialGestureRouter {
    public static let holdDelay: TimeInterval = 0.45
    public private(set) var configuration = RadialMenuDocument()
    public private(set) var presentation: RadialPresentation?
    public var isPresented: Bool { presentation != nil }
    public var pendingHold: RadialHoldToken? { pending?.token }
    private let identity: UUID
    private var sequence: UInt64 = 0
    private var lastTime: TimeInterval?
    private var held: [String: Ownership] = [:]
    private var pending: Pending?
    private struct Pending {
        let triggerID: String
        let token: RadialHoldToken
        let deadline: TimeInterval
        let modifiers: UInt64
        let items: [RadialMenuItem]
    }
    private enum Ownership {
        case forwarded, pendingMiddle, openingHold, suppressed
        case confirmation(started: TimeInterval, session: RadialHoldToken, index: Int)
    }
    public init(sessionID: UUID = UUID()) { identity = sessionID }

    @discardableResult public mutating func configure(_ document: RadialMenuDocument) throws -> [RadialGestureEffect] {
        try RadialMenuValidation.validate(document)
        guard document != configuration else { return [] }
        let effects = reset(reason: document.enabled ? .configurationChanged : .disabled)
        configuration = document
        return effects
    }

    @discardableResult public mutating func reset(reason: RadialDismissReason = .reset) -> [RadialGestureEffect] {
        var effects: [RadialGestureEffect] = []
        if let pending { effects.append(.cancelHold(token: pending.token)) }
        if let presentation { effects.append(.dismiss(session: presentation.session, reason: reason)) }
        pending = nil; presentation = nil; lastTime = nil
        for (key, ownership) in held {
            if case .forwarded = ownership { continue }
            held[key] = .suppressed
        }
        return effects
    }

    public mutating func handle(id: String, pressed: Bool, now: TimeInterval, eligible: Bool, modifiers: UInt64 = 0) -> [RadialGestureEffect] {
        var effects: [RadialGestureEffect] = []
        let wasActive = pending != nil || presentation != nil
        let validTime = acceptTime(now)
        let invalidated = !validTime || !eligible || !configuration.enabled
        if !validTime { effects += reset(reason: .invalidTime) }
        else if (!eligible || !configuration.enabled) && (pending != nil || presentation != nil) {
            effects += reset(reason: configuration.enabled ? .ineligible : .disabled)
        }
        if id == "key.0", pressed, id != configuration.activation.triggerID, id != configuration.activation.cancelTriggerID { effects += reset(reason: .upperKey) }
        let button = ["key.0", "key.1", "key.2", "knob.press"].contains(id)
        if wasActive && invalidated && ["key.0", "key.1", "key.2", "knob.press", "knob.left", "knob.right"].contains(id) {
            // The event that invalidated an open interaction still belongs to
            // that interaction: a failed confirmation must not become Return
            // (or Backspace/scroll) in a newly focused application. A previously
            // forwarded down keeps its up so the downstream owner can release.
            if let ownership = held[id], case .forwarded = ownership { }
            else {
                if button && pressed { held[id] = .suppressed }
                else if button { held.removeValue(forKey: id) }
                return effects
            }
        }
        if let ownership = held[id] {
            if pressed {
                if case .forwarded = ownership { effects.append(.forward(id: id, pressed: true)) }
                return effects
            }
            held.removeValue(forKey: id)
            switch ownership {
            case .forwarded: effects.append(.forward(id: id, pressed: false))
            case .pendingMiddle:
                guard let candidate = pending else { return effects }
                pending = nil; effects.append(.cancelHold(token: candidate.token))
                if eligible && configuration.enabled && validTime {
                    if now < candidate.deadline {
                        effects.append(candidate.triggerID == "key.1" ? .replayMiddleTap(modifiers: candidate.modifiers) : .replayTap(id: candidate.triggerID, modifiers: candidate.modifiers))
                    }
                    else { effects.append(open(candidate)) }
                }
            case .confirmation(let began, let session, let index):
                if eligible && validTime && now >= began,
                   (!configuration.activation.requiresHold || now - began < Self.holdDelay),
                   presentation?.session == session, presentation?.selectedIndex == index {
                    effects += confirm(eligible: true)
                }
            case .openingHold, .suppressed: break
            }
            return effects
        }
        if !pressed {
            if presentation != nil && (id == "knob.left" || id == "knob.right") { return effects }
            // An orphan middle up can never replay Return. Other ordinary ups
            // remain available to the existing downstream key owner.
            if id != "key.1" && !(id == configuration.activation.triggerID && configuration.enabled) {
                effects.append(.forward(id: id, pressed: false))
            }
            return effects
        }
        if let presentation {
            if id == configuration.activation.triggerID {
                held[id] = .confirmation(started: now, session: presentation.session, index: presentation.selectedIndex)
                return effects
            }
            if id == configuration.activation.cancelTriggerID {
                held[id] = .suppressed; effects += reset(reason: .cancelled); return effects
            }
            switch id {
            case "knob.left", "knob.right":
                let delta = id == "knob.left" ? -1 : 1
                let next = (presentation.selectedIndex + delta + presentation.totalCount) % presentation.totalCount
                effects += select(index: next, eligible: eligible)
                return effects
            case "key.1", "knob.press":
                held[id] = .confirmation(started: now, session: presentation.session, index: presentation.selectedIndex)
                return effects
            case "key.2":
                held[id] = .suppressed; effects += reset(reason: .cancelled); return effects
            default: break
            }
        }
        if id == configuration.activation.triggerID, configuration.enabled, !configuration.activation.requiresHold {
            // The configured wheel trigger owns both phases even when opening is
            // unavailable. It must not fall through to the original Right Control.
            held[id] = .suppressed
            guard eligible, validTime, !configuration.items.isEmpty, sequence < UInt64.max else { return effects }
            sequence += 1
            let candidate = Pending(triggerID:id,token:RadialHoldToken(session:identity,press:sequence),deadline:now,
                                    modifiers:modifiers,items:configuration.items)
            held[id] = .openingHold
            effects.append(open(candidate))
            return effects
        }
        if id == configuration.activation.triggerID, configuration.activation.requiresHold, configuration.enabled, eligible, !configuration.items.isEmpty {
            guard validTime, sequence < UInt64.max, (now + Self.holdDelay).isFinite, now + Self.holdDelay > now else {
                held[id] = .suppressed; return effects
            }
            sequence += 1
            let token = RadialHoldToken(session: identity, press: sequence)
            pending = Pending(triggerID:id,token: token, deadline: now + Self.holdDelay, modifiers: modifiers, items: configuration.items)
            held[id] = .pendingMiddle
            effects.append(.scheduleHold(token: token, deadline: now + Self.holdDelay))
            return effects
        }
        if button, id != configuration.activation.triggerID, pending != nil { effects += reset(reason: id == "key.0" ? .upperKey : .ineligible) }
        if button { held[id] = .forwarded }
        effects.append(.forward(id: id, pressed: pressed))
        return effects
    }

    public mutating func holdFired(token: RadialHoldToken, now: TimeInterval, eligible: Bool) -> [RadialGestureEffect] {
        // A stale timer must not invalidate, advance or alter a new session.
        guard let candidate = pending, candidate.token == token else { return [] }
        guard acceptTime(now) else { return reset(reason: .invalidTime) }
        guard eligible, configuration.enabled else { return reset(reason: .ineligible) }
        guard now >= candidate.deadline else { return [.scheduleHold(token: token, deadline: candidate.deadline)] }
        pending = nil; held[candidate.triggerID] = .openingHold
        return [.cancelHold(token: token), open(candidate)]
    }

    public mutating func select(index: Int, eligible: Bool) -> [RadialGestureEffect] {
        guard eligible else { return reset(reason: .ineligible) }
        guard let old = presentation, old.allItems.indices.contains(index), index != old.selectedIndex else { return [] }
        let next = RadialPresentation(session: old.session, allItems: old.allItems, globalSelectedIndex: index)
        presentation = next; return [.move(next)]
    }
    public mutating func confirm(eligible: Bool) -> [RadialGestureEffect] {
        guard eligible else { return reset(reason: .ineligible) }
        guard let selected = presentation else { return [] }
        let effects = reset(reason: .confirmed)
        return effects + [.execute(session: selected.session, item: selected.selectedItem)]
    }
    private mutating func open(_ candidate: Pending) -> RadialGestureEffect {
        let view = RadialPresentation(session: candidate.token, allItems: candidate.items, globalSelectedIndex: 0)
        presentation = view; return .show(view)
    }
    private mutating func acceptTime(_ time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0, lastTime == nil || time >= lastTime! else { return false }
        lastTime = time; return true
    }
}
