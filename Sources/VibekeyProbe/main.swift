import Foundation
import VibekeyCore

if CommandLine.arguments.contains("--configure-defaults") {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = support.appendingPathComponent("Vibekey/workflows.json")
    let bindings: [WorkflowBinding]
    let created: Bool
    if FileManager.default.fileExists(atPath: url.path) { bindings = try WorkflowPersistence.load(from: url); created = false }
    else { bindings = InitialDeviceConfiguration.defaults; try WorkflowPersistence.save(bindings, to: url); created = true }
    let readback = try WorkflowPersistence.load(from: url)
    guard readback == bindings else { fputs("Configuration readback mismatch\n", stderr); exit(1) }
    let receipt: [String: Any] = ["result":"PASS","created":created,"bindings":readback.count,"firmwarePassthrough":readback.allSatisfy { $0.steps.allSatisfy { $0.kind == .passthrough } },"hardwareSettingsWrites":0,"hostMacrosEnabledByDefault":false]
    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]); print(String(data: data, encoding: .utf8)!); exit(0)
}

if CommandLine.arguments.contains("--default-snapshot") {
    let session = DeviceSession()
    var snapshot = DeviceSnapshot()
    var shortcuts: [[String: Any]] = []
    var finished = false
    session.onReply = { reply in _ = snapshot.apply(reply) }
    session.onConnection = { connected, _ in
        guard connected else { return }
        for command in DeviceCommand.refresh { session.read(command) }
        let shortcut = DeviceCommand(6, 0x50, "当前硬件快捷键")
        let indices: [UInt8] = [0, 1, 2, 3, 4, 5, 110, 111, 112, 113, 114, 115]
        for index in indices {
            session.read(shortcut, payload: [index]) { result in
                if case .success(let reply) = result {
                    let p = reply.payload, count = Int(p[2])
                    if count <= 4 {
                        var entries: [[String: Int]] = []
                        for slot in 0..<count { let offset = 3 + 2 * slot; entries.append(["page":Int(p[offset] & 0x7f),"sign":Int(p[offset] >> 7),"usage":Int(p[offset + 1])]) }
                        shortcuts.append(["queriedIndex":Int(index),"returnedIndex":Int(p[0]),"entries":entries,"eventType":Int(p[11])])
                    } else { shortcuts.append(["queriedIndex":Int(index),"status":"INVALID_COUNT_REJECTED"]) }
                } else { shortcuts.append(["queriedIndex":Int(index),"status":"NO_CONFIRMED_REPLY"]) }
                if index == indices.last { finished = true }
            }
        }
    }
    session.start()
    let deadline = Date().addingTimeInterval(32)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let result: [String: Any] = ["source":"current real AU05 hardware", "settingsWrites":0, "defaultHostMacrosEnabled":false,
        "firmware":snapshot.firmware ?? "UNKNOWN", "batteryPercent":snapshot.batteryPercent as Any,
        "noiseReduction":snapshot.noiseReduction as Any,"noiseLow":snapshot.noiseLow as Any,"noiseHigh":snapshot.noiseHigh as Any,
        "sleepSeconds":snapshot.sleepSeconds as Any,"lightMode":snapshot.lightMode as Any,"lightBrightness":snapshot.lightBrightness as Any,
        "hooks":snapshot.hooks as Any,"audioMode":snapshot.audioMode as Any,"shortcuts":shortcuts]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    session.stop(); exit(finished ? 0 : 1)
}

if CommandLine.arguments.contains("--session-events") {
    let session = DeviceSession()
    var events = 0
    session.onLog = { print($0); fflush(stdout) }
    session.onConnection = { connected, message in print("connection \(connected): \(message)"); fflush(stdout); if connected { session.refresh() } }
    session.onEvent = { data in
        let b = [UInt8](data)
        if b.count >= 5, b[0] & 31 == 11 {
            events += 1; print("notice header: " + b.prefix(5).map { String(format: "%02x", $0) }.joined(separator: " ")); fflush(stdout)
        }
    }
    session.start()
    RunLoop.main.run(until: Date().addingTimeInterval(180))
    session.stop(); print("events=\(events)"); exit(0)
}

if CommandLine.arguments.contains("--roundtrip") {
    let session = DeviceSession()
    var snapshot = DeviceSnapshot()
    var receipt: [String: Any] = ["operation": "noiseReduction reversible roundtrip", "source": "real AU05 USB", "result": "INCOMPLETE"]
    var finished = false
    session.onReply = { reply in _ = snapshot.apply(reply) }
    session.onLog = { print($0) }
    func finish(_ success: Bool, _ message: String) {
        receipt["result"] = success ? "PASS" : "FAIL"; receipt["message"] = message
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        finished = true
    }
    session.onConnection = { connected, _ in
        guard connected else { return }
        session.read(.noiseReduction) { initial in
            guard case .success = initial, let original = snapshot.noiseReduction,
                  let low = snapshot.noiseLow, let high = snapshot.noiseHigh, [0, 1].contains(original) else {
                finish(false, "No valid original setting; no write attempted"); return
            }
            let wanted = 1 - original
            receipt["original"] = original; receipt["temporary"] = wanted
            func restore() {
                session.write(.noiseReduction, frame: try! DeviceControls.noiseReduction(level: original, low: low, high: high)) { ack in
                    session.read(.noiseReduction) { result in
                        let restored = snapshot.noiseReduction == original && snapshot.noiseLow == low && snapshot.noiseHigh == high
                        receipt["restored"] = restored
                        let wrote = receipt["temporaryReadback"] as? Bool == true
                        finish(restored && wrote, restored ? "Original level and both tuning parameters restored" : "Restore not confirmed")
                    }
                }
            }
            session.write(.noiseReduction, frame: try! DeviceControls.noiseReduction(level: wanted, low: low, high: high)) { result in
                if case .success = result {
                    session.read(.noiseReduction) { _ in
                        receipt["temporaryReadback"] = snapshot.noiseReduction == wanted
                        restore()
                    }
                } else { receipt["temporaryReadback"] = false; restore() }
            }
        }
    }
    session.start()
    let deadline = Date().addingTimeInterval(14)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if !finished { finish(false, "Roundtrip did not complete within the deadline") }
    session.stop()
    exit(receipt["result"] as? String == "PASS" ? 0 : 1)
}

let transport = HIDTransport()
var count = 0
let shouldRead = CommandLine.arguments.contains("--read") || CommandLine.arguments.contains("--inspect")
let fullInspect = CommandLine.arguments.contains("--inspect")
let eventMode = CommandLine.arguments.contains("--events")
transport.onConnection = { connected, message in
    print("connection \(connected): \(message)")
    if connected && shouldRead {
        let basic: [(UInt8, UInt8)] = [(0x04, 0x04), (0x01, 0x90)]
        let commands = fullInspect ? basic + [(0x01, 0x02), (0x06, 0x40), (0x01, 0x42), (0x0b, 0x89), (0x0b, 0x88), (0x06, 0x51), (0x01, 0x2a), (0x01, 0x0e), (0x01, 0x91)] : basic
        for (index, command) in commands.enumerated() {
            Timer.scheduledTimer(withTimeInterval: 0.25 + Double(index) * 0.3, repeats: false) { _ in
                do {
                    try transport.send(report: AU05Codec.outputReport(plaintext: AU05Codec.readFrame(group: command.0, command: command.1)))
                    print("query \(command.0)/\(command.1) sent")
                } catch { print("error: \(error.localizedDescription)") }
            }
        }
    }
}
transport.onReport = { report in
    count += 1
    if let decoded = AU05Codec.decodeReport(report) {
        if eventMode {
            let bytes = [UInt8](decoded)
            if bytes[0] & 0x1f == 11, bytes[1] == 0x10 {
                print("KEY logical=\(bytes[2]) status=\(bytes[3]) position=\(bytes[4])")
                fflush(stdout)
            }
        } else { print("rx[\(count)] \(report.count) decoded " + decoded.prefix(48).map { String(format: "%02x", $0) }.joined()) }
    } else { print("rx[\(count)] unrecognized length=\(report.count)") }
}
transport.start()
RunLoop.main.run(until: Date().addingTimeInterval(eventMode ? 240 : (fullInspect ? 6 : 4)))
transport.stop()
print("reports: \(count)")
