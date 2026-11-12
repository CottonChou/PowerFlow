import Foundation
import PowerFlowCore

// 终端诊断入口：不开 UI，直接把采样层的结果打出来，
// 用于和活动监视器 / powermetrics 对照。

let arguments = CommandLine.arguments
let rounds = arguments.firstIndex(of: "--rounds")
    .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 3

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func fmt(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "    —" }
    return String(format: "%5.2f", value)
}

let smc = SMC()
print("SMC: \(smc.statusText)")
if arguments.contains("--dump") {
    for key in ["PDTR", "PSTR", "PDBR", "PBwo", "PBLR", "B0AV", "B0AC", "TB0T",
                "D1JV", "D1JI", "D2JV", "D2JI", "CHTE", "CHIE"] {
        if let raw = smc.readBytes(key) {
            let hex = raw.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("  \(key) [\(raw.type)] len=\(raw.bytes.count) \(hex)  → \(fmt(smc.read(key)))")
        } else {
            print("  \(key) 读取失败")
        }
    }
    exit(0)
}
if arguments.contains("--battery") {
    let reading = BatteryProbe.read()
    print("installed=\(reading.installed) onAC=\(reading.onAC) charging=\(reading.charging) full=\(reading.fullyCharged)")
    print("percent=\(reading.percent.map(String.init) ?? "-") minutes=\(reading.minutesRemaining.map(String.init) ?? "-") temp=\(fmt(reading.temperature)) cycles=\(reading.cycleCount.map(String.init) ?? "-") health=\(fmt(reading.healthPercent))")
    print("pInput=\(fmt(reading.pInput)) pSystem=\(fmt(reading.pSystem)) pBattery=\(fmt(reading.pBattery)) pLoss=\(fmt(reading.pLoss))")
    print("raw PowerTelemetryData:")
    for (key, value) in BatteryProbe.rawTelemetry() {
        print("  \(key) = \(String(format: "%.1f", value)) mW")
    }
    exit(0)
}
for key in ["PDTR", "PSTR", "PDBR", "PBwo", "PBLR", "B0AV", "B0AC", "TB0T"] {
    print("  \(key) = \(fmt(smc.read(key)))")
}

if arguments.contains("--energy") {
    var before: [pid_t: ProcessEnergy] = [:]
    for pid in EnergyProbe.allPIDs() {
        if let e = EnergyProbe.read(pid: pid) { before[pid] = e }
    }
    let t0 = Date()
    Thread.sleep(forTimeInterval: 2)
    let elapsed = Date().timeIntervalSince(t0)

    var rows: [(String, Double, Double)] = []
    for pid in EnergyProbe.allPIDs() {
        guard let e = EnergyProbe.read(pid: pid),
              let b = before[pid], b.startAbstime == e.startAbstime else { continue }
        let energyDelta = Double(e.energyNJ >= b.energyNJ ? e.energyNJ - b.energyNJ : 0)
        let cpuDelta = Double(e.cpuNS >= b.cpuNS ? e.cpuNS - b.cpuNS : 0)
        let name = ProcessResolver.identify(pid: pid)?.name ?? "pid\(pid)"
        rows.append((name, energyDelta / 1e9 / elapsed, cpuDelta / 1e9 / elapsed * 6.5))
    }
    print("样本进程 \(rows.count)  能量增量非零 \(rows.filter { $0.1 > 0 }.count)  间隔 \(String(format: "%.2f", elapsed))s")
    print("能量法合计 \(fmt(rows.reduce(0) { $0 + $1.1 })) W   CPU估算法合计 \(fmt(rows.reduce(0) { $0 + $1.2 })) W")
    print("--- 按能量排序 ---")
    for row in rows.sorted(by: { $0.1 > $1.1 }).prefix(12) {
        print("  \(pad(row.0, 24)) E=\(fmt(row.1)) W   CPU=\(fmt(row.2)) W")
    }
    print("--- 按 CPU 估算排序 ---")
    for row in rows.sorted(by: { $0.2 > $1.2 }).prefix(8) {
        print("  \(pad(row.0, 24)) E=\(fmt(row.1)) W   CPU=\(fmt(row.2)) W")
    }
    exit(0)
}

let displayKey = ["PDBR", "PBwo", "PBLR"].first { smc.read($0) != nil }
let attributor = EnergyAttributor()
var lastTime = Date()

for round in 1...max(1, rounds) {
    let now = Date()
    let battery = BatteryProbe.read()
    let resolved = PowerResolver.resolve(battery: battery, smc: smc, displayKey: displayKey)
    let energy = attributor.sample(now: now)

    print("")
    print("── 采样 #\(round)  间隔 \(String(format: "%.2f", now.timeIntervalSince(lastTime)))s")
    print("  电源: \(battery.onAC ? "插电" : "电池") \(battery.charging ? "充电中" : "")  电量 \(battery.percent.map(String.init) ?? "—")%")
    print("  输入 \(fmt(resolved.pInput)) W   系统 \(fmt(resolved.pSystem)) W   电池 \(fmt(resolved.pBattery)) W   损耗 \(fmt(battery.pLoss)) W")
    print("  背光 \(fmt(resolved.pDisplay)) W   接口 \(fmt(resolved.pPorts)) W   来源 [\(resolved.source)]")

    if let input = resolved.pInput, let system = resolved.pSystem, let pack = resolved.pBattery {
        print("  预算: 输入 − 系统 − 电池 = \(String(format: "%.2f", input - system - pack)) W")
    }

    let attributed = energy.apps.reduce(0) { $0 + $1.watts }
    if let system = resolved.pSystem {
        let denominator = system - (resolved.pDisplay ?? 0) - (resolved.pPorts ?? 0)
        let coverage = denominator > 0.05 ? min(1, attributed / denominator) : nil
        print("  归因合计 \(fmt(attributed)) W   残差 \(fmt(max(0, denominator - attributed))) W   覆盖率 \(coverage.map { String(format: "%.0f%%", $0 * 100) } ?? "—")")
    }
    print("  能量记账: \(energy.measured ? "实测" : "估算")   参与进程 \(energy.processCount)")

    for app in energy.apps.prefix(6) {
        print("    \(pad(app.name, 26)) \(fmt(app.watts)) W  ×\(app.processCount)\(app.estimated ? " ≈" : "")")
    }
    if energy.apps.isEmpty && round == 1 {
        print("    (首轮只建立基线，第二轮开始出数)")
    }

    lastTime = now
    if round < rounds { Thread.sleep(forTimeInterval: 2) }
}
