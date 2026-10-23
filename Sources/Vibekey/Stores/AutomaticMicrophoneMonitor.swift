import CoreAudio
import Foundation

/// Reads HAL metadata only. Never creates an audio client, opens a stream,
/// requests microphone permission or changes any audio property.
final class AutomaticMicrophoneMonitor {
    enum State: Equatable { case disconnected, idle, active, unreadable }
    private let queue = DispatchQueue(label: "local.noah.vibekey.microphone-status", qos: .utility)
    private let changed: (State) -> Void
    private var timer: DispatchSourceTimer?
    private var devices: [AudioObjectID] = []
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var nextDiscovery: TimeInterval = 0
    private var lastState: State?
    private var idleSince: TimeInterval?

    init(changed: @escaping (State) -> Void) { self.changed = changed }
    deinit { timer?.cancel(); removeListeners() }
    static func matches(name: String, manufacturer: String, inputStreams: Int, outputStreams: Int) -> Bool {
        // IsRunningSomewhere covers all I/O, so accept only input-only hardware.
        // A speaker or duplex/virtual device must never look like recording.
        let identity = (name + " " + manufacturer).lowercased()
        let tokens = identity.split { !$0.isLetter && !$0.isNumber }
        return inputStreams > 0 && outputStreams == 0 &&
            (tokens.contains("au05") || identity.contains("vibekey") || identity.contains("vypekey"))
    }
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            lastState = nil; idleSince = nil; nextDiscovery = 0
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(30))
            source.setEventHandler { [weak self] in self?.refresh() }
            timer = source; source.resume()
        }
    }
    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil; removeListeners(); devices = []; lastState = nil; idleSince = nil
        }
    }
    private func refresh() {
        guard timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextDiscovery {
            nextDiscovery = now + 2
            guard let all = list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) else { publish(.unreadable); return }
            let found = all.filter { id in
                Self.matches(name: string(id, kAudioObjectPropertyName), manufacturer: string(id, kAudioObjectPropertyManufacturer),
                    inputStreams: list(id, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)?.count ?? 0,
                    outputStreams: list(id, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)?.count ?? 1)
            }.sorted()
            if found != devices {
                removeListeners(); devices = found
                for id in devices {
                    var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
                    if AudioObjectAddPropertyListenerBlock(id, &address, queue, block) == noErr { listeners.append((id, address, block)) }
                }
            }
        }
        guard !devices.isEmpty else { publish(.disconnected); return }
        let states = devices.map { number($0, kAudioDevicePropertyDeviceIsRunningSomewhere) }
        if states.contains(where: { $0 == 1 }) { idleSince = nil; publish(.active) }
        else if states.contains(where: { $0 == nil }) { publish(.unreadable) }
        else if lastState == .active {
            if idleSince == nil { idleSince = now }
            if now - (idleSince ?? now) >= 0.35 { publish(.idle) }
        } else { publish(.idle) }
    }
    private func publish(_ state: State) {
        guard state != lastState else { return }; lastState = state
        DispatchQueue.main.async { [changed] in changed(state) }
    }
    private func removeListeners() {
        for (id, original, block) in listeners {
            var address = original; AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
        listeners = []
    }
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func list(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32]? {
        var address = Self.address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size <= 65_536, size % 4 == 0 else { return nil }
        if size == 0 { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / 4)
        let capacity = size
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &values) == noErr, size <= capacity else { return nil }
        return Array(values.prefix(Int(size) / 4))
    }
    private func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = Self.address(selector), size: UInt32 = 4, value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, size == 4 else { return nil }; return value
    }
    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = Self.address(selector), size = UInt32(MemoryLayout<CFString?>.size), value: CFString?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value as String? ?? ""
    }
}
