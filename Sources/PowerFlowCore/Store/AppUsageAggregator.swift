import Foundation

public enum AppUsageAggregator {

    /// 把一个窗口内的 App 功率求平均。
    ///
    /// 分母用窗口内的样本总数，因此「偶发出现」的 App 会被自然拉低，
    /// 不会因为某个瞬间的尖峰排到前面。
    public static func aggregate(_ samples: [PowerSample], limit: Int = 8) -> [AppUsage] {
        guard !samples.isEmpty else { return [] }
        let denominator = Double(samples.count)

        var totals: [String: (name: String, watts: Double, estimated: Bool, processes: Int)] = [:]
        for sample in samples {
            for app in sample.apps {
                let averaged = app.watts / denominator
                if var existing = totals[app.key] {
                    existing.watts += averaged
                    existing.processes = max(existing.processes, app.processCount)
                    totals[app.key] = existing
                } else {
                    totals[app.key] = (app.name, averaged, app.estimated, app.processCount)
                }
            }
        }

        return totals
            .map { AppUsage(key: $0.key, name: $0.value.name, watts: $0.value.watts,
                            estimated: $0.value.estimated,
                            processCount: max(1, $0.value.processes)) }
            .filter { $0.watts > 0.005 }
            .sorted { $0.watts > $1.watts }
            .prefix(limit)
            .map { $0 }
    }
}
