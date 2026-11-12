import Foundation
import Darwin

/// 单个进程的累计能量与辅助计数（自进程启动起累加）。
public struct ProcessEnergy: Sendable, Hashable {
    public var energyNJ: UInt64
    public var cpuNS: UInt64
    public var wakeups: UInt64
    public var ioBytes: UInt64
    /// 用于识别 pid 复用：同一 pid 但起始时间不同即为新进程。
    public var startAbstime: UInt64
}

public enum EnergyProbe {

    /// `ri_user_time` / `ri_system_time` 在 Apple Silicon 上以 mach 绝对时钟
    /// tick 计（24 MHz），不是文档字面写的纳秒。必须经 timebase 换算，
    /// 否则 CPU 时间会被低估约 8 倍。
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        guard timebase.denom != 0 else { return ticks }
        return ticks &* timebase.numer / timebase.denom
    }

    /// `proc_pid_rusage` 的 `RUSAGE_INFO_V6` 提供 `ri_energy_nj`，
    /// 与活动监视器「能耗影响」同源，且不需要 root。
    public static func read(pid: pid_t) -> ProcessEnergy? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }

        if status == 0 {
            return ProcessEnergy(
                energyNJ: info.ri_energy_nj,
                cpuNS: nanoseconds(fromTicks: info.ri_user_time &+ info.ri_system_time),
                wakeups: info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups,
                ioBytes: info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten,
                startAbstime: info.ri_proc_start_abstime
            )
        }

        // 旧系统可能没有 v6，退回 v4 拿到 CPU / wakeup / IO 字段。
        var legacy = rusage_info_v4()
        let legacyStatus = withUnsafeMutablePointer(to: &legacy) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard legacyStatus == 0 else { return nil }
        return ProcessEnergy(
            energyNJ: 0,
            cpuNS: nanoseconds(fromTicks: legacy.ri_user_time &+ legacy.ri_system_time),
            wakeups: legacy.ri_pkg_idle_wkups &+ legacy.ri_interrupt_wkups,
            ioBytes: legacy.ri_diskio_bytesread &+ legacy.ri_diskio_byteswritten,
            startAbstime: legacy.ri_proc_start_abstime
        )
    }

    public static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written))).filter { $0 > 0 }
    }
}
