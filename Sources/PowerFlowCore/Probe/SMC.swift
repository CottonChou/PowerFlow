import Foundation
import IOKit

/// 只读 AppleSMC 客户端。
///
/// 只发送 `kSMCReadKey` / `kSMCGetKeyInfo` 两个命令，从不写入任何键。
/// 需要 `IOServiceOpen` 的成功返回，但**不需要 root 权限**。
public final class SMC: @unchecked Sendable {

    private struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        /// Swift 不会给结构体末尾补对齐填充，这里显式补齐到 12 字节，
        /// 否则整个 KeyData 只有 76 字节、字段偏移全部错位。
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    /// 固定 80 字节 ABI：4 + 6 + 16 + 12 + 1 + 1 + 1 + 4 + 32。
    private struct KeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private enum Command {
        static let kernelIndex: UInt32 = 2
        static let readKey: UInt8 = 5
        static let getKeyInfo: UInt8 = 9
    }

    private var connection: io_connect_t = 0
    private var cache: [String: KeyInfo] = [:]
    private let lock = NSLock()

    public private(set) var isOpen = false
    public private(set) var statusText = "未连接"

    public init() {
        guard MemoryLayout<KeyData>.size == 80 else {
            statusText = "SMC ABI 长度异常 (\(MemoryLayout<KeyData>.size))"
            return
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            statusText = "未找到 AppleSMC"
            return
        }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            statusText = "SMC 打开失败 (\(result))"
            return
        }
        isOpen = true
        statusText = "SMC 已连接"
    }

    deinit {
        if isOpen { IOServiceClose(connection) }
    }

    /// 读取一个键并解码为瓦特 / 电压 / 电流等单位。失败返回 nil。
    public func read(_ name: String) -> Double? {
        guard isOpen, let raw = readBytes(name) else { return nil }
        return Self.decode(type: raw.type, bytes: raw.bytes)
    }

    /// 读取原始字节，供需要自行解释的键使用。
    public func readBytes(_ name: String) -> (type: String, bytes: [UInt8])? {
        guard isOpen, name.utf8.count == 4 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard let info = keyInfo(name), info.dataSize > 0, info.dataSize <= 32 else { return nil }
        var input = KeyData()
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.size

        input.key = Self.fourCC(name)
        input.keyInfo = info
        input.data8 = Command.readKey

        let result = IOConnectCallStructMethod(
            connection,
            Command.kernelIndex,
            &input,
            MemoryLayout<KeyData>.size,
            &output,
            &outputSize
        )
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }

        let count = Int(min(info.dataSize, 32))
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(count)) }
        return (Self.typeString(info.dataType), bytes)
    }

    private func keyInfo(_ name: String) -> KeyInfo? {
        if let cached = cache[name] { return cached }

        var input = KeyData()
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.size
        input.key = Self.fourCC(name)
        input.data8 = Command.getKeyInfo

        let result = IOConnectCallStructMethod(
            connection,
            Command.kernelIndex,
            &input,
            MemoryLayout<KeyData>.size,
            &output,
            &outputSize
        )
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        cache[name] = output.keyInfo
        return output.keyInfo
    }

    private static func fourCC(_ name: String) -> UInt32 {
        name.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func typeString(_ type: UInt32) -> String {
        let bytes = [
            UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// AppleSMC 的载荷是**小端**。B0AV/PDBR/PSTR 这类键按大端读会得到
    /// 荒谬的数值（例如 37 V 的电池电压），这是最容易踩的坑。
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func le16() -> UInt16? {
            guard bytes.count >= 2 else { return nil }
            return UInt16(bytes[1]) << 8 | UInt16(bytes[0])
        }
        func le32() -> UInt32? {
            guard bytes.count >= 4 else { return nil }
            return UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16
                | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        }

        switch type {
        case "flt ":
            guard let bits = le32() else { return nil }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "sp78":
            guard let raw = le16() else { return nil }
            return Double(Int16(bitPattern: raw)) / 256
        case "sp87":
            guard let raw = le16() else { return nil }
            return Double(Int16(bitPattern: raw)) / 128
        case "fp88":
            guard let raw = le16() else { return nil }
            return Double(raw) / 256
        case "fpe2":
            guard let raw = le16() else { return nil }
            return Double(raw) / 4
        case "ui16":
            return le16().map(Double.init)
        case "si16":
            return le16().map { Double(Int16(bitPattern: $0)) }
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "ui32":
            return le32().map(Double.init)
        case "si32":
            return le32().map { Double(Int32(bitPattern: $0)) }
        default:
            return nil
        }
    }
}
