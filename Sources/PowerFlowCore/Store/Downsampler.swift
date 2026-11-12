import Foundation

public enum Downsampler {

    /// 对一组样本求平均，得到一个代表点。
    public static func average(_ samples: [PowerSample]) -> PowerSample? {
        guard !samples.isEmpty else { return nil }
        if samples.count == 1 { return samples[0] }

        let count = Double(samples.count)
        func mean(_ values: [Double?]) -> Double? {
            let present = values.compactMap { $0 }
            guard !present.isEmpty else { return nil }
            return present.reduce(0, +) / Double(present.count)
        }

        var merged: [String: (name: String, watts: Double, estimated: Bool, count: Int)] = [:]
        for sample in samples {
            for app in sample.apps {
                if var existing = merged[app.key] {
                    existing.watts += app.watts
                    existing.count += app.processCount
                    merged[app.key] = existing
                } else {
                    merged[app.key] = (app.name, app.watts, app.estimated, app.processCount)
                }
            }
        }
        let apps = Array(merged
            .map { AppUsage(key: $0.key, name: $0.value.name,
                            watts: $0.value.watts / count,
                            estimated: $0.value.estimated,
                            processCount: max(1, $0.value.count / samples.count)) }
            .filter { $0.watts >= 0.01 }
            .sorted { $0.watts > $1.watts }
            .prefix(25))

        let last = samples[samples.count - 1]
        return PowerSample(
            ts: last.ts,
            onAC: samples.filter { $0.onAC }.count * 2 >= samples.count,
            charging: samples.filter { $0.charging }.count * 2 >= samples.count,
            batteryPercent: last.batteryPercent,
            batteryMinutes: last.batteryMinutes,
            pInput: mean(samples.map { $0.pInput }),
            pSystem: mean(samples.map { $0.pSystem }),
            pBattery: mean(samples.map { $0.pBattery }),
            pDisplay: mean(samples.map { $0.pDisplay }),
            pPorts: mean(samples.map { $0.pPorts }),
            apps: apps
        )
    }

    /// 按数量等分桶并求平均，把 N 个点压缩成约 `limit` 个点。
    public static func decimate(_ samples: [PowerSample], to limit: Int) -> [PowerSample] {
        guard limit > 0, samples.count > limit else { return samples }
        let bucketSize = Int(ceil(Double(samples.count) / Double(limit)))
        guard bucketSize > 1 else { return samples }

        var result: [PowerSample] = []
        result.reserveCapacity(samples.count / bucketSize + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + bucketSize, samples.count)
            if let averaged = average(Array(samples[index..<end])) {
                result.append(averaged)
            }
            index = end
        }
        return result
    }
}
