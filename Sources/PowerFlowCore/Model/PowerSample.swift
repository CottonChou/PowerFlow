import Foundation

/// 单个 App 在某个采样窗口内的平均功耗。
public struct AppUsage: Identifiable, Codable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let watts: Double
    /// true 表示该值来自 cpu/wakeup/io 加权估算，而非内核能量记账。
    public let estimated: Bool
    public let processCount: Int

    public var id: String { key }

    public init(key: String, name: String, watts: Double, estimated: Bool, processCount: Int) {
        self.key = key
        self.name = name
        self.watts = watts
        self.estimated = estimated
        self.processCount = processCount
    }
}

/// 一次 2 秒采样的完整功率快照。
///
/// 单位统一为瓦特（W）。`pBattery` 遵循「正数进电池、负数出电池」的约定，
/// 与 `PowerTelemetryData.BatteryPower` 一致。
public struct PowerSample: Identifiable, Sendable {
    public let ts: Date
    public let onAC: Bool
    public let charging: Bool
    public let batteryPercent: Int?
    public let batteryMinutes: Int?
    public let batteryTemperature: Double?
    public let batteryCycleCount: Int?
    public let batteryHealthPercent: Double?
    public let adapterRatedWatts: Double?
    public let adapterName: String?
    public let adapterNegotiatedWatts: Double?
    public let adapterNegotiatedVoltageMV: Int?
    public let adapterNegotiatedCurrentMA: Int?
    public let pInput: Double?
    public let pSystem: Double?
    public let pBattery: Double?
    public let pDisplay: Double?
    public let pPorts: Double?
    public let apps: [AppUsage]

    public var id: Date { ts }

    public init(
        ts: Date,
        onAC: Bool,
        charging: Bool,
        batteryPercent: Int?,
        batteryMinutes: Int?,
        batteryTemperature: Double? = nil,
        batteryCycleCount: Int? = nil,
        batteryHealthPercent: Double? = nil,
        adapterRatedWatts: Double? = nil,
        adapterName: String? = nil,
        adapterNegotiatedWatts: Double? = nil,
        adapterNegotiatedVoltageMV: Int? = nil,
        adapterNegotiatedCurrentMA: Int? = nil,
        pInput: Double?,
        pSystem: Double?,
        pBattery: Double?,
        pDisplay: Double?,
        pPorts: Double?,
        apps: [AppUsage]
    ) {
        self.ts = ts
        self.onAC = onAC
        self.charging = charging
        self.batteryPercent = batteryPercent
        self.batteryMinutes = batteryMinutes
        self.batteryTemperature = batteryTemperature
        self.batteryCycleCount = batteryCycleCount
        self.batteryHealthPercent = batteryHealthPercent
        self.adapterRatedWatts = adapterRatedWatts
        self.adapterName = adapterName
        self.adapterNegotiatedWatts = adapterNegotiatedWatts
        self.adapterNegotiatedVoltageMV = adapterNegotiatedVoltageMV
        self.adapterNegotiatedCurrentMA = adapterNegotiatedCurrentMA
        self.pInput = pInput
        self.pSystem = pSystem
        self.pBattery = pBattery
        self.pDisplay = pDisplay
        self.pPorts = pPorts
        self.apps = apps
    }

    /// 充电功率（仅当确实在充入时非空）。
    public var chargePower: Double? {
        guard let pBattery, pBattery > 0.05 else { return nil }
        return pBattery
    }

    /// 放电功率（仅当确实在放出时非空，返回正值）。
    public var dischargePower: Double? {
        guard let pBattery, pBattery < -0.05 else { return nil }
        return -pBattery
    }

    /// 已归因 App 的功率合计。
    public var attributed: Double {
        apps.reduce(0) { $0 + $1.watts }
    }

    /// 系统负载扣除屏幕、接口、App 之后的残差。物理上必然 >= 0。
    public var residual: Double? {
        guard let pSystem else { return nil }
        return max(0, pSystem - attributed - (pDisplay ?? 0) - (pPorts ?? 0))
    }

    /// 归因覆盖率 = 已归因 / 可归因分母。用于判断该窗口数据可信度。
    public var coverage: Double? {
        guard let pSystem else { return nil }
        let denominator = pSystem - (pDisplay ?? 0) - (pPorts ?? 0)
        guard denominator > 0.05 else { return nil }
        return min(1, attributed / denominator)
    }

    /// 当前采样点是否处于「未充电的插电状态」。
    public var isIdleOnAC: Bool {
        onAC && chargePower == nil
    }

    /// 判断是否处于「供电瓶颈 / 倒贴放电」状态（插着电源但输入功率不足以支撑整机负载，电池被迫放电）。
    public var isUnderpowered: Bool {
        guard onAC,
              let battery = pBattery, battery < -0.35,
              let input = pInput,
              let load = pSystem,
              input + 0.35 < load else {
            return false
        }
        return true
    }

    /// 适配器及 USB-PD 规格摘要（如 "100W · 20V/5.0A" 或 "Apple 96W"）。
    public var adapterSummary: String? {
        guard onAC else { return nil }
        var parts: [String] = []
        if let rated = adapterRatedWatts, rated > 0 {
            parts.append(String(format: "%.0fW", rated))
        } else if let neg = adapterNegotiatedWatts, neg > 0 {
            parts.append(String(format: "%.0fW", neg))
        }
        if let v = adapterNegotiatedVoltageMV, let a = adapterNegotiatedCurrentMA, v > 0, a > 0 {
            let volts = Double(v) / 1000.0
            let amps = Double(a) / 1000.0
            parts.append(String(format: "%.0fV/%.1fA", volts, amps))
        }
        guard !parts.isEmpty else {
            return adapterName
        }
        let spec = parts.joined(separator: " · ")
        if let name = adapterName, !name.isEmpty, name != "pd charger" {
            return "\(name) · \(spec)"
        }
        return spec
    }
}

/// 趋势图的一条数据带。
public enum PowerBand: String, CaseIterable, Sendable {
    case apps
    case display
    case ports
    case residual

    public var title: String {
        switch self {
        case .apps: "已归因 App"
        case .display: "屏幕"
        case .ports: "USB-C"
        case .residual: "未归因"
        }
    }

    public func value(in sample: PowerSample) -> Double {
        switch self {
        case .apps: sample.attributed
        case .display: sample.pDisplay ?? 0
        case .ports: sample.pPorts ?? 0
        case .residual: sample.residual ?? 0
        }
    }
}

/// 把样本摊平成 Swift Charts 需要的长格式。
public struct BandPoint: Identifiable, Sendable {
    public let ts: Date
    public let band: PowerBand
    public let watts: Double
    public var id: String { "\(ts.timeIntervalSince1970)-\(band.rawValue)" }

    public init(ts: Date, band: PowerBand, watts: Double) {
        self.ts = ts
        self.band = band
        self.watts = watts
    }
}

public enum TrendRange: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes
    case thirtyMinutes
    case sixHours
    case oneDay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fiveMinutes: "5 分钟"
        case .thirtyMinutes: "30 分钟"
        case .sixHours: "6 小时"
        case .oneDay: "24 小时"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: 300
        case .thirtyMinutes: 1_800
        case .sixHours: 21_600
        case .oneDay: 86_400
        }
    }
}
