import Foundation
import Combine

/// 采样能力自检结果，用于在 UI 上诚实地标注哪些数字是实测、哪些缺失。
public struct Capabilities: Sendable {
    public var smc: Bool
    public var telemetry: Bool
    public var displayKey: String?
    public var ports: Bool
    public var energy: Bool

    public init(smc: Bool, telemetry: Bool, displayKey: String?, ports: Bool, energy: Bool) {
        self.smc = smc
        self.telemetry = telemetry
        self.displayKey = displayKey
        self.ports = ports
        self.energy = energy
    }

    public var summary: String {
        var parts: [String] = []
        parts.append(smc ? "SMC ✓" : "SMC ✗")
        parts.append(telemetry ? "遥测 ✓" : "遥测 ✗")
        parts.append(displayKey.map { "背光 \($0)" } ?? "背光 ✗")
        parts.append(ports ? "接口 ✓" : "接口 ✗")
        parts.append(energy ? "能量记账 ✓" : "能量估算")
        return parts.joined(separator: " · ")
    }
}

@MainActor
public final class PowerSampler: ObservableObject {

    public static let sampleInterval: TimeInterval = 2
    static let displayKeys = ["PDBR", "PBwo", "PBLR"]
    static let maxAppsPerSample = 25

    @Published public private(set) var current: PowerSample?
    @Published public private(set) var isRunning = false
    @Published public private(set) var capabilities = Capabilities(
        smc: false, telemetry: false, displayKey: nil, ports: false, energy: false
    )
    @Published public private(set) var lastError: String?

    public static let shared = PowerSampler()

    public let tiers = HistoryTiers()
    private let smc = SMC()
    private let attributor = EnergyAttributor()
    private let store: SQLiteStore?
    private let workQueue = DispatchQueue(label: "com.powerflow.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var resolvedDisplayKey: String?

    public init(store: SQLiteStore? = SQLiteStore()) {
        self.store = store
        if let store {
            let since = Date().addingTimeInterval(-HistoryTiers.coarseWindow)
            tiers.load(coarse: store.load(since: since))
        }
        tiers.onCoarseSample = { [weak self] sample in
            guard let self else { return }
            self.workQueue.async {
                self.store?.insert(sample)
            }
        }
        self.capabilities.smc = self.smc.isOpen
        self.resolvedDisplayKey = Self.displayKeys.first { self.smc.read($0) != nil }
        self.capabilities.displayKey = self.resolvedDisplayKey
    }

    public func start() {
        guard timer == nil else { return }
        attributor.reset()
        let source = DispatchSource.makeTimerSource(queue: workQueue)
        source.schedule(
            deadline: .now() + 0.1,
            repeating: Self.sampleInterval,
            leeway: .milliseconds(200)
        )
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
        isRunning = true
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    public func clearHistory() {
        store?.deleteAll()
    }

    public func history(for range: TrendRange, limit: Int = 240) -> [PowerSample] {
        tiers.samples(for: range, limit: limit)
    }

    // MARK: - 采样

    private func tick() {
        let now = Date()
        let battery = BatteryProbe.read()
        let resolved = PowerResolver.resolve(
            battery: battery,
            smc: smc,
            displayKey: resolvedDisplayKey
        )
        let energy = attributor.sample(now: now)

        let sample = PowerSample(
            ts: now,
            onAC: battery.onAC,
            charging: battery.charging,
            batteryPercent: battery.percent,
            batteryMinutes: battery.minutesRemaining,
            batteryTemperature: battery.temperature,
            batteryCycleCount: battery.cycleCount,
            batteryHealthPercent: battery.healthPercent,
            adapterRatedWatts: battery.adapterRatedWatts,
            adapterName: battery.adapterName,
            adapterNegotiatedWatts: battery.negotiatedWatts,
            adapterNegotiatedVoltageMV: battery.negotiatedVoltageMV,
            adapterNegotiatedCurrentMA: battery.negotiatedCurrentMA,
            pInput: resolved.pInput,
            pSystem: resolved.pSystem,
            pBattery: resolved.pBattery,
            pDisplay: resolved.pDisplay,
            pPorts: resolved.pPorts,
            apps: Array(energy.apps.prefix(Self.maxAppsPerSample))
        )

        DispatchQueue.main.async { [weak self] in
            self?.publish(sample, energy: energy, resolved: resolved)
        }
    }

    private func publish(
        _ sample: PowerSample,
        energy: EnergyAttributor.Result,
        resolved: ResolvedPower
    ) {
        tiers.append(sample)
        current = sample
        capabilities.telemetry = resolved.pInput != nil
        capabilities.ports = resolved.pPorts != nil
        if energy.measured || capabilities.energy {
            capabilities.energy = true
        }
        lastError = energy.processCount == 0 && sample.apps.isEmpty
            ? "尚未取得进程能量增量（首轮采样只建立基线）"
            : nil
    }
}
