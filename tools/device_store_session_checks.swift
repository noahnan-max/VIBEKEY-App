import Foundation
@testable import VibekeyCore

private final class StoreTransportFixture: DeviceTransporting {
    var onReport:((Data)->Void)?
    var onConnection:((Bool,String)->Void)?
    var sent:[Data] = []
    private var connected = false
    func start() {connected = true;onConnection?(true,"owned memory transport")}
    func stop() {guard connected else {return};connected = false;onConnection?(false,"owned transport disconnected")}
    func send(report:Data) throws -> Int32 {sent.append(AU05Codec.decodeReport(report)!);return 0}
    func deliver(_ bytes:[UInt8]) throws {
        onReport?(try AU05Codec.outputReport(plaintext:Data(bytes)+Data(repeating:0,count:64-bytes.count)))
    }
    func authorize() throws {
        let request = sent.last {$0[0] & 31 == 6 && $0[2] == 5}!
        let challenge = (0..<4).reduce(UInt32(0)) {$0 | UInt32(request[5+$1]) << ($1*8)}
        let encoded = challenge ^ 0xd9f4e04c
        try deliver([0x86,2,5,0x11,5]+(0..<4).map {UInt8(truncatingIfNeeded:encoded >> ($0*8))})
    }
}

@main private struct DeviceStoreSessionChecks {
    static var checks = 0
    static func check(_ value:Bool,_ message:String) {
        guard value else {fputs("FAIL: \(message)\n",stderr);exit(1)}
        checks += 1
    }
    static func pump(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
    static func main() throws {
        let transport = StoreTransportFixture()
        let session = DeviceSession(transport:transport)
        let store = DeviceStore(session:session)
        var router = OriginalDeviceActionRouter(), output:[OriginalDeviceActionEvent] = []
        var losses = 0, disconnects = 0, triggers = 0
        store.onTrigger = {id,pressed in
            triggers += 1
            output += router.handle(id,pressed:pressed)
        }
        store.onControlLoss = {losses += 1;output += router.releaseAll()}
        store.onDisconnect = {disconnects += 1}
        store.start()
        check(store.connected && !store.isReady,"USB presence alone made DeviceStore ready")
        try transport.authorize();pump(0.12)
        try transport.deliver([0x86,3,0x0a,0x11,1])
        check(!store.isReady,"Receiver active=1 alone made DeviceStore ready")
        try transport.deliver([0x81,1,2,0x11,0,0,60,0])
        check(store.isReady && store.snapshot.batteryPercent == 60,"A real settings reply did not update DeviceStore readiness/snapshot")
        try transport.deliver([0x8b,0x10,0,1,0])
        try transport.deliver([0x8b,0x10,0,1,3])
        check(output.count == 2,"Original left/right Control presses were not forwarded")
        try transport.deliver([0x8b,0x0b,0])
        check(!store.isReady && store.connected && losses == 1 && disconnects == 1,"Remote sleep failed to notify both control release and audio cancellation")
        check(output.suffix(2).allSatisfy {if case .key(_,let pressed,_) = $0 {return !pressed};return false},"Remote loss did not release the router's held keys")
        try transport.deliver([0x8b,0x0b,0])
        check(losses == 1 && disconnects == 1,"Repeated inactive notice duplicated loss callbacks")
        try transport.deliver([0x86,3,0x0a,0x11,2])
        check(!store.isReady && store.diagnostics.remoteActiveRaw == 2 && store.connectionLabel == "AU05 状态未确认","Unknown query enum was lost or advertised as online")
        try transport.deliver([0x8b,0x10,0,1,1])
        check(store.isReady && output.last == .key(keyCode:36,pressed:true,modifiers:0),"A newer key remained blocked by old remote state")
        let beforeUnknown = triggers
        try transport.deliver([0x8b,0x10,0,7,0])
        check(triggers == beforeUnknown,"Unknown button status became an action")
        try transport.deliver([0x8b,0x10,0,0,4])
        try transport.deliver([0x8b,0x10,0,1,5])
        check(output.suffix(2) == [.scroll(lines:-1,modifiers:0),.scroll(lines:1,modifiers:0)],"Recovery changed original rotary direction or status-zero semantics")
        store.stopForExit()
        check(!store.connected && !store.isReady && losses == 2 && disconnects == 2,"Physical disconnect failed to notify exactly one additional loss")
        check(output.last == .key(keyCode:36,pressed:false,modifiers:0) && router.releaseAll().isEmpty,"Disconnect failed to release only owned keys exactly once")
        let stoppedTriggers = triggers
        try transport.deliver([0x8b,0x10,0,1,0])
        check(triggers == stoppedTriggers,"A late report after disconnect triggered an action")
        print("PASS: \(checks) actual DeviceStore + DeviceSession callback/owned-key-release checks; memory transport, zero HID/mic/CGEvent/UI")
    }
}
