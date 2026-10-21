import Foundation
import Combine
import VibekeyCore

@MainActor final class RadialMenuStore:ObservableObject {
    @Published var draft:RadialMenuDocument {
        didSet { if autosaveReady, draft != oldValue { scheduleAutomaticSave() } }
    }
    @Published private(set) var configuration:RadialMenuDocument
    @Published var selectedID:UUID?
    @Published private(set) var error:String?
    @Published private(set) var isReady = true
    @Published private(set) var automaticSavePending = false
    private let directory:URL
    private let readData:(URL)throws->Data
    var fileURL:URL {directory.appendingPathComponent("radial-menu.json")}
    private var blocked = false
    private var autosaveReady = false
    private lazy var autosaver = ConfigurationAutosaver { [weak self] in _ = self?.flushAutomaticSave() }
    init(directory:URL? = nil,readData:@escaping (URL)throws->Data = {try Data(contentsOf:$0)}) {
        self.directory = (directory ?? VibekeyPaths.applicationSupport).standardizedFileURL
        self.readData = readData
        let initial = Self.defaults
        configuration = initial;draft = initial;selectedID = initial.items.first?.id
        do {
            if let saved = try read() {configuration = saved;draft = saved;selectedID = saved.items.first?.id}
            else { if !save() { configuration.enabled = false; draft.enabled = false; blocked = true; isReady = false } }
        } catch {configuration.enabled = false;draft.enabled = false;blocked = true;isReady = false;self.error = "轮盘配置未能读取，原文件已保留："+error.localizedDescription}
        autosaveReady = true
    }
    var automaticSaveMessage: String {
        if automaticSavePending { return "正在自动保存…" }
        if error != nil { return "自动保存未完成，当前修改尚未生效" }
        return "已自动保存"
    }
    private func scheduleAutomaticSave() {
        automaticSavePending = draft != configuration
        if automaticSavePending { autosaver.schedule() } else { autosaver.cancel(); if !blocked { error = nil } }
    }
    @discardableResult func flushAutomaticSave() -> Bool {
        autosaver.cancel(); automaticSavePending = false
        guard draft != configuration else { return !blocked }
        return save()
    }
    static var defaults:RadialMenuDocument {
        InitialDeviceConfiguration.radialMenu
    }
    func add() {
        guard draft.items.count < RadialMenuValidation.maximumItems else {return}
        let item = RadialMenuItem(name:"新动作",steps:[])
        draft.items.append(item);selectedID = item.id
    }
    func remove(_ id:UUID) {
        draft.items.removeAll{$0.id == id};selectedID = draft.items.first?.id
        if draft.items.isEmpty {draft.enabled = false}
    }
    func move(_ id:UUID,by delta:Int) {
        guard let i = draft.items.firstIndex(where:{$0.id == id}),draft.items.indices.contains(i+delta) else {return}
        draft.items.swapAt(i,i+delta)
    }
    func resetDraft() {draft = configuration;selectedID = configuration.items.first?.id;if !blocked {error = nil}}
    @discardableResult func save()->Bool {
        if autosaveReady { autosaver.cancel(); automaticSavePending = false }
        guard !blocked else {return false}
        let candidate = draft
        var previous:RadialMenuDocument?
        var replacementStarted = false
        do {
            let data = try RadialMenuCodec.encode(candidate)
            previous = try read()
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try validatePath()
            let temporary = directory.appendingPathComponent(".radial-\(UUID().uuidString).tmp")
            defer {try? FileManager.default.removeItem(at:temporary)}
            guard FileManager.default.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else {throw HardwareStorageError.writeFailed}
            replacementStarted = true
            if FileManager.default.fileExists(atPath:fileURL.path) {_ = try FileManager.default.replaceItemAt(fileURL,withItemAt:temporary)}
            else {try FileManager.default.moveItem(at:temporary,to:fileURL)}
            guard let readback = try read(),readback == candidate else {throw HardwareStorageError.writeFailed}
            configuration = readback;error = nil;return true
        } catch {
            if replacementStarted {
                do {
                    let readback = try read()
                    if readback == candidate {configuration = candidate;self.error = nil;return true}
                    if readback == previous {self.error = "轮盘未保存，当前配置未改变："+error.localizedDescription;return false}
                } catch { /* An unreadable file is not proof that replacement failed. */ }
                blocked = true;isReady = false
                self.error = "保存结果未能确认，轮盘已暂停。文件已保留，请重新打开 App 后检查。"
            } else {self.error = "轮盘未保存，当前配置未改变："+error.localizedDescription}
            return false
        }
    }
    private func validatePath() throws {
        var cursor = directory
        while true {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath:cursor.path)) != nil {throw HardwareStorageError.unsafePath}
            if FileManager.default.fileExists(atPath:cursor.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath:cursor.path)
                guard attrs[.type] as? FileAttributeType == .typeDirectory else {throw HardwareStorageError.unsafePath}
            }
            if cursor.path == "/" {break};cursor.deleteLastPathComponent()
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath:fileURL.path)) != nil {throw HardwareStorageError.unsafePath}
    }
    private func read() throws -> RadialMenuDocument? {
        try validatePath()
        guard FileManager.default.fileExists(atPath:fileURL.path) else {return nil}
        let attrs = try FileManager.default.attributesOfItem(atPath:fileURL.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {throw HardwareStorageError.unsafePath}
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= RadialMenuValidation.maximumDataBytes else {throw RadialMenuError.oversizedData}
        return try RadialMenuCodec.decode(readData(fileURL))
    }
}
