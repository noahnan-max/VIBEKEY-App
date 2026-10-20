import Foundation

protocol DeviceTransporting: AnyObject {
    var onReport: ((Data) -> Void)? { get set }
    var onConnection: ((Bool, String) -> Void)? { get set }
    func start()
    func stop()
    @discardableResult func send(report: Data) throws -> Int32
}
extension HIDTransport: DeviceTransporting {}

public struct DeviceCommand: Equatable, Hashable {
    public let frameType: UInt8
    public let group: UInt8
    public let code: UInt8
    public let name: String
    public init(_ group: UInt8, _ code: UInt8, _ name: String, frameType: UInt8 = 1) { self.group = group; self.code = code; self.name = name; self.frameType = frameType }
    public static let active = DeviceCommand(3, 0x0a, "AU05 在线状态", frameType: 6)
    public static let version = DeviceCommand(4, 4, "固件版本")
    public static let battery = DeviceCommand(1, 2, "电量")
    public static let noiseReduction = DeviceCommand(1, 0x90, "麦克风降噪")
    public static let motor = DeviceCommand(6, 0x40, "震动强度")
    public static let sleep = DeviceCommand(1, 0x42, "休眠时间")
    public static let hooks = DeviceCommand(11, 0x89, "按键接管模式")
    public static let lights = DeviceCommand(11, 0x88, "指示灯")
    public static let audioMode = DeviceCommand(6, 0x51, "收音按键模式")
    public static let microphone = DeviceCommand(1, 0x2a, "设备麦克风开关")
    public static let refresh = [active, version, battery, noiseReduction, motor, sleep, hooks, lights, audioMode]
}

public struct DeviceReply {
    public let frameType: UInt8
    public let group: UInt8
    public let code: UInt8
    public let isRead: Bool
    public let payload: [UInt8]
    public init?(decoded: Data) {
        let b = [UInt8](decoded)
        guard b.count >= 8, b[3] & 0x10 != 0 else { return nil }
        frameType = b[0] & 0x1f
        guard frameType == 1 || (frameType == 6 && b[1] & 15 == 3 && b[2] == 0x0a && b[3] & 1 == 1) else { return nil }
        group = b[1] & 0x0f; code = b[2]; isRead = b[3] & 1 != 0
        payload = Array(b.dropFirst(4))
    }
    public func matches(_ command: DeviceCommand) -> Bool { frameType == command.frameType && group == command.group && code == command.code }
    public func uint16(_ offset: Int) -> Int? {
        guard offset >= 0, payload.count >= offset + 2 else { return nil }
        return Int(payload[offset]) | Int(payload[offset + 1]) << 8
    }
}

public struct DeviceSnapshot {
    public var firmware: String?
    public var batteryPercent: Int?
    public var batteryReading: BatteryReading?
    public var lastBatteryReadAt: Date? { batteryReading?.readAt }
    public var motor: Int?
    public var sleepSeconds: Int?
    public var hooks: Int?
    public var noiseReduction: Int?
    public var noiseLow: Int?
    public var noiseHigh: Int?
    public var lightMode: Int?
    public var lightBrightness: Int?
    public var audioMode: Int?
    public var microphoneEnabled: Int?
    public var lastReadAt: Date?
    public init() {}

    public mutating func apply(_ reply: DeviceReply, at now: Date = Date()) -> Bool {
        guard reply.isRead, reply.frameType == 1 else { return false }
        let p = reply.payload
        switch (reply.group, reply.code) {
        case (4, 4):
            guard p.count >= 15 else { return false }
            firmware = "\(p[6]).\(p[7]).\(p[8])" + (p[14] == 0 ? "" : ".\(p[14])")
        case (1, 2):
            guard let reading = BatteryReading(reply: reply, readAt: now) else { return false }
            batteryReading = reading; batteryPercent = reading.percent
        case (1, 0x90):
            guard p.count >= 5, let low = reply.uint16(1), let high = reply.uint16(3) else { return false }
            noiseReduction = Int(p[0]); noiseLow = Int(Int16(bitPattern: UInt16(low))); noiseHigh = Int(Int16(bitPattern: UInt16(high)))
        case (6, 0x40): motor = Int(p[0])
        case (1, 0x42): guard let seconds = reply.uint16(0) else { return false }; sleepSeconds = seconds
        case (11, 0x89): hooks = Int(p[0])
        case (11, 0x88): guard p.count >= 24 else { return false }; lightMode = Int(p[2]); lightBrightness = Int(p[3])
        case (6, 0x51): audioMode = Int(p[0])
        case (1, 0x2a): microphoneEnabled = Int(p[0])
        default: return false
        }
        lastReadAt = now
        return true
    }
}

/// Content-free link evidence. USB presence and receiver authentication alone
/// do not prove that the AU05 unit is responding.
public struct DeviceSessionDiagnostics: Equatable {
    public var authenticated = false
    public var authenticationTimedOut = false
    public var remoteActive: Bool?
    /// Query byte or complete notice flags; the recovered notice uses bit 0.
    public var remoteActiveRaw: UInt8?
    public var deviceResponding = false
    public var inputReports = 0
    public var decodedReports = 0
    public var settingReplies = 0
    public var keyReports = 0
    public var readTimeouts = 0
    public init() {}
    public var isDeviceReady:Bool {authenticated && deviceResponding}
    public func lostDevice(since previous:Self)->Bool {
        remoteActive == false && !deviceResponding && (previous.remoteActive != false || previous.deviceResponding)
    }
}

public final class DeviceSession {
    public var onConnection: ((Bool, String) -> Void)?
    public var onReply: ((DeviceReply) -> Void)?
    public var onEvent: ((Data) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onDiagnostics: ((DeviceSessionDiagnostics) -> Void)?
    public private(set) var connected = false
    public private(set) var sessionEstablished = false
    public private(set) var diagnostics = DeviceSessionDiagnostics()
    private let transport: DeviceTransporting
    private struct Request {
        let id = UUID()
        let command: DeviceCommand
        let frame: Data
        let read: Bool
        let refreshID: UUID?
        let completion: ((Result<DeviceReply, Error>) -> Void)?
        var shouldSend:(()->Bool)? = nil
        var replyMatches:((DeviceReply)->Bool)? = nil
    }
    private var queue: [Request] = []
    private var pending: Request?
    private var timeout: Timer?
    private var heartbeatTimer: Timer?
    private var handshakeTimer: Timer?
    private var dispatchTimer: Timer?
    private var challenge: UInt32 = 0
    private var handshakeAttempts = 0
    private var authenticationFailed = false
    private var refreshID: UUID?
    private var refreshSettingsRemaining = 0
    private var needsSettingsRefresh = false

    public convenience init() { self.init(transport:HIDTransport()) }
    init(transport: DeviceTransporting) {
        self.transport = transport
        transport.onConnection = { [weak self] connected, message in
            guard let self = self else { return }
            self.connected = connected
            self.diagnostics = DeviceSessionDiagnostics()
            self.refreshID = nil; self.refreshSettingsRemaining = 0; self.needsSettingsRefresh = false
            if !connected { self.cancelRequests(); self.stopHandshake() }
            else { self.beginHandshake() }
            self.onConnection?(connected, message)
            self.onDiagnostics?(self.diagnostics)
        }
        transport.onReport = { [weak self] report in self?.receive(report) }
    }
    public func start() { transport.start() }
    public func stop() { stopHandshake(); transport.stop(); cancelRequests() }
    public func refresh() {
        guard connected else { return }
        // A failed five-attempt handshake is retried only by this explicit
        // refresh. Repeated clicks during a live attempt share one challenge.
        if authenticationFailed {
            beginHandshake()
            onDiagnostics?(diagnostics)
        }
        guard refreshID == nil else { return }
        let id = UUID(); refreshID = id; needsSettingsRefresh = true
        enqueueRead(.active, refreshID:id, completion: { [weak self] _ in
            guard let self, self.refreshID == id else { return }
            self.refreshID = nil
            self.resumeSettingsRefresh()
        })
    }
    public func read(_ command: DeviceCommand, payload: [UInt8] = [], completion: ((Result<DeviceReply, Error>) -> Void)? = nil) {
        enqueueRead(command, payload:payload, refreshID:nil, completion:completion)
    }
    /// Best-effort background reads must recheck readiness at dequeue. This
    /// prevents an idle-time poll waking a unit after its connection changes.
    public func readIfAllowed(_ command: DeviceCommand, shouldSend: @escaping () -> Bool, completion: @escaping (Result<DeviceReply, Error>) -> Void) {
        enqueueRead(command, refreshID: nil, shouldSend: shouldSend, completion: completion)
    }
    public func readMatching(_ command: DeviceCommand, payload: [UInt8] = [], matching: @escaping (DeviceReply)->Bool, completion: @escaping (Result<DeviceReply, Error>) -> Void) {
        enqueueRead(command, payload:payload, refreshID:nil, matching:matching, completion:completion)
    }
    public func write(_ command: DeviceCommand, frame: Data, shouldSend:(()->Bool)? = nil, completion: @escaping (Result<DeviceReply, Error>) -> Void) {
        enqueue(Request(command: command, frame: frame, read: false, refreshID:nil, completion: completion,shouldSend:shouldSend))
    }
    private func enqueueRead(_ command:DeviceCommand, payload:[UInt8] = [], refreshID:UUID?, shouldSend:(()->Bool)? = nil, matching:((DeviceReply)->Bool)? = nil, completion:((Result<DeviceReply, Error>) -> Void)? = nil) {
        enqueue(Request(command:command, frame:AU05Codec.readFrame(group:command.group, command:command.code, payload:payload, frameType:command.frameType), read:true, refreshID:refreshID, completion:completion, shouldSend:shouldSend, replyMatches:matching))
    }
    private func resumeSettingsRefresh() {
        guard needsSettingsRefresh, refreshID == nil, connected, sessionEstablished,
              diagnostics.remoteActive != false || diagnostics.deviceResponding else { return }
        let id = UUID(); refreshID = id; needsSettingsRefresh = false
        let commands = DeviceCommand.refresh.filter { $0 != .active }
        refreshSettingsRemaining = commands.count
        for command in commands {
            enqueueRead(command, refreshID:id, completion: { [weak self] _ in
                guard let self, self.refreshID == id else { return }
                self.refreshSettingsRemaining -= 1
                if self.refreshSettingsRemaining == 0 { self.refreshID = nil }
            })
        }
    }
    private func observeRemoteActive(_ raw:UInt8, notice:Bool = false) {
        diagnostics.remoteActiveRaw = raw
        let active = notice ? raw & 1 : raw
        diagnostics.remoteActive = active == 0 ? false : (active == 1 ? true : nil)
        if active == 0 {
            diagnostics.deviceResponding = false
            needsSettingsRefresh = true
            // Cancel only our refresh batch. Explicit reads/writes retain their
            // own completions; reconnect never replays a hardware write.
            if let id = refreshID, refreshSettingsRemaining > 0 {
                refreshID = nil; refreshSettingsRemaining = 0
                let cancelled = queue.filter { $0.refreshID == id }
                queue.removeAll { $0.refreshID == id }
                let active = pending?.refreshID == id ? pending : nil
                if active != nil { pending = nil; timeout?.invalidate(); timeout = nil }
                ((active.map { [$0] } ?? []) + cancelled).forEach { $0.completion?(.failure(SessionError.deviceUnavailable)) }
                scheduleNext(after:0.04)
            }
        }
        switch active {
        case 0: onLog?("接收器已连接，AU05 暂未在线")
        case 1: onLog?("接收器报告 AU05 已在线")
        default: onLog?("接收器报告未知 AU05 在线状态：\(raw)")
        }
    }
    private func enqueue(_ request: Request) {
        guard connected else { request.completion?(.failure(TransportError.disconnected)); return }
        guard !authenticationFailed else { request.completion?(.failure(SessionError.authenticationTimeout)); return }
        guard queue.count < 64 else { request.completion?(.failure(SessionError.busy)); return }
        queue.append(request); next()
    }
    private func next() {
        guard dispatchTimer == nil, pending == nil, !queue.isEmpty, connected, sessionEstablished else { return }
        let request = queue.removeFirst(); pending = request
        guard request.shouldSend?() != false else {finish(.failure(SessionError.cancelled));return}
        do {
            try transport.send(report: AU05Codec.outputReport(plaintext: request.frame))
            guard pending?.id == request.id else { return }
            timeout = deviceTimer(interval: 1.5, repeats: false) { [weak self] _ in
                guard let self, self.pending?.id == request.id else { return }
                self.finish(.failure(SessionError.timeout(request.command.name)))
            }
        } catch { finish(.failure(error)) }
    }
    private func receive(_ report: Data) {
        guard connected else { return }
        diagnostics.inputReports += 1
        guard let decoded = AU05Codec.decodeReport(report) else { onLog?("忽略未识别的 USB 报告"); onDiagnostics?(diagnostics); return }
        diagnostics.decodedReports += 1
        if !sessionEstablished, !authenticationFailed, DeviceHandshake.accepts(decoded, challenge: challenge) {
            sessionEstablished = true; authenticationFailed = false; handshakeTimer?.invalidate(); handshakeTimer = nil
            scheduleNext(after:0.1)
            diagnostics.authenticated = true;diagnostics.authenticationTimedOut = false;onDiagnostics?(diagnostics)
            onLog?("AU05 设备会话已验证")
            // The original SDK gates its command worker on authentication.
            // Establish keepalive before dispatching queued settings reads.
            do { try transport.send(report:AU05Codec.outputReport(plaintext:DeviceHandshake.heartbeat)) }
            catch { onLog?(error.localizedDescription) }
            heartbeatTimer = deviceTimer(interval: 1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                do { try self.transport.send(report: AU05Codec.outputReport(plaintext: DeviceHandshake.heartbeat)) }
                catch { self.onLog?(error.localizedDescription) }
            }
            return
        }
        guard sessionEstablished else { onDiagnostics?(diagnostics); return }
        if let reply = DeviceReply(decoded: decoded) {
            if reply.matches(.active) {
                observeRemoteActive(reply.payload[0])
            } else {
                diagnostics.settingReplies += 1;diagnostics.deviceResponding = true
            }
            onDiagnostics?(diagnostics)
            onReply?(reply)
            if let request = pending, reply.matches(request.command), reply.isRead == request.read, request.replyMatches?(reply) != false { finish(.success(reply)) }
            resumeSettingsRefresh()
        } else if decoded.first.map({ $0 & 0x1f == 14 }) == true { return }
        else {
            if decoded.count >= 3, decoded[0] & 31 == 11, decoded[1] == 11 {
                observeRemoteActive(decoded[2], notice:true)
            } else if decoded.count >= 5,decoded[0] & 31 == 11,decoded[1] == 0x10 {
                diagnostics.keyReports += 1;diagnostics.deviceResponding = true
            }
            onDiagnostics?(diagnostics)
            onEvent?(decoded)
            resumeSettingsRefresh()
        }
    }
    private func beginHandshake() {
        stopHandshake(); challenge = UInt32.random(in: 1...UInt32.max); handshakeAttempts = 0; authenticationFailed = false
        diagnostics.authenticationTimedOut = false
        diagnostics.remoteActive = nil; diagnostics.remoteActiveRaw = nil; diagnostics.deviceResponding = false
        sendHandshake()
        handshakeTimer = deviceTimer(interval: 1, repeats: true) { [weak self] _ in self?.sendHandshake() }
    }
    private func sendHandshake() {
        guard connected, !sessionEstablished else { return }
        guard handshakeAttempts < 5 else {
            handshakeTimer?.invalidate(); handshakeTimer = nil
            authenticationFailed = true
            diagnostics.authenticationTimedOut = true;onDiagnostics?(diagnostics)
            onLog?("设备会话未确认，未发送设置或控制请求")
            cancelRequests(error:SessionError.authenticationTimeout)
            return
        }
        handshakeAttempts += 1
        do { try transport.send(report: AU05Codec.outputReport(plaintext: DeviceHandshake.request(challenge: challenge))) }
        catch { onLog?(error.localizedDescription) }
    }
    private func stopHandshake() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil; handshakeTimer?.invalidate(); handshakeTimer = nil; sessionEstablished = false
        dispatchTimer?.invalidate(); dispatchTimer = nil
        diagnostics.authenticated = false
    }
    private func scheduleNext(after delay:TimeInterval) {
        dispatchTimer?.invalidate()
        dispatchTimer = deviceTimer(interval:delay, repeats:false) { [weak self] _ in
            guard let self else { return }
            self.dispatchTimer = nil; self.next()
        }
    }
    private func finish(_ result: Result<DeviceReply, Error>) {
        guard let request = pending else { return }
        pending = nil; timeout?.invalidate(); timeout = nil
        // Install the quiet interval before invoking a completion that may
        // enqueue the settings stage of a refresh.
        scheduleNext(after:0.04)
        if case .failure(let error) = result {
            if request.read,case SessionError.timeout = error {diagnostics.readTimeouts += 1;onDiagnostics?(diagnostics)}
            onLog?(error.localizedDescription)
        }
        request.completion?(result)
    }
    private func cancelRequests(error:Error = TransportError.disconnected) {
        timeout?.invalidate(); timeout = nil
        let waiting = (pending.map { [$0] } ?? []) + queue
        pending = nil; queue.removeAll()
        waiting.forEach { $0.completion?(.failure(error)) }
    }
}

public enum SessionError: Error, LocalizedError {
    case busy, timeout(String), authenticationTimeout, deviceUnavailable, cancelled
    public var errorDescription: String? {
        switch self {
        case .busy: return "设备操作队列已满"
        case .timeout(let name): return "\(name)读取超时，状态仍未确认"
        case .authenticationTimeout: return "AU05会话验证超时，未发送控制请求"
        case .deviceUnavailable: return "AU05 暂未在线，恢复连接后重新读取设置"
        case .cancelled:return "设备操作已撤销，未发送旧控制请求"
        }
    }
}

/// Device work must progress while AppKit tracks a menu or runs a sheet.
private func deviceTimer(interval:TimeInterval,repeats:Bool,block:@escaping @Sendable (Timer)->Void)->Timer {
    let timer=Timer(timeInterval:interval,repeats:repeats,block:block)
    RunLoop.main.add(timer,forMode:.common)
    return timer
}
