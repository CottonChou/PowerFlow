import Foundation
import Darwin

/// 把两次采样之间的能量增量换算成平均功率，并按宿主 App 聚合。
///
/// 计数是「进程启动以来累计」的，所以第一次见到的进程只记基线、不出数，
/// 否则会把它一生累计的能量算进这 2 秒。
public final class EnergyAttributor: @unchecked Sendable {

    public struct Result: Sendable {
        public var apps: [AppUsage]
        public var measured: Bool
        public var processCount: Int
    }

    /// 旧系统拿不到 `ri_energy_nj` 时的兜底系数。
    /// 实测一个跑满的能效核约 2.3–3.2 W，性能核更高，取 3.5 W 作为折中。
    static let wattsPerBusyCore = 3.5
    static let wattsPerIOMegabyte = 0.05
    static let wattsPerWakeup = 0.0005
    /// 单进程上限，防止计数器回绕造成的假尖峰。
    static let perProcessCeiling = 200.0
    static let floorWatts = 0.02

    private var previous: [pid_t: ProcessEnergy] = [:]
    private var previousTimestamp: Date?
    private let ownPID = getpid()

    public init() {}

    public func reset() {
        previous.removeAll()
        previousTimestamp = nil
    }

    public func sample(now: Date) -> Result {
        let elapsed = previousTimestamp.map { now.timeIntervalSince($0) } ?? 0

        // 睡眠唤醒保护：如果时间间隔过长（如休眠数小时），基线已失效，重置并建立新基线
        if elapsed > 10 {
            reset()
            return sample(now: now)
        }

        let pids = EnergyProbe.allPIDs()

        var current: [pid_t: ProcessEnergy] = [:]
        current.reserveCapacity(pids.count)
        var aggregate: [String: (name: String, watts: Double, estimated: Bool, count: Int)] = [:]
        var anyMeasured = false
        var deltaCount = 0

        for pid in pids where pid != ownPID {
            guard let reading = EnergyProbe.read(pid: pid) else { continue }
            current[pid] = reading
            guard elapsed > 0.2 else { continue }

            guard let baseline = previous[pid],
                  baseline.startAbstime == reading.startAbstime else {
                continue // 首次见到或 pid 被复用：只记基线
            }

            let energyDelta = subtract(reading.energyNJ, baseline.energyNJ)
            let cpuDelta = subtract(reading.cpuNS, baseline.cpuNS)

            // 关键优化：绝大多数进程是空闲的（能耗与 CPU 增量皆为 0），直接跳过！
            // 避免每 2 秒对 1000 个无能耗进程进行昂贵的 proc_pidpath 系统调用和字符串解析
            guard energyDelta > 0 || cpuDelta > 0 else { continue }

            let watts: Double
            let estimated: Bool
            if energyDelta > 0 {
                watts = Double(energyDelta) / 1e9 / elapsed
                estimated = false
                anyMeasured = true
            } else if reading.energyNJ > 0 || baseline.energyNJ > 0 {
                // 系统支持 v6 能量记账，但本周期未产生非零焦耳增量，说明功耗极低
                watts = 0
                estimated = false
            } else {
                // 系统不支持 v6 能量记账（返回 0），退回基于 CPU/IO/Wakeup 的加权估算
                let cpuSeconds = Double(cpuDelta) / 1e9
                let ioDelta = subtract(reading.ioBytes, baseline.ioBytes)
                let wakeupDelta = subtract(reading.wakeups, baseline.wakeups)
                let ioMB = Double(ioDelta) / 1_048_576
                watts = cpuSeconds / elapsed * Self.wattsPerBusyCore
                    + ioMB / elapsed * Self.wattsPerIOMegabyte
                    + Double(wakeupDelta) / elapsed * Self.wattsPerWakeup
                estimated = true
            }

            let capped = min(max(0, watts), Self.perProcessCeiling)
            guard capped > Self.floorWatts else { continue }

            // 仅对真正产生能耗且高于阈值的少数进程（通常仅 10-30 个）解析 Identity
            guard let identity = ProcessResolver.identify(pid: pid) else { continue }
            deltaCount += 1

            if var existing = aggregate[identity.key] {
                existing.watts += capped
                existing.count += 1
                existing.estimated = existing.estimated && estimated
                aggregate[identity.key] = existing
            } else {
                aggregate[identity.key] = (identity.name, capped, estimated, 1)
            }
        }

        previous = current
        previousTimestamp = now

        let apps = aggregate
            .map { AppUsage(key: $0.key, name: $0.value.name, watts: $0.value.watts,
                            estimated: $0.value.estimated, processCount: $0.value.count) }
            .sorted { $0.watts > $1.watts }

        return Result(apps: apps, measured: anyMeasured, processCount: deltaCount)
    }

    private func subtract(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}
