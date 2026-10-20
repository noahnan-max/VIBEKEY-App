import Foundation
import AppKit
import ApplicationServices
import CoreAudio
import Darwin

public final class HostActions {
    private static let executor = HostActionExecutor()

    public init() {}

    /// Checks existing authorization without displaying a permission prompt.
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Call only after an explicit test or an enabled, recognized device trigger.
    public func run(_ steps: [WorkflowStep], log: @escaping (String) -> Void) async throws {
        try WorkflowValidation.validate(steps)
        try await Self.executor.run(steps, log: log)
    }
}

private actor HostActionExecutor {
    private var running = false
    private var activeShortcut: ShortcutsCommand?

    func run(_ steps: [WorkflowStep], log: @escaping (String) -> Void) async throws {
        guard !running, activeShortcut?.isRunning != true else { throw WorkflowError.alreadyRunning }
        try Task.checkCancellation()
        if steps.contains(where: { $0.kind == .shortcut }), !HostActions.accessibilityGranted {
            throw WorkflowError.accessibilityRequired
        }
        running = true
        defer { running = false }
        let deadline = ProcessInfo.processInfo.systemUptime + WorkflowValidation.maximumDuration
        do {
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw WorkflowError.timedOut("工作流") }
                // Recheck filesystem-sensitive inputs immediately before use.
                if let error = step.validationError { throw WorkflowError.invalidConfiguration(error) }
                log("步骤 \(index + 1)/\(steps.count)：\(step.kind.title)")
                switch step.kind {
                case .passthrough:
                    log("沿用当前 AU05 按键动作。")
                case .shortcut:
                    try await pressKey(step)
                case .scrollUp, .scrollDown:
                    guard HostActions.accessibilityGranted else { throw WorkflowError.accessibilityRequired }
                    let source = CGEventSource(stateID: .privateState)
                    let lines = Int32(step.scrollLines) * (step.kind == .scrollUp ? 1 : -1)
                    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { throw WorkflowError.systemFailure("无法创建滚动事件。") }
                    event.flags = CGEventSource.flagsState(.hidSystemState); event.post(tap: .cghidEventTap)
                case .openApp:
                    try await openApplication(step.argument, timeout: min(remaining, WorkflowValidation.workspaceTimeout))
                    log("系统已确认应用打开请求。")
                case .openURL:
                    guard let url = WorkflowValidation.webURL(step.argument) else {
                        throw WorkflowError.invalidConfiguration("网址无效。")
                    }
                    try await openWebURL(url, timeout: min(remaining, WorkflowValidation.workspaceTimeout))
                    log("系统已确认网址打开请求；网页内容未核验。")
                case .runShortcut:
                    let command = ShortcutsCommand()
                    activeShortcut = command
                    do { try await command.run(name: step.argument, timeout: min(remaining, WorkflowValidation.shortcutTimeout)) }
                    catch {
                        if !command.isRunning { activeShortcut = nil }
                        throw error
                    }
                    activeShortcut = nil
                    log("系统快捷指令已退出成功；其业务结果需由对应应用确认。")
                case .delay:
                    guard step.seconds <= remaining else { throw WorkflowError.timedOut("工作流") }
                    try await Task.sleep(nanoseconds: UInt64(step.seconds * 1_000_000_000))
                case .volumeUp:
                    log(try OutputAudio.changeVolume(by: 0.0625))
                case .volumeDown:
                    log(try OutputAudio.changeVolume(by: -0.0625))
                case .toggleMute:
                    log(try OutputAudio.toggleMute())
                case .inputSource:
                    log("已切换到" + (try await InputSourceCatalog.select(step.argument)))
                }
            }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime <= deadline else { throw WorkflowError.timedOut("工作流") }
            log("工作流步骤执行结束。")
        } catch {
            log(error is CancellationError ? "工作流已取消，已停止后续步骤。" : error.localizedDescription)
            throw error
        }
    }

    private func pressKey(_ step: WorkflowStep) async throws {
        guard HostActions.accessibilityGranted else { throw WorkflowError.accessibilityRequired }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: false) else {
            throw WorkflowError.systemFailure("无法创建快捷键事件。")
        }
        down.flags = CGEventFlags(rawValue: step.modifiers)
        up.flags = down.flags
        let modifierFlags:[UInt16:UInt64]=[59:0x00040001,62:0x00042000,56:0x00020002,60:0x00020004,58:0x00080020,61:0x00080040,55:0x00100008,54:0x00100010,63:0x00800000]
        if let own=modifierFlags[step.keyCode] {
            let physical=CGEventSource.flagsState(.hidSystemState)
            down.type = .flagsChanged;up.type = .flagsChanged
            down.flags=CGEventFlags(rawValue:step.modifiers|own).union(physical)
            up.flags=physical
        }
        down.post(tap: .cghidEventTap)
        // Cancellation must still release the key that this macro pressed.
        defer {
            if modifierFlags[step.keyCode] != nil {up.flags=CGEventSource.flagsState(.hidSystemState)}
            up.post(tap: .cghidEventTap)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func openApplication(_ argument: String, timeout: Double) async throws {
        try await workspaceRequest(timeout: timeout) { completion in
            let url: URL?
            if argument.hasPrefix("/") { url = URL(fileURLWithPath: argument) }
            else { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: argument) }
            guard let url else { completion.finish(.failure(WorkflowError.systemFailure("找不到指定的已安装应用。"))); return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error { completion.finish(.failure(WorkflowError.systemFailure("系统无法打开应用（错误 \((error as NSError).code)）。"))) }
                else if app != nil { completion.finish(.success(())) }
                else { completion.finish(.failure(WorkflowError.systemFailure("系统未确认应用打开结果。"))) }
            }
        }
    }

    private func openWebURL(_ url: URL, timeout: Double) async throws {
        try await workspaceRequest(timeout: timeout) { completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open(url, configuration: configuration) { app, error in
                if let error { completion.finish(.failure(WorkflowError.systemFailure("系统无法打开网址（错误 \((error as NSError).code)）。"))) }
                else if app != nil { completion.finish(.success(())) }
                else { completion.finish(.failure(WorkflowError.systemFailure("系统未确认网址打开结果。"))) }
            }
        }
    }

    private func workspaceRequest(timeout: Double, request: @escaping (WorkspaceCompletion) -> Void) async throws {
        let completion = WorkspaceCompletion()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion.install(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    completion.finish(.failure(WorkflowError.timedOut("打开请求")))
                }
                DispatchQueue.main.async {
                    guard !completion.finished else { return }
                    request(completion)
                }
            }
        }, onCancel: { completion.finish(.failure(CancellationError())) })
    }
}

/// A workspace callback, cancellation and timeout may race; resume exactly once.
private final class WorkspaceCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class ShortcutsCommand {
    private let process = Process()
    private let errorPipe = Pipe()
    private let outputLock = NSLock()
    private var errorOutputSeen = false

    var isRunning: Bool { process.isRunning }

    func run(name: String, timeout: Double) async throws {
        try Task.checkCancellation()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = try WorkflowValidation.shortcutArguments(for: name)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        // Drain the pipe without retaining output that may contain user data.
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.markErrorOutput()
        }
        defer { errorPipe.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() }
        catch { throw WorkflowError.systemFailure("无法启动系统快捷指令（错误 \((error as NSError).code)）。") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw WorkflowError.timedOut("系统快捷指令") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try Task.checkCancellation()
        } catch {
            await stopOwnChild()
            throw error
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw WorkflowError.commandFailed(process.terminationStatus, sawErrorOutput)
        }
    }

    private var sawErrorOutput: Bool {
        outputLock.lock()
        defer { outputLock.unlock() }
        return errorOutputSeen
    }

    private func markErrorOutput() {
        outputLock.lock()
        errorOutputSeen = true
        outputLock.unlock()
    }

    private func stopOwnChild() async {
        guard process.isRunning else { return }
        process.terminate()
        await waitForOwnChild(seconds: 0.5)
        if process.isRunning {
            // Only the child this invocation launched is eligible for termination.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            await waitForOwnChild(seconds: 0.5)
        }
    }

    private func waitForOwnChild(seconds: Double) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            // A canceled Task.sleep returns immediately; cleanup uses a cancelless timer.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
    }
}

private enum OutputAudio {
    static func changeVolume(by delta: Float32) throws -> String {
        let device = try defaultOutput()
        let addresses = try writableAddresses(device: device, selector: kAudioDevicePropertyVolumeScalar)
        let originals = try addresses.map { try readFloat(device, address: $0) }
        guard originals.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw WorkflowError.audioUnavailable("输出设备返回了无效音量，未写入。")
        }
        let targets = originals.map { min(1, max(0, $0 + delta)) }
        var changed = 0
        do {
            for (address, target) in zip(addresses, targets) {
                changed += 1
                try writeFloat(device, address: address, value: target)
            }
            let actual = try addresses.map { try readFloat(device, address: $0) }
            guard try defaultOutput() == device, zip(actual, targets).allSatisfy({ $0.0.isFinite && abs($0.0 - $0.1) <= 0.02 }) else {
                throw WorkflowError.audioUnavailable("输出音量未通过回读核验。")
            }
            let average = actual.reduce(0, +) / Float32(actual.count)
            return "输出音量已回读：\(Int((average * 100).rounded()))%" + (actual.count > 1 ? "（声道平均）" : "") + "。"
        } catch {
            var restored = true
            for index in 0..<changed {
                do {
                    try writeFloat(device, address: addresses[index], value: originals[index])
                    let actual = try readFloat(device, address: addresses[index])
                    if !actual.isFinite || abs(actual - originals[index]) > 0.02 { restored = false }
                } catch { restored = false }
            }
            throw WorkflowError.audioUnavailable("音量操作未确认；" + (restored ? "已回读恢复原值。" : "部分恢复结果未知，请检查系统音量。"))
        }
    }

    static func toggleMute() throws -> String {
        let device = try defaultOutput()
        let addresses = try writableAddresses(device: device, selector: kAudioDevicePropertyMute)
        let originals = try addresses.map { try readUInt32(device, address: $0) }
        guard originals.allSatisfy({ $0 <= 1 }) else { throw WorkflowError.audioUnavailable("输出设备返回了无效静音状态，未写入。") }
        let target: UInt32 = originals.allSatisfy({ $0 == 1 }) ? 0 : 1
        var changed = 0
        do {
            for address in addresses {
                changed += 1
                try writeUInt32(device, address: address, value: target)
            }
            let actual = try addresses.map { try readUInt32(device, address: $0) }
            guard try defaultOutput() == device, actual.allSatisfy({ $0 == target }) else {
                throw WorkflowError.audioUnavailable("输出静音未通过回读核验。")
            }
            return target == 1 ? "已回读：电脑输出已静音。" : "已回读：电脑输出已取消静音。"
        } catch {
            var restored = true
            for index in 0..<changed {
                do {
                    try writeUInt32(device, address: addresses[index], value: originals[index])
                    if try readUInt32(device, address: addresses[index]) != originals[index] { restored = false }
                } catch { restored = false }
            }
            throw WorkflowError.audioUnavailable("静音操作未确认；" + (restored ? "已回读恢复原值。" : "部分恢复结果未知，请检查系统静音。"))
        }
    }

    private static func defaultOutput() throws -> AudioObjectID {
        let address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let device = try readUInt32(AudioObjectID(kAudioObjectSystemObject), address: address)
        guard device != kAudioObjectUnknown else { throw WorkflowError.audioUnavailable("当前没有可用的默认电脑输出设备。") }
        return device
    }

    private static func writableAddresses(device: AudioObjectID, selector: AudioObjectPropertySelector) throws -> [AudioObjectPropertyAddress] {
        func address(_ element: UInt32) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        }
        func writable(_ value: AudioObjectPropertyAddress) -> Bool {
            var value = value
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(device, &value) &&
                AudioObjectIsPropertySettable(device, &value, &settable) == noErr && settable.boolValue
        }
        let main = address(kAudioObjectPropertyElementMain)
        if writable(main) { return [main] }
        let channels = try outputChannelCount(device)
        let addresses = (1...channels).map { address(UInt32($0)) }
        guard addresses.allSatisfy(writable) else {
            throw WorkflowError.audioUnavailable("默认输出设备不支持完整的电脑音量或静音控制；未写入。")
        }
        return addresses
    }

    private static func outputChannelCount(_ device: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size))
        guard size >= MemoryLayout<AudioBufferList>.size, size <= 65_536 else {
            throw WorkflowError.audioUnavailable("输出设备的声道信息无效。")
        }
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { allocation.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, allocation))
        let pointer = allocation.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = Int(pointer.pointee.mNumberBuffers)
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        guard buffers > 0, buffers <= 64, offset + buffers * MemoryLayout<AudioBuffer>.size <= Int(size) else {
            throw WorkflowError.audioUnavailable("输出设备的缓冲区信息无效。")
        }
        let channels = UnsafeMutableAudioBufferListPointer(pointer).reduce(0) { $0 + Int($1.mNumberChannels) }
        guard (1...64).contains(channels) else { throw WorkflowError.audioUnavailable("输出设备的声道数量不受支持。") }
        return channels
    }

    private static func readFloat(_ device: AudioObjectID, address: AudioObjectPropertyAddress) throws -> Float32 {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value))
        guard size == MemoryLayout<Float32>.size else { throw WorkflowError.audioUnavailable("音量回读长度不符。") }
        return value
    }

    private static func readUInt32(_ device: AudioObjectID, address: AudioObjectPropertyAddress) throws -> UInt32 {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value))
        guard size == MemoryLayout<UInt32>.size else { throw WorkflowError.audioUnavailable("设备状态回读长度不符。") }
        return value
    }

    private static func writeFloat(_ device: AudioObjectID, address: AudioObjectPropertyAddress, value: Float32) throws {
        var address = address
        var value = value
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value))
    }

    private static func writeUInt32(_ device: AudioObjectID, address: AudioObjectPropertyAddress, value: UInt32) throws {
        var address = address
        var value = value
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw WorkflowError.audioUnavailable("电脑输出设备操作失败（系统错误 \(status)）。") }
    }
}
