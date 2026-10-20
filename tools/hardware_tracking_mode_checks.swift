import Foundation
@testable import VibekeyCore

private final class TrackingTransport:DeviceTransporting {
    var onReport:((Data)->Void)?
    var onConnection:((Bool,String)->Void)?
    var sent:[Data]=[]
    func start() {onConnection?(true,"owned transport")}
    func stop() {}
    func send(report:Data)throws->Int32 {sent.append(AU05Codec.decodeReport(report)!);return 0}
    func authorize()throws {
        let challengeFrame=sent.last{$0[0] & 31 == 6 && $0[2] == 5}!
        let challenge=(0..<4).reduce(UInt32(0)){$0 | UInt32(challengeFrame[5+$1]) << ($1*8)} ^ 0xd9f4e04c
        let bytes:[UInt8]=[0x86,2,5,0x11,5]+(0..<4).map{UInt8(truncatingIfNeeded:challenge >> ($0*8))}
        onReport?(try AU05Codec.outputReport(plaintext:Data(bytes)+Data(repeating:0,count:64-bytes.count)))
    }
    var heartbeats:Int {sent.filter{Array($0.prefix(5))==Array(DeviceHandshake.heartbeat.prefix(5))}.count}
}

@main struct TrackingModeChecks {
    static func main() throws {
        let expectsStall=CommandLine.arguments.contains("--expect-old-stall")
        let mode=RunLoop.Mode("VibekeyOwnedTrackingMode")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFRunLoopMode(rawValue:mode.rawValue as CFString))
        // An owned source keeps this isolated mode running; no NSMenu or input.
        let keeper=Timer(timeInterval:0.02,repeats:true){_ in};RunLoop.main.add(keeper,forMode:mode)
        defer {keeper.invalidate()}
        func pump(_ seconds:Double) {
            let deadline=Date().addingTimeInterval(seconds)
            while Date()<deadline {_=RunLoop.main.run(mode:mode,before:min(deadline,Date().addingTimeInterval(0.04)))}
        }
        let transport=TrackingTransport(),session=DeviceSession(transport:transport)
        session.start();try transport.authorize();let before=transport.heartbeats
        var timedOut=false
        session.read(.active){if case .failure(SessionError.timeout)=($0) {timedOut=true}}
        pump(2.05)
        let activeSent=transport.sent.contains{$0.count>2 && $0[0] & 31 == DeviceCommand.active.frameType && $0[1] == DeviceCommand.active.group && $0[2] == DeviceCommand.active.code}
        let heartbeatAdvanced=transport.heartbeats>before
        session.stop()
        let retry=TrackingTransport(),retrySession=DeviceSession(transport:retry);retrySession.start();let attempts=retry.sent.count;pump(1.15)
        let handshakeAdvanced=retry.sent.count>attempts;retrySession.stop()
        let values=[activeSent,timedOut,heartbeatAdvanced,handshakeAdvanced]
        let passed=expectsStall ? values.allSatisfy{!$0}:values.allSatisfy{$0}
        let report:[String:Any]=["status":passed ? "PASS":"FAIL","mode":mode.rawValue,"expectation":expectsStall ? "reproduce old default-mode stall":"dispatch, timeout, heartbeat and retry continue in tracking mode","activeReadDispatched":activeSent,"requestTimeoutDelivered":timedOut,"heartbeatAdvanced":heartbeatAdvanced,"handshakeRetryAdvanced":handshakeAdvanced,"physicalHardwareOpened":false,"UIOpened":false]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted),as:UTF8.self));if !passed {exit(1)}
    }
}
