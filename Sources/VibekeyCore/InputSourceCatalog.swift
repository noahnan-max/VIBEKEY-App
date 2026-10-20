import Foundation
import Carbon

public struct InstalledInputSource:Identifiable,Equatable,Sendable {
    public let id:String
    public let name:String
    public init(id:String,name:String) {self.id=id;self.name=name}
}

/// Selects only already enabled macOS sources. Never installs or registers one.
@MainActor public enum InputSourceCatalog {
    public static var available:[InstalledInputSource] {
        sources().compactMap {source in
            guard let id=text(source,kTISPropertyInputSourceID),let name=text(source,kTISPropertyLocalizedName) else {return nil}
            return InstalledInputSource(id:id,name:name)
        }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    public static var currentID:String? {
        guard let source=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {return nil}
        return text(source,kTISPropertyInputSourceID)
    }
    public static func select(_ id:String) async throws -> String {
        guard let source=sources().first(where:{text($0,kTISPropertyInputSourceID)==id}) else {
            throw WorkflowError.invalidConfiguration("这个输入法未启用，请先在 macOS 输入法设置中添加。")
        }
        guard TISSelectInputSource(source)==noErr else {throw WorkflowError.systemFailure("系统没有接受输入法切换。")}
        let deadline=ProcessInfo.processInfo.systemUptime+1.5
        repeat {
            try Task.checkCancellation()
            if currentID==id {return text(source,kTISPropertyLocalizedName) ?? "输入法"}
            try await Task.sleep(nanoseconds:50_000_000)
        } while ProcessInfo.processInfo.systemUptime<deadline
        throw WorkflowError.systemFailure("输入法切换已请求，但系统尚未确认。")
    }
    private static func sources()->[TISInputSource] {
        guard let result=TISCreateInputSourceList(nil,false)?.takeRetainedValue() else {return []}
        return (result as NSArray).compactMap {item in
            let source=item as! TISInputSource
            guard text(source,kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  flag(source,kTISPropertyInputSourceIsSelectCapable),flag(source,kTISPropertyInputSourceIsEnabled) else {return nil}
            return source
        }
    }
    private static func text(_ source:TISInputSource,_ key:CFString)->String? {
        guard let value=TISGetInputSourceProperty(source,key) else {return nil}
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    private static func flag(_ source:TISInputSource,_ key:CFString)->Bool {
        guard let value=TISGetInputSourceProperty(source,key) else {return false}
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}
