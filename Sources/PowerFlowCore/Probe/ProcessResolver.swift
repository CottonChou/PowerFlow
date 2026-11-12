import Foundation
import Darwin

/// 把 pid 映射到「用户认知里的 App」。
///
/// Chrome 的十几个 renderer、Electron 的 helper 都必须归到宿主 App，
/// 否则排行榜会被进程名切碎。
public enum ProcessResolver {

    public struct Identity: Sendable, Hashable {
        public let key: String
        public let name: String
    }

    public static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func identify(pid: pid_t) -> Identity? {
        if let full = path(of: pid), let identity = identity(fromPath: full) {
            return identity
        }
        if let name = name(of: pid), !name.isEmpty {
            return Identity(key: "proc:" + name, name: name)
        }
        return nil
    }

    /// 从可执行文件路径推导宿主 App。
    ///
    /// `…/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/…`
    /// → `Google Chrome`
    public static func identity(fromPath path: String) -> Identity? {
        // 取最外层的 .app：嵌套的 Helper.app 必须归到宿主 App。
        guard let range = path.range(of: ".app/") else {
            // 普通命令行程序：用可执行名。
            let executable = (path as NSString).lastPathComponent
            guard !executable.isEmpty else { return nil }
            return Identity(key: "bin:" + path, name: executable)
        }
        let bundlePath = String(path[path.startIndex..<range.lowerBound]) + ".app"
        let name = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return Identity(key: "app:" + bundlePath, name: name.isEmpty ? "未知" : name)
    }
}
