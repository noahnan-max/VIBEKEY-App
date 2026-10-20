import Foundation
import IOKit.hid

public final class HIDTransport {
    public static let vendorID = 0xfff1
    public static let productID = 0x00dd
    public var onReport: ((Data) -> Void)?
    public var onConnection: ((Bool, String) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    public private(set) var isConnected = false

    public init() {}
    deinit { stop(); reportBuffer.deallocate() }

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let match: [String: Int] = [
            kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: 0xfffc, kIOHIDPrimaryUsageKey: 1
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context = context else { return }
            Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().attach(device, result: result)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { onConnection?(false, "USB 访问失败：\(String(format: "%08x", result))") }
    }

    private func attach(_ candidate: IOHIDDevice, result: IOReturn) {
        guard manager != nil,device == nil else { return }
        let opened = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            onConnection?(false, "AU05 已发现，USB 打开失败：\(String(format: "%08x", opened))")
            return
        }
        device = candidate
        isConnected = true
        reportBuffer.initialize(repeating: 0, count: 64)
        IOHIDDeviceRegisterInputReportCallback(candidate, reportBuffer, 64, { context, result, _, _, _, report, length in
            guard result == kIOReturnSuccess, let context = context, length > 0, length <= 64 else { return }
            let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            guard transport.isConnected,transport.device != nil else {return}
            transport.onReport?(Data(bytes: report, count: length))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        onConnection?(true, "AU05 · USB 已连接")
    }

    private func detach(_ candidate: IOHIDDevice) {
        guard let current = device, CFEqual(current, candidate) else { return }
        IOHIDDeviceRegisterInputReportCallback(current,reportBuffer,64,nil,Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceUnscheduleFromRunLoop(current, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(current, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        isConnected = false
        onConnection?(false, "AU05 已断开")
    }

    public func stop() {
        if let current = device { detach(current) }
        if let manager = manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
    }

    @discardableResult
    public func send(report: Data) throws -> IOReturn {
        guard let device = device else { throw TransportError.disconnected }
        guard report.count == 64, report.first == 0x55 else { throw TransportError.invalidReport }
        let result: IOReturn = report.withUnsafeBytes { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0x55), buffer.bindMemory(to: UInt8.self).baseAddress!, report.count)
        }
        guard result == kIOReturnSuccess else { throw TransportError.writeFailed(result) }
        return result
    }
}

public enum TransportError: Error, LocalizedError {
    case disconnected, invalidReport, writeFailed(IOReturn)
    public var errorDescription: String? {
        switch self {
        case .disconnected: return "AU05 未连接"
        case .invalidReport: return "USB 报告长度或编号无效"
        case .writeFailed(let code): return "USB 发送失败：\(String(format: "%08x", code))"
        }
    }
}
