import Foundation
import VibekeyCore

private struct Failure:Error {let text:String}
private func expect(_ condition:@autoclosure () throws->Bool,_ text:String)throws {if try !condition(){throw Failure(text:text)}}
private func hash(_ digit:Character)->String {String(repeating:String(digit),count:64)}
private func signal(_ state:AgentSignalState,_ sequence:UInt64,_ time:Double=100,session:String=hash("a"),source:AgentSignalSource = .codex,request:String?=nil,resolves:String?=nil,simulation:Bool=false)->AgentSignal {
    AgentSignal(source:source,state:state,sessionHash:session,eventID:String(format:"%064x",sequence),sequence:sequence,occurredAt:time,simulation:simulation,requestHash:request,resolvesRequestHash:resolves)
}
@main struct AgentSignalChecks {
    @MainActor static func main() throws {
        guard let argument=CommandLine.arguments.first(where:{$0.hasPrefix("--directory=")}) else {throw Failure(text:"missing owned directory")}
        let directory=URL(fileURLWithPath:String(argument.dropFirst("--directory=".count)))
        var rows:[[String:Any]]=[]
        func check(_ name:String,_ action:()throws->Void){do{try action();rows.append(["name":name,"status":"PASS"])}catch{rows.append(["name":name,"status":"FAIL","error":String(describing:error)])}}
        let now=Date(timeIntervalSince1970:100)
        check("default is unknown, not finished") {try expect(AgentSignalAggregator().snapshot(at:now).state == nil,"default state")}
        check("pre-commit Stop stays tentative and never becomes completion by timeout") {
            var a=AgentSignalAggregator();try a.ingest(signal(.stopProposed,1),now:now)
            try expect(a.snapshot(at:now).state == .stopProposed,"Stop lost tentative identity")
            try expect(a.snapshot(at:Date(timeIntervalSince1970:108)).state == nil,"timeout inferred success")
            try a.ingest(signal(.turnCompleted,2,101,session:hash("b")),now:Date(timeIntervalSince1970:101))
            try expect(a.snapshot(at:Date(timeIntervalSince1970:101)).state == .turnCompleted,"tentative Stop masked confirmed independent completion")
        }
        check("turn completion expires without polling extending it") {
            var a=AgentSignalAggregator();let e=signal(.turnCompleted,1)
            try a.ingest(e,now:now);try expect(a.snapshot(at:now).state == .turnCompleted,"turn missing")
            try expect(!a.ingest(e,now:Date(timeIntervalSince1970:107)),"duplicate accepted")
            try expect(a.snapshot(at:Date(timeIntervalSince1970:108)).state == nil,"completion extended")
        }
        check("future, old sequence and old time cannot overwrite state") {
            var a=AgentSignalAggregator();try a.ingest(signal(.running,2),now:now)
            try expect(!a.ingest(signal(.turnCompleted,3,101),now:now),"future accepted")
            try expect(!a.ingest(signal(.turnCompleted,1,100),now:now),"old sequence accepted")
            try expect(!a.ingest(signal(.turnCompleted,4,99),now:now),"old time accepted")
            try expect(a.snapshot(at:now).state == .running,"state changed")
        }
        check("ended session cannot relight on late events") {
            var a=AgentSignalAggregator();try a.ingest(signal(.ended,2),now:now)
            try expect(!a.ingest(signal(.turnCompleted,3,101),now:Date(timeIntervalSince1970:101)),"ended relit")
            try expect(a.snapshot(at:now).state == nil,"ended lit")
        }
        check("A approval outranks another session B completion") {
            var a=AgentSignalAggregator();try a.ingest(signal(.approvalRequired,1,request:hash("b")),now:now)
            try a.ingest(signal(.turnCompleted,2,session:hash("c")),now:now)
            try expect(a.snapshot(at:now).state == .approvalRequired,"B masked A")
        }
        check("B tool receipt and late Stop do not resolve A approval") {
            var a=AgentSignalAggregator();try a.ingest(signal(.approvalRequired,1,request:hash("b")),now:now)
            try a.ingest(signal(.running,2,100,resolves:hash("c")),now:now)
            try a.ingest(signal(.turnCompleted,3),now:now)
            let state=a.snapshot(at:now)
            try expect(state.state == .attentionRequired && state.unresolvedApprovalCount == 1,"unrelated event cleared approval")
        }
        check("only exact explicit resolution can clear known request") {
            var a=AgentSignalAggregator();try a.ingest(signal(.approvalRequired,1,request:hash("b")),now:now)
            try a.ingest(signal(.running,2,resolves:hash("b")),now:now)
            try expect(a.snapshot(at:now).state == .running && a.snapshot(at:now).unresolvedApprovalCount == 0,"known resolution failed")
        }
        check("expired A approval does not mask fresh B turn, while A stays unknown") {
            var a=AgentSignalAggregator();try a.ingest(signal(.approvalRequired,1),now:now)
            let late=Date(timeIntervalSince1970:401)
            try a.ingest(signal(.turnCompleted,2,401,session:hash("c")),now:late)
            let state=a.snapshot(at:late)
            try expect(state.state == .turnCompleted && state.selectedEventID == signal(.turnCompleted,2).eventID && state.unresolvedApprovalCount == 1 && state.staleSessionCount == 1,"stale A masked B or was dropped")
            try a.ingest(signal(.turnCompleted,3,401),now:late)
            try expect(a.snapshot(at:late).selectedEventID == state.selectedEventID,"A Stop cleared its own approval")
            try expect(a.snapshot(at:Date(timeIntervalSince1970:409)).state == nil,"A Stop became completion after B expired")
        }
        check("unknown approval deliveries stay separate without relighting or extending TTL") {
            var a=AgentSignalAggregator();let first=signal(.approvalRequired,1)
            try a.ingest(first,now:now)
            let initial=a.snapshot(at:now)
            try expect(initial.state == .attentionRequired,"uncorrelated approval pretended resolved identity")
            try a.ingest(signal(.approvalRequired,2,200),now:Date(timeIntervalSince1970:200))
            let second=a.snapshot(at:Date(timeIntervalSince1970:200))
            try expect(second.unresolvedApprovalCount == 2 && second.selectedEventID == initial.selectedEventID,"unknown deliveries merged or warning identity reset")
            try expect(a.snapshot(at:Date(timeIntervalSince1970:400)).state == nil,"later unknown delivery prolonged warning")
            try a.ingest(signal(.approvalRequired,3,401),now:Date(timeIntervalSince1970:401))
            try expect(a.snapshot(at:Date(timeIntervalSince1970:401)).state == nil,"late uncorrelated replay relit warning")
        }
        check("selected event identity does not change with unrelated session metadata") {
            var a=AgentSignalAggregator();let completed=signal(.turnCompleted,1)
            try a.ingest(completed,now:now)
            let initial=a.snapshot(at:now)
            try a.ingest(signal(.running,2,101,session:hash("b")),now:Date(timeIntervalSince1970:101))
            let next=a.snapshot(at:Date(timeIntervalSince1970:101))
            try expect(next.selectedEventID == initial.selectedEventID && next.state == initial.state,"completion relight identity changed")
            try expect(next.lastEventAt != initial.lastEventAt && next.activeSessionCount == 2,"test did not change independent metadata")
        }
        check("session end explicitly clears its approvals") {
            var a=AgentSignalAggregator();try a.ingest(signal(.approvalRequired,1),now:now);try a.ingest(signal(.ended,2),now:now)
            try expect(a.snapshot(at:now).unresolvedApprovalCount == 0,"end retained approval")
        }
        check("real TaskCompleted proposal is never accepted as committed") {
            do {try signal(.taskCompleted,1,source:.claude).validate();throw Failure(text:"proposal accepted")}
            catch is AgentSignalError {}
            try signal(.taskCompleted,1,source:.claude,simulation:true).validate()
        }
        check("unknown JSON fields with raw messages are rejected") {
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(signal(.running,1))) as! [String:Any]
            object["prompt"]="SYNTHETIC_PRIVATE_TEXT"
            do {_ = try JSONDecoder().decode(AgentSignal.self,from:JSONSerialization.data(withJSONObject:object));throw Failure(text:"unknown raw field accepted")}
            catch is AgentSignalError {}
        }
        var clock=now
        let files=FileManager.default
        func inbox(_ name:String,_ events:[AgentSignal])throws->URL {
            let root=directory.appendingPathComponent(name);try files.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(events))
            let data=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"events":encoded,"completionProposedCount":0])
            let path=root.appendingPathComponent("inbox.json");files.createFile(atPath:path.path,contents:data,attributes:[.posixPermissions:0o600]);return root
        }
        check("missing private inbox causes no physical signal or file creation") {
            let absent=directory.appendingPathComponent("absent")
            let store=AgentSignalStore(directory:absent,clock:{clock});store.refresh()
            try expect(store.physicalSnapshot.state == nil && !files.fileExists(atPath:absent.path),"default side effects")
        }
        check("simulation never changes physical state or real source connection") {
            let absent=directory.appendingPathComponent("simulation")
            let store=AgentSignalStore(directory:absent,clock:{clock});store.refresh();let physical=store.physicalSnapshot
            store.simulate(state:.turnCompleted)
            try expect(store.snapshot.isSimulation && store.snapshot.state == .turnCompleted,"simulation missing")
            try expect(store.physicalSnapshot == physical && store.lastEvents.isEmpty,"simulation became real")
            clock=Date(timeIntervalSince1970:109);store.refresh()
            try expect(store.snapshot.state == nil && store.physicalSnapshot.state == nil,"simulation did not expire")
            clock=now
        }
        check("real expiry still clears during simulation") {
            let root=try inbox("expiry",[signal(.turnCompleted,1)])
            let store=AgentSignalStore(directory:root,clock:{clock});store.refresh();store.simulate(state:.approvalRequired)
            try expect(store.physicalSnapshot.state == .turnCompleted && !store.physicalSnapshot.isSimulation,"real state changed")
            clock=Date(timeIntervalSince1970:109);store.refresh()
            try expect(store.physicalSnapshot.state == nil,"real completion kept by simulation")
            clock=now
        }
        check("approval and Stop survive cold inbox reconstruction conservatively") {
            let root=try inbox("pending",[signal(.approvalRequired,1),signal(.turnCompleted,2)])
            let store=AgentSignalStore(directory:root,clock:{clock});store.refresh()
            try expect(store.physicalSnapshot.state == .attentionRequired,"restart lost pending approval")
            store.simulate(state:.turnCompleted)
            try expect(store.physicalSnapshot.state == .attentionRequired && !store.physicalSnapshot.isSimulation,"simulation cleared pending")
            store.stop();try expect(store.physicalSnapshot.state == nil,"stop retained physical state")
        }
        check("bridge failure marker clears physical status and blocks simulation") {
            let root=try inbox("bridge-error",[signal(.running,1)])
            let store=AgentSignalStore(directory:root,clock:{clock});store.refresh()
            files.createFile(atPath:root.appendingPathComponent("bridge-error.json").path,contents:Data("{}".utf8),attributes:[.posixPermissions:0o600])
            store.refresh();store.simulate(state:.turnCompleted)
            try expect(store.errorMessage != nil && store.physicalSnapshot.state == nil && store.snapshot.state == nil,"failure turned green")
        }
        check("unsafe permissions, symlink and malformed inbox fail closed") {
            let root=try inbox("unsafe",[signal(.running,1)])
            let path=root.appendingPathComponent("inbox.json");try files.setAttributes([.posixPermissions:0o644],ofItemAtPath:path.path)
            let store=AgentSignalStore(directory:root,clock:{clock});store.refresh()
            try expect(store.errorMessage != nil && store.physicalSnapshot.state == nil,"permissions accepted")
            try files.removeItem(at:path);try files.createSymbolicLink(at:path,withDestinationURL:directory.appendingPathComponent("missing"))
            store.refresh();try expect(store.errorMessage != nil,"symlink accepted")
            try files.removeItem(at:path);files.createFile(atPath:path.path,contents:Data("invalid".utf8),attributes:[.posixPermissions:0o600])
            store.refresh();try expect(store.errorMessage != nil,"bad JSON accepted")
        }
        let failed=rows.filter{$0["status"] as? String != "PASS"}.count
        let report:[String:Any]=["status":failed==0 ? "PASS":"FAIL","checks":rows.count,"passed":rows.count-failed,"failed":failed,"cases":rows,
            "realHooksInstalled":false,"realTasksObserved":false,"GUIShown":false,"HIDOpened":false,"networkCalled":false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]));exit(failed==0 ? 0:1)
    }
}
