import Foundation
import VibekeyCore

private final class Reader: CodexDesktopStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var batch = CodexDesktopStatusBatch(events: [], observedAt: Date(), sourceAvailable: true, inspectedSessions: 1, statusText: "fixture")
    private var fails = false
    func set(_ value: CodexDesktopStatusBatch, fails: Bool = false) { lock.lock(); defer { lock.unlock() }; batch = value; self.fails = fails }
    func poll(at: Date) throws -> CodexDesktopStatusBatch {
        lock.lock(); defer { lock.unlock() }
        if fails { throw AgentSignalError.invalidEvent }; return batch
    }
}
@MainActor private final class Clock { var now = Date(timeIntervalSince1970: 1_000) }
@main struct AgentDesktopMergeChecks {
    @MainActor static func main() async throws {
        var checks: [[String:Any]] = []
        func check(_ name: String, _ pass: Bool) { checks.append(["name":name,"pass":pass]) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let clock = Clock(), reader = Reader()
        let store = AgentSignalStore(directory:directory,clock:{clock.now},desktopReader:reader)
        let session = String(repeating:"a",count:64), turn = String(repeating:"b",count:64), other = String(repeating:"c",count:64)
        func event(_ id: Int, _ state: AgentSignalState, _ at: Double, _ turnHash: String? = nil, ends: Bool = false, source: AgentSignalSource = .codex, sequence: UInt64 = 1) -> AgentSignal {
            let suffix = String(id,radix:16)
            return AgentSignal(source:source,state:state,sessionHash:session,eventID:String(repeating:"0",count:64-suffix.count)+suffix,
                sequence:sequence,occurredAt:at,turnHash:turnHash,endsTurn:ends)
        }
        func inbox(_ events: [AgentSignal]) throws {
            let objects = try JSONSerialization.jsonObject(with:JSONEncoder().encode(events))
            let data = try JSONSerialization.data(withJSONObject:["schemaVersion":1,"events":objects,"completionProposedCount":0])
            let path = directory.appendingPathComponent("inbox.json"); try data.write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        func update(_ events: [AgentSignal], closures: [CodexDesktopTurnClosure] = [], fails: Bool = false) {
            reader.set(.init(events:events,observedAt:clock.now,sourceAvailable:!fails,inspectedSessions:1,statusText:"fixture",closedTurns:closures),fails:fails)
            store.refresh()
        }
        func settle() async { for _ in 0..<35 { try? await Task.sleep(nanoseconds:2_000_000) } }
        try inbox([event(1,.running,1_000,turn,sequence:1)])
        update([event(2,.running,1_000,turn,sequence:9_999_999)]); await settle()
        check("real source sequence spaces merge without starvation", store.physicalSnapshot.state == .running)
        clock.now = Date(timeIntervalSince1970:1_001)
        try inbox([event(3,.approvalRequired,1_001,turn,sequence:2)])
        update([event(2,.running,1_000,turn,sequence:9_999_999)]); await settle()
        check("new native approval outranks a large desktop sequence", [.approvalRequired,.attentionRequired].contains(store.physicalSnapshot.state) && store.physicalSnapshot.unresolvedApprovalCount == 1 && store.physicalSnapshot.selectedEventID == event(3,.approvalRequired,1_001,turn).eventID)
        clock.now = Date(timeIntervalSince1970:1_002)
        update([event(4,.running,1_002,turn)]); await settle()
        check("same turn progress never guesses approval resolution", store.physicalSnapshot.unresolvedApprovalCount == 1 && store.physicalSnapshot.state == .attentionRequired)
        clock.now = Date(timeIntervalSince1970:1_003)
        let wrong = CodexDesktopTurnClosure(sessionHash:session,turnHash:other,occurredAt:1_003,state:.turnCompleted)
        update([event(5,.turnCompleted,1_003,other,ends:true)],closures:[wrong]); await settle()
        check("another turn end never clears pending approval", store.physicalSnapshot.unresolvedApprovalCount == 1)
        clock.now = Date(timeIntervalSince1970:1_004)
        let closed = CodexDesktopTurnClosure(sessionHash:session,turnHash:turn,occurredAt:1_004,state:.turnCompleted)
        update([event(6,.turnCompleted,1_004,turn,ends:true)],closures:[closed]); await settle()
        check("exact real turn end clears its native pending and gives one end state", store.physicalSnapshot.unresolvedApprovalCount == 0 && store.physicalSnapshot.state == .turnCompleted)
        clock.now = Date(timeIntervalSince1970:1_014)
        update([],closures:[closed]); await settle()
        check("expired visual end never resurrects old native approval", store.physicalSnapshot.unresolvedApprovalCount == 0 && store.physicalSnapshot.state == nil)
        update([],fails:true); await settle()
        check("later metadata read failure cannot resurrect a proven closed request", store.physicalSnapshot.unresolvedApprovalCount == 0 && store.physicalSnapshot.state == nil)
        try inbox([event(7,.approvalRequired,1_014,other,sequence:3)])
        update([],closures:[closed]); await settle()
        check("new turn approval survives earlier turn proof", store.physicalSnapshot.unresolvedApprovalCount == 1 && [.approvalRequired,.attentionRequired].contains(store.physicalSnapshot.state))
        try inbox([event(8,.approvalRequired,1_014,nil,sequence:4)])
        update([],closures:[closed]); await settle()
        check("legacy uncorrelated approval stays conservative", store.physicalSnapshot.unresolvedApprovalCount == 1)
        try inbox([event(9,.approvalRequired,1_014,turn,source:.claude,sequence:5)])
        update([],closures:[closed]); await settle()
        check("Codex closure cannot clear a Claude approval", store.physicalSnapshot.unresolvedApprovalCount == 1 && store.physicalSnapshot.source == .claude)
        store.stop()
        let failed = checks.filter { $0["pass"] as? Bool != true }
        print(String(data:try JSONSerialization.data(withJSONObject:["status":failed.isEmpty ? "PASS":"FAIL","checks":checks,"defaultInboxWrites":0,"hardwareWrites":0],options:[.sortedKeys]),encoding:.utf8)!)
        if !failed.isEmpty { exit(1) }
    }
}
