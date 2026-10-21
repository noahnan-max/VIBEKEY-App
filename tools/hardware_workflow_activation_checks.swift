import Foundation
import VibekeyCore

@main @MainActor struct WorkflowActivationChecks {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hardware-workflow-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=WorkflowStore(directory:root);var checks=0
        func check(_ value:Bool,_ name:String) {guard value else {fatalError(name)};checks += 1}
        check(store.bindings==store.activeBindings && store.activeBindings.count==6,"Initial saved defaults")
        store.enabled=true
        let initialActive=store.customBinding(for:"key.0",applicationBundleID:"")
        store.bindings[0].steps=[WorkflowStep(kind:.shortcut,keyCode:8,modifiers:0x100000)]
        check(store.hasUnsavedChanges && store.customBinding(for:"key.0",applicationBundleID:"")==initialActive,"Draft affected a live key")
        store.save();check(!store.hasUnsavedChanges && store.customBinding(for:"key.0",applicationBundleID:"")?.steps[0].keyCode==8,"Saved binding not activated")
        let saved=store.activeBindings,bytes=try Data(contentsOf:root.appendingPathComponent("workflows.json"))
        store.bindings[0].steps[0].keyCode=255;store.save()
        let unchanged=try Data(contentsOf:root.appendingPathComponent("workflows.json"))
        check(store.error != nil && store.activeBindings==saved && unchanged==bytes,"Failed save changed active configuration")
        store.bindings=saved
        store.bindings.append(WorkflowBinding(name:"Application",triggerID:"key.0",applicationBundleID:"com.example.editor",steps:[WorkflowStep(kind:.shortcut,keyCode:9)]))
        check(store.customBinding(for:"key.0",applicationBundleID:"com.example.editor")?.steps[0].keyCode==8,"Unsaved application scope became active")
        store.save();check(store.customBinding(for:"key.0",applicationBundleID:"com.example.editor")?.steps[0].keyCode==9,"Application-specific saved scope missing")
        store.enabled=false;check(store.customBinding(for:"key.0",applicationBundleID:"com.example.editor")==nil,"Disabled mapping still active")
        let reopened=WorkflowStore(directory:root);check(reopened.activeBindings==store.activeBindings,"Reopen changed saved configuration")
        reopened.bindings[0].steps=[WorkflowStep(kind:.shortcut,keyCode:8,modifiers:0x100000)]
        check(reopened.save(enableCustomActions:true) && reopened.enabled && reopened.activeBindings==reopened.bindings,"Save and enable did not wait for persistence")
        reopened.enabled=false
        let beforeFailure=reopened.activeBindings
        reopened.bindings[0].steps[0].keyCode=255
        check(!reopened.save(enableCustomActions:true) && !reopened.enabled && reopened.activeBindings==beforeFailure,"Invalid draft enabled actions or changed active bindings")
        let broken=root.appendingPathComponent("broken");try FileManager.default.createDirectory(at:broken,withIntermediateDirectories:true)
        let raw=Data("broken configuration".utf8);try raw.write(to:broken.appendingPathComponent("workflows.json"))
        let damaged=WorkflowStore(directory:broken)
        check(!damaged.save(enableCustomActions:true) && !damaged.enabled,"Unreadable configuration was enabled")
        check(try Data(contentsOf:broken.appendingPathComponent("workflows.json"))==raw,"Damaged file was overwritten")
        let report:[String:Any]=["status":"PASS","checks":checks,"realUserDataTouched":false,"systemActionsExecuted":0]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted),as:UTF8.self))
    }
}
