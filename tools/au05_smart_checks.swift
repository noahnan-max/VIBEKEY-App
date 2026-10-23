import Foundation
import VibekeyCore

@main struct Checks {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw NSError(domain:name,code:1) }; checks += 1
    }
    @MainActor static func rejects(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }; throw NSError(domain:name,code:2)
    }
    static func baseline() throws -> AU05SmartSnapshot {
        let shortcuts = try (0..<6).map { try AU05OnboardShortcut(index:UInt8($0),entries:[.init(page:2,usage:40)]) }
        return AU05SmartSnapshot(connectionID:UUID(),firmware:"4.5.1",shortcuts:shortcuts,lightingPayload:[0,0,2,13]+Array(1...20),
            workflows:[WorkflowBinding(name:"original",triggerID:"key.2",steps:[WorkflowStep(kind:.runShortcut,argument:"NEVER_UPLOAD_PRIVATE_MACRO_847261")])],
            workflowsEnabled:false,agentLightingEnabled:true,knobPressReserved:false)
    }
    static func plan() -> AU05SmartPlan {
        AU05SmartPlan(summary:"test",keys:[.init(trigger:"key.0",keyCode:8,modifiers:0x100000)],
            macros:[.init(trigger:"key.1",name:"复制后粘贴",steps:[.init(kind:"shortcut",keyCode:8,modifiers:0x100000),.init(kind:"delay",seconds:0.3),.init(kind:"shortcut",keyCode:9,modifiers:0x100000)])],
            lighting:.init(mode:1,brightness:8))
    }
    @MainActor final class Fixture {
        var state: AU05SmartSnapshot
        var writes = 0, reads = 0, backups = 0
        var failure: String?; var injectRead = -1; var disconnected = false
        init(_ value: AU05SmartSnapshot) { state = value }
        func fail(_ kind: String) throws {
            if failure == kind { failure = nil; throw AU05ShortcutError.invalidReply }
            if failure == "disconnect" { disconnected = true; throw AU05ShortcutError.disconnected }
        }
        var adapter: AU05SmartAdapter {
            .init(read: {
                self.reads += 1
                if self.disconnected { throw AU05ShortcutError.disconnected }
                if self.reads == self.injectRead { self.state.shortcuts[5] = try self.state.shortcuts[5].replacing(entries:[.init(page:2,usage:69)]) }
                return self.state
            },writeShortcut: { value in self.writes += 1; self.state.shortcuts[Int(value.index)] = value; try self.fail("key") },writeLighting: { _, target in
                self.writes += 1; self.state.lightingPayload = target.rawPayload; try self.fail("light")
            },writeHost: { _, target in
                self.writes += 1; self.state.workflows = target.workflows; self.state.workflowsEnabled = target.workflowsEnabled; self.state.agentLightingEnabled = target.agentLightingEnabled; try self.fail("host")
            })
        }
    }
    @MainActor static func main() async throws {
        let original = try baseline(), prepared = try AU05SmartPlanner.prepare(plan(),baseline:original)
        try check(prepared.hasChanges && prepared.desired.shortcuts[0].recordedShortcut?.keyCode == 8,"Native shortcut planned")
        try check(try AU05SmartPlanner.shortcut(code:90,modifiers:nil).modifiers == 0,"An unmodified key may omit modifier bits")
        try check(prepared.desired.workflows[0] == original.workflows[0],"Untouched private macro preserved")
        try check(prepared.desired.workflows.last?.steps.count == 3 && prepared.desired.workflowsEnabled,"Host macro planned and enabled")
        try check(!prepared.desired.agentLightingEnabled && prepared.acknowledgements.count == 2,"Host/Agent switch impacts acknowledged")
        try check(try prepared.desired.lighting.workRecords == original.lighting.workRecords,"Opaque lighting preserved")
        let context = try JSONSerialization.data(withJSONObject:AU05SmartModel.context(original))
        try check(!String(decoding:context,as:UTF8.self).contains("NEVER_UPLOAD_PRIVATE_MACRO_847261") && !String(decoding:context,as:UTF8.self).contains(original.connectionID.uuidString),"No private macros or IDs sent")
        try rejects("Fn rejected") { _ = try AU05SmartPlanner.prepare(.init(summary:"x",keys:[.init(trigger:"key.0",keyCode:63,modifiers:0)]),baseline:original) }
        try rejects("Bad modifiers rejected") { _ = try AU05SmartPlanner.prepare(.init(summary:"x",keys:[.init(trigger:"key.0",keyCode:8,modifiers:0x800000)]),baseline:original) }
        try rejects("Over 4 native entries rejected") { _ = try AU05SmartPlanner.prepare(.init(summary:"x",keys:[.init(trigger:"key.0",keyCode:8,modifiers:0x1e0000)]),baseline:original) }
        try rejects("Unknown trigger rejected") { _ = try AU05SmartPlanner.prepare(.init(summary:"x",keys:[.init(trigger:"other",action:"none")]),baseline:original) }
        try rejects("Duplicate trigger rejected") { var p=plan();p.keys.append(p.keys[0]);_ = try AU05SmartPlanner.prepare(p,baseline:original) }
        try rejects("Key/macro conflict rejected") { var p=plan();p.macros[0].trigger="key.0";_ = try AU05SmartPlanner.prepare(p,baseline:original) }
        for kind in ["openApp","openURL","runShortcut","shell","inputSource"] {
            try rejects("Unsafe macro kind " + kind) { var p=plan();p.macros[0].steps=[.init(kind:kind)];_ = try AU05SmartPlanner.prepare(p,baseline:original) }
        }
        try rejects("Invalid delay rejected") { var p=plan();p.macros[0].steps=[.init(kind:"delay",seconds:31)];_ = try AU05SmartPlanner.prepare(p,baseline:original) }
        try rejects("Total delay rejected") { var p=plan();p.macros[0].steps=Array(repeating:.init(kind:"delay",seconds:30),count:3);_ = try AU05SmartPlanner.prepare(p,baseline:original) }
        try rejects("Brightness bounds") { _ = try AU05SmartPlanner.prepare(.init(summary:"x",lighting:.init(mode:1,brightness:21)),baseline:original) }
        try rejects("Work record brightness rejected") { _ = try AU05SmartPlanner.prepare(.init(summary:"x",lighting:.init(mode:2,brightness:3)),baseline:original) }
        try rejects("Unknown mode rejected") { _ = try AU05SmartPlanner.prepare(.init(summary:"x",lighting:.init(mode:4)),baseline:original) }
        try rejects("Clarification cannot write") { var p=plan();p.clarification="?";_ = try AU05SmartPlanner.prepare(p,baseline:original) }
        try rejects("Scoped macro conflict") { var s=original;s.workflowsEnabled=true;s.workflows.append(.init(name:"scope",triggerID:"key.0",applicationBundleID:"com.apple.TextEdit",steps:[.init(kind:.delay,seconds:1)]));_ = try AU05SmartPlanner.prepare(plan(),baseline:s) }
        try rejects("Wheel reservation") { var s=original;s.knobPressReserved=true;_ = try AU05SmartPlanner.prepare(.init(summary:"x",keys:[.init(trigger:"knob.press",action:"none")]),baseline:s) }
        let engine=AU05SmartTransaction(), success=Fixture(original)
        let final=try await engine.commit(expected:original,desired:prepared.desired,adapter:success.adapter) { snapshot in try check(snapshot==original && success.writes==0,"Backup precedes first write");success.backups+=1 }
        try check(final==prepared.desired && success.backups==1,"All fields read back after commit")
        let restored=try await engine.commit(expected:final,desired:original,adapter:success.adapter) { _ in success.backups+=1 }
        try check(restored==original && success.backups==2,"Restore backs up current state")
        let noBackup=Fixture(original)
        do { _ = try await engine.commit(expected:original,desired:prepared.desired,adapter:noBackup.adapter) { _ in throw AU05ShortcutError.storage };throw NSError(domain:"Backup must fail",code:1) } catch AU05ShortcutError.storage {}
        try check(noBackup.writes==0,"Backup failure zero writes")
        let stale=Fixture(original);stale.state.shortcuts[5] = try original.shortcuts[5].replacing(entries:[])
        do { _ = try await engine.commit(expected:original,desired:prepared.desired,adapter:stale.adapter) { _ in stale.backups+=1 };throw NSError(domain:"Stale must fail",code:1) } catch AU05ShortcutError.changed {}
        try check(stale.writes==0 && stale.backups==0,"Stale preview no backup/write")
        for field in ["key","light","host"] {
            let f=Fixture(original);f.failure=field
            do { _ = try await engine.commit(expected:original,desired:prepared.desired,adapter:f.adapter) { _ in f.backups+=1 };throw NSError(domain:"Partial write must fail",code:1) } catch AU05ShortcutError.restored {}
            try check(f.state==original,"Partial " + field + " failure fully restored")
        }
        let disconnected=Fixture(original);disconnected.failure="disconnect"
        do { _ = try await engine.commit(expected:original,desired:prepared.desired,adapter:disconnected.adapter) { _ in };throw NSError(domain:"Disconnect must fail",code:1) } catch AU05ShortcutError.recoveryRequired {}
        try check(disconnected.writes==1,"Disconnect unknown; no cross-connection writes")
        let concurrent=Fixture(original);concurrent.injectRead=4
        do { _ = try await engine.commit(expected:original,desired:prepared.desired,adapter:concurrent.adapter) { _ in };throw NSError(domain:"Concurrent must fail",code:1) } catch AU05ShortcutError.recoveryRequired {}
        try check(concurrent.state.shortcuts[5] != original.shortcuts[5] && concurrent.writes==1,"Unrelated edit preserved instead of blind rollback")
        let rollbackEdit=Fixture(original);rollbackEdit.failure="key";rollbackEdit.injectRead=5
        do { _ = try await engine.commit(expected:original,desired:prepared.desired,adapter:rollbackEdit.adapter) { _ in };throw NSError(domain:"Rollback concurrency must fail",code:1) } catch AU05ShortcutError.recoveryRequired {}
        try check(rollbackEdit.writes==1 && rollbackEdit.state.shortcuts[5] != original.shortcuts[5],"Recheck each rollback write against concurrent edits")
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("au05-smart-check-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let archive=AU05SmartArchive(directory:dir), backup=try archive.begin(original)
        try check(try archive.load(backup)==original,"Durable complete backup readback")
        try check((try FileManager.default.attributesOfItem(atPath:backup.path)[.posixPermissions] as? NSNumber)?.intValue==0o600,"Backup private from creation")
        try check(try archive.journal()?.phase=="pending","Crash journal survives reopen")
        try archive.finish("saved");try check(try AU05SmartArchive(directory:dir).journal()?.phase=="saved","Completed journal reopens")
        print("PASS AU05 smart configuration: \(checks) meaningful checks; physical writes 0")
    }
}
