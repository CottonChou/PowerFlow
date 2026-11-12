import Foundation

/// 一次采样的功率结论，以及每个数字的来源（用于诚实标注）。
public struct ResolvedPower: Sendable {
    public var pSystem: Double?
    public var pBattery: Double?
    public var pInput: Double?
    public var pDisplay: Double?
    public var pPorts: Double?
    public var source: String

    public init(pSystem: Double?, pBattery: Double?, pInput: Double?,
                pDisplay: Double?, pPorts: Double?, source: String) {
        self.pSystem = pSystem
        self.pBattery = pBattery
        self.pInput = pInput
        self.pDisplay = pDisplay
        self.pPorts = pPorts
        self.source = source
    }
}

/// 合并 SMC 与 IOPS 遥测。
///
/// 实测结论：`PowerTelemetryData` 是**缓存值**，机器负载从 45 W 拉到 53 W
/// 时它一个数字都不变；而 SMC 的 `PSTR` / `B0AV×B0AC` 每秒都在更新。
/// 所以系统负载与电池功率以 SMC 为准，遥测只用于适配器输入。
public enum PowerResolver {

    static let systemRange: ClosedRange<Double> = 0.3...400
    static let batteryRange: ClosedRange<Double> = 0.2...400

    public static func resolve(
        battery: BatteryReading,
        smc: SMC,
        displayKey: String?
    ) -> ResolvedPower {
        var notes: [String] = []

        // 1. 系统负载：PSTR 优先
        var system: Double?
        if let raw = smc.read("PSTR"), raw.isFinite, systemRange.contains(abs(raw)) {
            system = abs(raw)
            notes.append("PSTR")
        }

        // 2. 电池功率：电压 × 电流，符号由充放电状态决定
        var pack: Double?
        if let volts = smc.read("B0AV"), let amps = smc.read("B0AC"),
           // B0AV 的单位是毫伏（约 12000），不是伏。
           volts.isFinite, amps.isFinite, volts > 1_000, volts < 30_000 {
            // mV × mA = µW，除 1e6 得瓦特
            let watts = volts * amps / 1_000_000
            if watts.isFinite, batteryRange.contains(abs(watts)) {
                if battery.charging {
                    pack = abs(watts)
                } else if !battery.onAC {
                    pack = -abs(watts)
                } else {
                    // 插电未充电：处于浮充待机。小波动归零为 0.0W，只有明确协同放电才计负
                    pack = abs(watts) < 0.35 ? 0.0 : (amps < 0 ? -abs(watts) : 0.0)
                }
                notes.append("B0AV×B0AC")
            }
        }

        // 3. 回退到遥测
        if system == nil, let telemetry = battery.pSystem, systemRange.contains(abs(telemetry)) {
            system = abs(telemetry)
            notes.append("遥测SystemLoad")
        }
        if pack == nil, let telemetry = battery.pBattery, batteryRange.contains(abs(telemetry)) {
            pack = telemetry
            notes.append("遥测BatteryPower")
        }

        // 4. 放电时电池功率即系统负载
        if system == nil, let pack, pack < -0.2 {
            system = -pack
            notes.append("电池反推")
        }

        // 5. 适配器输入：遥测最可靠；缺失时用 系统 + 充电功率 推算
        var input = battery.pInput
        if let value = input, value < 0.05 { input = 0 }
        if input == nil, battery.onAC, let system {
            let charge = max(0, pack ?? 0)
            input = system + charge
            notes.append("输入推算")
        }

        // 6. 充电功率不可能超过「输入 − 系统」。SMC 的 电压×电流 在电池端测量，
        //    会比实际入电高 ~10%（含内阻损耗），这里做一次预算收敛，
        //    保证流向图与功率预算自洽。
        if battery.onAC, battery.charging, let value = pack, value > 0,
           let input, input > 0.5, let system, system > 0 {
            let available = input - system
            if available > 0.2, value > available {
                pack = available
                notes.append("充电受预算约束")
            }
        }

        let display = displayKey.flatMap { key -> Double? in
            guard let value = smc.read(key), value.isFinite, value >= 0, value < 120 else { return nil }
            return value
        }

        let ports = PortProbe.read(using: smc, onAC: battery.onAC)

        return ResolvedPower(
            pSystem: system,
            pBattery: pack,
            pInput: input,
            pDisplay: display,
            pPorts: ports.watts,
            source: notes.isEmpty ? "无可用来源" : notes.joined(separator: "+")
        )
    }
}
