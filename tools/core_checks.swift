import Foundation
import VibekeyCore

func hex(_ text: String) -> Data {
    let chars = Array(text); return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
}
var checks = 0
func require(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() { fputs("FAIL: \(name)\n", stderr); exit(1) }; checks += 1
}
let version = AU05Codec.readFrame(group: 4, command: 4)
let report = try AU05Codec.outputReport(plaintext: version)
require(report == hex("5564a41cdb714dd2db3890c499a360aaad3890c499a360aaad3890c499a360aaad3890c499a360aaad3890c499a360aaad3890c499a360aaad3890c499a360aa"), "Exact SDK golden version output report")
require(AU05Codec.decodeReport(report) == version.prefix(56), "Only complete ciphertext blocks decoded")
require(AU05Codec.decodeReport(report.dropLast()) == nil, "Truncated input rejected")
var wrong = report; wrong[0] = 3
require(AU05Codec.decodeReport(wrong) == nil, "Wrong HID report ID rejected")
for size in [0, 8, 16, 56, 64] {
    let bytes = Data((0..<size).map { UInt8(($0 * 59 + 203) % 256) })
    require(AU05Codec.tea(AU05Codec.tea(bytes, decrypt: false), decrypt: true) == bytes, "TEA UInt32 overflow roundtrip")
}
var snapshot = DeviceSnapshot()
let actualReplies = [
    "810404114100002828010405012609111200000000000000000000000000000000",
    "81010211770f5000cd010000000000000000000000000000000000000000000000",
    "810190110164006400000000000000000000000000000000000000000000000000",
    "81014211100e000000000000000000000000000000000000000000000000000000",
    "810b881100000202020a020202020a020202020a020202010a020202000000000000"
]
for raw in actualReplies { require(snapshot.apply(DeviceReply(decoded: hex(raw))!), "Apply observed hardware readback") }
require(snapshot.firmware == "4.5.1", "Binary firmware version layout")
require(snapshot.batteryPercent == 80, "Battery UInt16 percent offset, not voltage")
require(snapshot.sleepSeconds == 3600, "Current sleep period")
require(snapshot.noiseReduction == 1 && snapshot.noiseLow == 100 && snapshot.noiseHigh == 100, "Noise fields preserved")
require(snapshot.lightMode == 2 && snapshot.lightBrightness == 2, "LED selector/header offsets")
require(DeviceReply(decoded: hex("8101900101640064")) == nil, "Response success gate required")
let ack = DeviceReply(decoded: hex("8101901000640064"))!
require(!snapshot.apply(ack), "ACK must not masquerade as state readback")
let negative = DeviceReply(decoded: hex("8101901101feff0080"))!
_ = snapshot.apply(negative)
require(snapshot.noiseLow == -2 && snapshot.noiseHigh == -32768, "Signed noise tuning preserved")
let noise = try DeviceControls.noiseReduction(level: 0, low: 100, high: 100)
require(noise.prefix(9) == hex("010190040064006400"), "NR setter preserves tuning and write flag")
let sleep = try DeviceControls.sleep(seconds: 3600)
let brightness = try DeviceControls.lightBrightness(20)
require(sleep.prefix(8) == hex("01014202100e0000"), "Sleep uses Int32 and flag02")
require(brightness.prefix(8) == hex("010b880402000014"), "Brightness exact selected field")
do { _ = try DeviceControls.noiseReduction(level: 2, low: 100, high: 100); require(false, "Unknown NR mode") } catch { checks += 1 }
do { _ = try DeviceControls.sleep(seconds: 60); require(false, "Other device's sleep period") } catch { checks += 1 }
do { _ = try DeviceControls.lightBrightness(21); require(false, "Out-of-range LED") } catch { checks += 1 }
require(DeviceControls.microphone(enabled: true).prefix(5) == hex("01012a0001"), "Mic setter has exact flag00")
require(DeviceControls.haptics(enabled: true).prefix(6) == hex("01064004ff00"), "Factory haptics switch uses strength255, not arbitrary intensity")
let nonce: UInt32 = 0x9fcd12a5
require(DeviceHandshake.request(challenge: nonce).prefix(9) == hex("0602050105a512cd9f"), "Handshake nonce byte order")
let masked = nonce ^ 0xd9f4e04c
var auth = Data([0x86, 2, 5, 0x11, 5]); auth.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: masked >> ($0*8)) })
require(DeviceHandshake.accepts(auth, challenge: nonce), "Matching challenge proven")
require(!DeviceHandshake.accepts(auth, challenge: nonce + 1), "Foreign challenge rejected")
auth[4] = 16
require(!DeviceHandshake.accepts(auth, challenge: nonce), "Invalid reply table index rejected")
require(DeviceHandshake.heartbeat.prefix(5) == hex("0601230001"), "Heartbeat complete payload")
require(HardwareTrigger.resolve(position: 4, status: 0)?.id == "knob.right", "Right rotation physical index")
require(HardwareTrigger.resolve(position: 5, status: 0)?.id == "knob.left", "Left rotation physical index")
require(HardwareTrigger.resolve(position: 1, status: 0)?.pressed == false, "Release cannot execute workflow")
require(HardwareTrigger.resolve(position: 31, status: 1) == nil, "Unknown input cannot execute workflow")
let defaults = InitialDeviceConfiguration.defaults
try WorkflowValidation.validate(defaults)
require(defaults.count == 6, "All physical actions initialized")
require(defaults.filter { ["key.1", "key.2", "knob.press"].contains($0.triggerID) }.allSatisfy { $0.steps.allSatisfy { $0.kind == .passthrough } }, "Unchanged base keys retain firmware routing")
require(defaults.first(where: { $0.triggerID == "key.2" })?.steps.first?.argument == "Backspace", "Current custom config, not factory Esc")
print("PASS: \(checks) protocol/handshake/current-default checks")
