import Foundation
@testable import VibekeyCore

final class SessionFixture: DeviceTransporting {
    var onReport: ((Data) -> Void)?
    var onConnection: ((Bool,String) -> Void)?
    var sent:[Data] = []
    func start() { onConnection?(true,"fixture") }
    func stop() { onConnection?(false,"fixture stopped") }
    func send(report:Data) throws -> Int32 { sent.append(AU05Codec.decodeReport(report)!); return 0 }
    var controls:[Data] { sent.filter { $0.first! & 31 == 1 } }
    var handshakes:[Data] {sent.filter {$0[0] & 31 == 6 && $0[2] == 5}}
    var reads:[Data] {sent.filter {$0[0] & 31 == 1 || ($0[0] & 31 == 6 && $0[2] == 0x0a)}}
    func deliver(_ prefix:[UInt8]) throws {
        let frame = Data(prefix) + Data(repeating:0,count:64-prefix.count)
        onReport?(try AU05Codec.outputReport(plaintext:frame))
    }
    func reply(_ command:DeviceCommand, payload:[UInt8] = []) throws {
        try deliver([0x80 | command.frameType,command.group,command.code,0x11] + payload)
    }
    func authorize(valid:Bool, request:Data? = nil) throws {
        let request = request ?? handshakes.last!
        var challenge:UInt32 = 0
        for n in 0..<4 { challenge |= UInt32(request[5+n]) << (n*8) }
        let encoded = (valid ? challenge : challenge ^ 1) ^ 0xd9f4e04c
        try deliver([0x86,2,5,0x11,5] + (0..<4).map { UInt8(truncatingIfNeeded:encoded >> ($0*8)) })
    }
}
var checks = 0
func check(_ condition:Bool,_ message:String) {
    guard condition else { fputs("FAIL: \(message)\n",stderr); exit(1) }; checks += 1
}
func pump(_ seconds:Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
let fixture = SessionFixture()
// Own fixture injection exercises the actual queue and timers without opening HID.
let live = DeviceSession(transport:fixture)
var results = 0, errors = 0
live.start()
live.read(.battery) { if case .success = $0 { results += 1 } else { errors += 1 } }
live.read(.sleep) { if case .success = $0 { results += 1 } else { errors += 1 } }
check(fixture.controls.isEmpty,"Settings sent before authentication")
try fixture.authorize(valid:false); pump(0.12)
check(!live.sessionEstablished && fixture.controls.isEmpty,"Foreign auth unblocked commands")
try fixture.authorize(valid:true)
check(live.sessionEstablished,"Valid auth was not accepted")
check(fixture.sent.last?.prefix(5) == Data([6,1,0x23,0,1]),"Keepalive did not precede command dispatch")
pump(0.14)
check(fixture.controls.count == 1 && fixture.controls[0][2] == 2,"First read did not dispatch after auth")
try fixture.deliver([0x81,1,0x42,0x11,0x10,0x0e,0,0])
check(results == 0 && fixture.controls.count == 1,"Unrelated reply completed or advanced the queue")
try fixture.deliver([0x81,1,2,0x10,0,0,60,0])
check(results == 0,"Write acknowledgement completed a read")
try fixture.deliver([0x81,1,2,0x11,0,0,60,0]); pump(0.07)
check(results == 1 && fixture.controls.count == 2,"Read completion did not release the next command")
try fixture.deliver([0x81,1,0x42,0x11,0x10,0x0e,0,0]); pump(0.05)
check(results == 2 && errors == 0,"Expected read results did not arrive exactly once")
live.read(.version) { if case .failure = $0 { errors += 1 } }
live.stop(); pump(0.05)
check(errors == 1 && !live.connected && !live.sessionEstablished,"Disconnect did not cancel the pending command")
try fixture.authorize(valid:true); pump(0.12)
check(!live.sessionEstablished,"Late auth revived a disconnected session")

let closedFixture = SessionFixture(), closed = DeviceSession(transport:closedFixture)
var rejected = 0
closed.start()
closed.write(.sleep,frame:try DeviceControls.sleep(seconds:3600)) {
    if case .failure(let error) = $0, case SessionError.authenticationTimeout = error { rejected += 1 }
}
pump(5.2)
check(closedFixture.controls.isEmpty,"An unauthenticated write reached the transport")
check(rejected == 1,"Auth deadline did not fail a queued write")
closed.read(.battery) { if case .failure = $0 { rejected += 1 } }
check(rejected == 2 && closedFixture.controls.isEmpty,"Commands hung after failed authentication")
check(closed.diagnostics.authenticationTimedOut && !closed.diagnostics.authenticated,"Authentication failure remained displayed as pending")
check(closedFixture.handshakes.count == 5,"Authentication did not stop after five attempts")
let expiredChallenge = closedFixture.handshakes.last!
try closedFixture.authorize(valid:true)
check(!closed.sessionEstablished,"An expired challenge revived authentication without an explicit retry")
closed.refresh()
for _ in 0..<10 {closed.refresh()}
check(closedFixture.handshakes.count == 6 && !closed.diagnostics.authenticationTimedOut,"Refresh failed to restart one bounded authentication attempt")
try closedFixture.authorize(valid:true,request:expiredChallenge)
check(!closed.sessionEstablished,"The previous connection challenge authenticated a refreshed session")
pump(5.2)
check(closedFixture.handshakes.count == 10 && closed.diagnostics.authenticationTimedOut,"The refreshed authentication exceeded its own five-attempt bound")
pump(1.1)
check(closedFixture.handshakes.count == 10,"Failed refreshed authentication restarted itself without user action")
closed.refresh()
try closedFixture.authorize(valid:true);pump(0.12)
check(closed.sessionEstablished && closedFixture.reads.count == 1,"Reauthentication did not dispatch exactly one coalesced active read")
try closedFixture.reply(.active,payload:[0]);pump(1.7)
check(closedFixture.controls.isEmpty && closed.diagnostics.readTimeouts == 0,"Offline refresh sent eight doomed settings reads")
check(closedFixture.handshakes.count == 11,"Offline status caused autonomous authentication retries")
closed.stop()

// Receiver-auth and remote-device state are separate protocol messages.
let receiverFixture = SessionFixture(), receiver = DeviceSession(transport:receiverFixture)
var activeReplies = 0, diagnosticsUpdates = 0, deviceLosses = 0
var observedDiagnostics = DeviceSessionDiagnostics()
receiver.onDiagnostics = {value in
    diagnosticsUpdates += 1
    if value.lostDevice(since:observedDiagnostics) {deviceLosses += 1}
    observedDiagnostics = value
}
receiver.start();try receiverFixture.authorize(valid:true);pump(0.12)
check(receiver.diagnostics.authenticated && receiver.diagnostics.remoteActive == nil && !receiver.diagnostics.deviceResponding,"Receiver authentication claimed a responding AU05")
receiver.read(.active) {if case .success = $0 {activeReplies += 1}}
let activeRequest = receiverFixture.sent.last!
check(activeRequest.prefix(4) == Data([6,3,0x0a,1]) && activeRequest.dropFirst(4).allSatisfy{$0 == 0},"Active query differs from recovered receiver frame")
try receiverFixture.deliver([0x81,3,0x0a,0x11,0,0,0,0])
check(activeReplies == 0 && receiver.diagnostics.remoteActive == nil,"Device frame type completed a receiver query")
try receiverFixture.deliver([0x86,3,0x0a,0x01,1,0,0,0])
try receiverFixture.deliver([0x86,3,0x0a,0x10,1,0,0,0])
check(activeReplies == 0 && receiver.diagnostics.remoteActive == nil,"Rejected access/ack bits changed active state")
try receiverFixture.deliver([0x86,3,0x0a,0x11,0,0,0,0]);pump(0.05)
check(activeReplies == 1 && receiver.diagnostics.remoteActive == false && !receiver.diagnostics.deviceResponding,"Inactive receiver reply was treated as hardware ready")
receiver.read(.active) {if case .success = $0 {activeReplies += 1}}
try receiverFixture.deliver([0x86,3,0x0a,0x11,2,0,0,0]);pump(0.05)
check(activeReplies == 2 && receiver.diagnostics.remoteActive == nil && receiver.diagnostics.remoteActiveRaw == 2 && !receiver.diagnostics.deviceResponding,"Unknown active enum became an invented online state")
try receiverFixture.deliver([0x81,1,2,0x11,0,0,60,0])
check(receiver.diagnostics.deviceResponding && receiver.diagnostics.settingReplies == 2,"Valid device response was not counted")
try receiverFixture.deliver([0x8b,0x0b,0])
check(receiver.diagnostics.remoteActive == false && !receiver.diagnostics.deviceResponding,"Inactive notice retained stale ready state")
let lossesBeforeWake = deviceLosses
try receiverFixture.deliver([0x8b,0x10,0,1,0])
check(receiver.diagnostics.remoteActive == false && receiver.diagnostics.isDeviceReady,"A later real key remained blocked by an older inactive flag")
try receiverFixture.deliver([0x8b,0x0b,0])
check(!receiver.diagnostics.isDeviceReady && deviceLosses == lossesBeforeWake+1,"Repeated inactive flag after fresh input did not request key/recording cleanup")
try receiverFixture.deliver([0x8b,0x0b,1])
try receiverFixture.deliver([0x8b,0x10,0,1,0])
check(receiver.diagnostics.remoteActive == true && receiver.diagnostics.deviceResponding && receiver.diagnostics.keyReports == 2,"Wake/key notice did not restore responding evidence")
let priorReports = receiver.diagnostics.inputReports, priorDecoded = receiver.diagnostics.decodedReports
receiverFixture.onReport?(Data([0]))
check(observedDiagnostics.inputReports == priorReports+1 && observedDiagnostics.decodedReports == priorDecoded,"Observer missed an invalid incoming report before the next timeout")
receiver.read(.battery);pump(1.6)
check(receiver.diagnostics.inputReports == priorReports+1 && receiver.diagnostics.decodedReports == priorDecoded,"Invalid report counters are not distinct")
check(receiver.diagnostics.readTimeouts == 1 && diagnosticsUpdates > 0,"Timeout did not publish content-free connection diagnostics")
receiver.stop()
check(!receiver.diagnostics.authenticated && receiver.diagnostics.remoteActive == nil && !receiver.diagnostics.deviceResponding,"Disconnect retained ready evidence")

// A receiver can remain attached while its remote AU05 sleeps. A wake notice
// replenishes exactly one read-only settings batch without reconnecting USB.
func completeSettings(_ fixture:SessionFixture) throws {
    for command in DeviceCommand.refresh where command != .active {
        pump(0.06)
        check(fixture.reads.last?.prefix(4) == Data([1,command.group,command.code,1]),"Recovery changed the original settings read order: \(command.name)")
        try fixture.reply(command)
    }
    pump(0.06)
}
let recoveryFixture = SessionFixture(), recovery = DeviceSession(transport:recoveryFixture)
var forwarded:[Data] = [], losses = 0
var recoveryPrevious = DeviceSessionDiagnostics()
recovery.onEvent = {forwarded.append($0)}
recovery.onDiagnostics = {value in
    if value.lostDevice(since:recoveryPrevious) {losses += 1}
    recoveryPrevious = value
}
recovery.start()
for _ in 0..<20 {recovery.refresh()}
try recoveryFixture.authorize(valid:true);pump(0.12)
check(recoveryFixture.reads.count == 1,"Repeated refresh queued duplicate active queries")
try recoveryFixture.reply(.active,payload:[0]);pump(1.7)
check(recoveryFixture.controls.isEmpty && recovery.diagnostics.readTimeouts == 0 && !recovery.diagnostics.isDeviceReady,"USB presence made the offline AU05 ready or generated timeout traffic")
for _ in 0..<20 {try recoveryFixture.deliver([0x8b,0x0b,0])}
check(losses == 1,"Repeated inactive notices duplicated the control-loss transition")
for _ in 0..<20 {try recoveryFixture.deliver([0x8b,0x0b,1])}
check(!recovery.diagnostics.isDeviceReady,"Active=1 alone claimed settings/key response evidence")
try completeSettings(recoveryFixture)
check(recoveryFixture.controls.count == 8 && recovery.diagnostics.settingReplies == 8 && recovery.diagnostics.isDeviceReady,"Wake did not complete exactly eight settings reads")
let onlineReadCount = recoveryFixture.reads.count
for _ in 0..<20 {recovery.refresh()}
try recoveryFixture.reply(.active,payload:[1]);pump(0.06)
try completeSettings(recoveryFixture)
check(recoveryFixture.reads.count == onlineReadCount+9,"An online refresh changed its original nine-read contract or duplicated a batch")

// Loss halfway through a batch discards its queued reads and timeout. It never
// continues the old batch after a new wake generation has replaced it.
try recoveryFixture.deliver([0x8b,0x0b,0])
try recoveryFixture.deliver([0x8b,0x0b,1]);pump(0.06)
try recoveryFixture.reply(.version);pump(0.06)
check(recoveryFixture.controls.last?[2] == DeviceCommand.battery.code,"Mid-batch fixture did not reach the pending battery read")
try recoveryFixture.deliver([0x8b,0x0b,0])
let stoppedReadCount = recoveryFixture.reads.count
pump(1.7)
check(recoveryFixture.reads.count == stoppedReadCount && recovery.diagnostics.readTimeouts == 0,"Sleeping mid-refresh left old reads or timeout callbacks active")
try recoveryFixture.deliver([0x8b,0x0b,1])
try completeSettings(recoveryFixture)
check(recoveryFixture.reads.count == stoppedReadCount+8,"Wake replayed a partial obsolete batch or failed to replace it")

// A genuine key can prove remote response before the receiver's next active=1.
try recoveryFixture.deliver([0x8b,0x0b,0])
let keyWakeStart = recoveryFixture.reads.count
let originalPackets:[[UInt8]] = [[0x8b,0x10,0,1,1],[0x8b,0x10,0,0,1],
    [0x8b,0x10,0,1,2],[0x8b,0x10,0,0,2],[0x8b,0x10,0,1,3],
    [0x8b,0x10,0,0,3],[0x8b,0x10,0,0,4],[0x8b,0x10,0,1,5],
    [0x8b,0x10,0,7,0]]
let eventStart = forwarded.count
for packet in originalPackets {try recoveryFixture.deliver(packet)}
check(recovery.diagnostics.remoteActive == false && recovery.diagnostics.isDeviceReady,"A stale inactive value blocked a newer genuine key")
check(forwarded.count == eventStart+originalPackets.count && zip(forwarded.suffix(originalPackets.count),originalPackets).allSatisfy {Array($0.0.prefix($0.1.count)) == $0.1},"Recovery swallowed, duplicated or rewrote original key/rotary/unknown packets")
try completeSettings(recoveryFixture)
check(recoveryFixture.reads.count == keyWakeStart+8,"Repeated key reports created multiple recovery batches")
try recoveryFixture.deliver([0x8b,0x0b,3])
check(recovery.diagnostics.remoteActive == true && recovery.diagnostics.remoteActiveRaw == 3,"Notice flags lost their recovered bit-zero interpretation or raw value")
check(recoveryFixture.controls.allSatisfy {$0[3] & 1 == 1},"Automatic recovery performed a hardware settings write")
recovery.stop()
check(!recovery.diagnostics.isDeviceReady && recovery.diagnostics.remoteActiveRaw == nil,"Physical disconnect retained link readiness or raw status")

// Unknown/missing active capability may still be followed by actual device
// settings. Only explicit active=0 pauses the automatic settings stage.
let unavailableFixture = SessionFixture(), unavailable = DeviceSession(transport:unavailableFixture)
unavailable.start();unavailable.refresh();try unavailableFixture.authorize(valid:true);pump(1.8)
check(unavailable.diagnostics.readTimeouts == 1 && unavailableFixture.controls.count == 1,"An unanswered active query permanently blocked valid device reads")
try completeSettings(unavailableFixture)
check(unavailable.diagnostics.isDeviceReady && unavailable.diagnostics.remoteActive == nil,"Fresh settings did not restore readiness when active capability was unknown")
unavailable.stop()

var unknownSnapshot = DeviceSnapshot()
let unknownMotor = DeviceReply(decoded:Data([0x81,6,0x40,0x11,123,0,0,0]))!
let unknownMode = DeviceReply(decoded:Data([0x81,6,0x51,0x11,7,0,0,0]))!
check(unknownSnapshot.apply(unknownMotor) && unknownSnapshot.motor == 123 && unknownSnapshot.apply(unknownMode) && unknownSnapshot.audioMode == 7,"Unrecognized hardware enums were coerced into known defaults")
print("PASS: \(checks) actual DeviceSession auth/queue/timer checks; mock transport, zero HID/device writes")
