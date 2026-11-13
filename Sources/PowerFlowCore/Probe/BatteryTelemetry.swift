import Foundation
import IOKit
import IOKit.ps

/// 电池与适配器的只读遥测。
///
/// 主路径读 `AppleSmartBattery` 的 `PowerTelemetryData` 字典，它天然满足
/// `SystemPowerIn = SystemLoad + BatteryPower`；旧机型缺失该字典时退回
/// Voltage × Amperage 计算。
public struct BatteryReading: Sendable {
    public var installed = false
    public var onAC = false
    public var charging = false
    public var fullyCharged = false
    public var percent: Int?
    public var minutesRemaining: Int?
    public var temperature: Double?
    public var cycleCount: Int?
    public var healthPercent: Double?
    public var adapterRatedWatts: Double?
    public var adapterName: String?
    public var adapterVoltageMV: Int?
    public var adapterCurrentMA: Int?
    public var negotiatedWatts: Double?
    public var negotiatedVoltageMV: Int?
    public var negotiatedCurrentMA: Int?

    public var pInput: Double?
    public var pSystem: Double?
    public var pBattery: Double?
    public var pLoss: Double?

    public init() {}
}

public enum BatteryProbe {

    public static func read() -> BatteryReading {
        var reading = BatteryReading()
        reading.installed = false

        if let registry = registryProperties() {
            reading.installed = bool(registry["BatteryInstalled"]) ?? true
            reading.charging = bool(registry["IsCharging"]) ?? false
            reading.fullyCharged = bool(registry["FullyCharged"]) ?? false
            if let external = bool(registry["ExternalConnected"]) {
                reading.onAC = external
            }
            reading.temperature = int(registry["Temperature"]).map { Double($0) / 100 }
            reading.cycleCount = int(registry["CycleCount"])

            if let design = int(registry["DesignCapacity"]),
               let full = int(registry["AppleRawMaxCapacity"]) ?? int(registry["NominalChargeCapacity"]),
               design > 0 {
                reading.healthPercent = min(100, Double(full) / Double(design) * 100)
            }

            if let adapter = (registry["AdapterDetails"] as? [String: Any])
                ?? (registry["AppleRawAdapterDetails"] as? [[String: Any]])?.first {
                reading.adapterRatedWatts = int(adapter["Watts"]).map(Double.init)
                reading.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
                reading.adapterVoltageMV = int(adapter["AdapterVoltage"])
                reading.adapterCurrentMA = int(adapter["Current"])
            }
        }

        // 读取 USB-PD 协商档位 (Voltage / Current / Max Power)
        applyUSBPDDetails(&reading)

        // 先通过 IOPS 刷新实时的 onAC、charging、电量及剩余时间
        applyPowerSource(&reading)

        // 结合精准的供电状态计算 pBattery 与 pSystem
        if let registry = registryProperties() {
            if let telemetry = registry["PowerTelemetryData"] as? [String: Any] {
                let rawBattery = milliwatts(telemetry["BatteryPower"]).map(abs)
                if let raw = rawBattery {
                    if reading.charging {
                        reading.pBattery = raw
                    } else if !reading.onAC {
                        reading.pBattery = -raw
                    } else {
                        // 插电未充电：电池处于浮充待机。小波动归零，不把满电误报为放电
                        reading.pBattery = raw < 0.35 ? 0.0 : -raw
                    }
                }
                reading.pInput = milliwatts(telemetry["SystemPowerIn"])
                reading.pSystem = milliwatts(telemetry["SystemLoad"]).map(abs)
                reading.pLoss = milliwatts(telemetry["AdapterEfficiencyLoss"]).map(abs)
            }

            if reading.pBattery == nil,
               let volts = int(registry["Voltage"]).map({ Double($0) / 1_000 }),
               let amps = signedInt(registry["Amperage"]).map({ Double($0) / 1_000 }) {
                let magnitude = abs(volts * amps)
                if reading.charging {
                    reading.pBattery = magnitude
                } else if !reading.onAC {
                    reading.pBattery = -magnitude
                } else {
                    reading.pBattery = magnitude < 0.35 ? 0.0 : (amps < 0 ? -magnitude : magnitude)
                }
            }

            // 系统负载缺失时的兜底：放电时电池功率即系统负载；
            // 插电时用 输入 − 电池充电 反推。
            if reading.pSystem == nil {
                if !reading.onAC, let battery = reading.pBattery {
                    reading.pSystem = abs(battery)
                } else if let input = reading.pInput, let battery = reading.pBattery {
                    let charge = max(0, battery)
                    reading.pSystem = max(0, input - charge)
                }
            }
        }

        return reading
    }

    /// 公共电源 API 刷新更快，用于补充百分比、剩余时间与变压器状态。
    private static func applyPowerSource(_ reading: inout BatteryReading) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }

        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as? String {
            switch type {
            case kIOPSACPowerValue: reading.onAC = true
            case kIOPSBatteryPowerValue: reading.onAC = false
            default: break
            }
        }

        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }

            reading.installed = true
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                reading.percent = Int((Double(current) / Double(maximum) * 100).rounded())
            }
            if bool(description[kIOPSIsChargingKey]) == true {
                reading.charging = true
            }
            if reading.charging {
                reading.minutesRemaining = int(description[kIOPSTimeToFullChargeKey])
                    .flatMap { $0 > 0 ? $0 : nil }
            } else {
                reading.minutesRemaining = int(description[kIOPSTimeToEmptyKey])
                    .flatMap { $0 > 0 ? $0 : nil }
            }
            break
        }
    }

    /// 读取 USB-PD 端口协商的真实功率档位。
    private static func applyUSBPDDetails(_ reading: inout BatteryReading) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortFeaturePowerSource"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { continue }
            guard (dict["PowerSourceName"] as? String) == "USB-PD" else { continue }
            if let winning = dict["WinningPowerSourceOption"] as? [String: Any] {
                if let mv = int(winning["Voltage (mV)"]) {
                    reading.negotiatedVoltageMV = mv
                }
                if let ma = int(winning["Max Current (mA)"]) {
                    reading.negotiatedCurrentMA = ma
                }
                if let mw = int(winning["Max Power (mW)"]) {
                    reading.negotiatedWatts = Double(mw) / 1000.0
                } else if let mv = reading.negotiatedVoltageMV, let ma = reading.negotiatedCurrentMA {
                    reading.negotiatedWatts = Double(mv * ma) / 1_000_000.0
                }
                break
            }
        }
    }

    private static func registryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    /// 诊断用：把 `PowerTelemetryData` 的原始字段（mW）打出来，
    /// 便于确认各机型的符号约定。
    public static func rawTelemetry() -> [(String, Double)] {
        guard let registry = registryProperties(),
              let telemetry = registry["PowerTelemetryData"] as? [String: Any] else {
            return []
        }
        return telemetry.keys.sorted().compactMap { key in
            guard let number = telemetry[key] as? NSNumber else { return nil }
            return (key, number.doubleValue)
        }
    }

    private static func milliwatts(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite else { return nil }
        let watts = raw / 1_000
        // 无符号包装或字段缺失时会得到天文数字，直接判为不可用。
        guard abs(watts) < 1_000 else { return nil }
        return watts
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func signedInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }
}
