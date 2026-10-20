import Foundation

public enum VibekeyPaths {
    public static var applicationSupport:URL {
        let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
            ?? URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vibekey",isDirectory:true)
    }
}
public enum HardwareStorageError:Error,LocalizedError {
    case unsafePath,writeFailed
    public var errorDescription:String? {
        switch self {
        case .unsafePath:return "本机配置路径不可用，原文件已保留。"
        case .writeFailed:return "配置保存未能确认，原文件已保留。"
        }
    }
}
