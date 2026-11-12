import Foundation

/// USB-C 接口对外供电的只读测量。
///
/// 逐个读取 `D1JV × D1JI` … `D4JV × D4JI`。已知局限：SMC 的通道编号与物理
/// 接口的对应关系未在所有机型验证；插电时输入通道本身也会被 SMC 上报，
/// 因此这里用「电压最高的通道」作为输入通道的启发式排除。
public struct PortReading: Sendable {
    public var watts: Double?
    public var channelCount: Int
    public var excludedInputChannel: Bool

    public init(watts: Double?, channelCount: Int, excludedInputChannel: Bool) {
        self.watts = watts
        self.channelCount = channelCount
        self.excludedInputChannel = excludedInputChannel
    }
}

public enum PortProbe {
    /// 低于此值视为待机，不计入接口功耗。
    static let idleFloor = 0.20
    /// 单个接口的合理上限，超过说明解码异常。
    static let saneCeiling = 120.0

    public static func read(using smc: SMC, onAC: Bool) -> PortReading {
        var rails: [(channel: Int, volts: Double, amps: Double, watts: Double)] = []

        for channel in 1...4 {
            guard let volts = smc.read("D\(channel)JV"),
                  let amps = smc.read("D\(channel)JI"),
                  volts.isFinite, amps.isFinite,
                  volts >= 0, amps >= 0 else { continue }
            let watts = volts * amps
            guard watts.isFinite, watts <= saneCeiling else { continue }
            rails.append((channel, volts, amps, watts))
        }

        guard !rails.isEmpty else {
            return PortReading(watts: nil, channelCount: 0, excludedInputChannel: false)
        }

        var excluded = false
        if onAC, let inputCandidate = rails.max(by: { $0.volts < $1.volts }) {
            rails.removeAll { $0.channel == inputCandidate.channel }
            excluded = true
        }

        let active = rails.filter { $0.watts > idleFloor }
        guard !active.isEmpty else {
            return PortReading(watts: 0, channelCount: rails.count, excludedInputChannel: excluded)
        }
        return PortReading(
            watts: active.reduce(0) { $0 + $1.watts },
            channelCount: rails.count,
            excludedInputChannel: excluded
        )
    }
}
