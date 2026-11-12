import Foundation

/// 三层历史：2s 原始 / 10s 中频 / 60s 低频。
///
/// 只保留三份降采样副本，长窗口查询时不再扫描全量 2s 数据。
public final class HistoryTiers {

    static let fineInterval: TimeInterval = 2
    static let mediumInterval: TimeInterval = 10
    static let coarseInterval: TimeInterval = 60

    static let fineWindow: TimeInterval = 3_600
    static let mediumWindow: TimeInterval = 21_600
    static let coarseWindow: TimeInterval = 86_400

    public private(set) var fine: [PowerSample] = []
    public private(set) var medium: [PowerSample] = []
    public private(set) var coarse: [PowerSample] = []

    private var fineBucket: [PowerSample] = []
    private var mediumBucket: [PowerSample] = []
    private var fineBucketStart: Date?
    private var mediumBucketStart: Date?

    /// 每当产生一个新的 60s 聚合点时回调，用于落库。
    public var onCoarseSample: ((PowerSample) -> Void)?

    public init() {}

    public func load(coarse samples: [PowerSample]) {
        coarse = samples.sorted { $0.ts < $1.ts }
    }

    public func append(_ sample: PowerSample) {
        fine.append(sample)
        trimFine()

        if fineBucketStart == nil { fineBucketStart = sample.ts }
        fineBucket.append(sample)
        if let start = fineBucketStart,
           sample.ts.timeIntervalSince(start) >= Self.mediumInterval - 0.01 {
            if let averaged = Downsampler.average(fineBucket) {
                pushMedium(averaged)
            }
            fineBucket.removeAll(keepingCapacity: true)
            fineBucketStart = sample.ts
        }
    }

    private func pushMedium(_ sample: PowerSample) {
        medium.append(sample)
        trimMedium()

        if mediumBucketStart == nil { mediumBucketStart = sample.ts }
        mediumBucket.append(sample)
        if let start = mediumBucketStart,
           sample.ts.timeIntervalSince(start) >= Self.coarseInterval - 0.01 {
            if let averaged = Downsampler.average(mediumBucket) {
                coarse.append(averaged)
                trimCoarse()
                onCoarseSample?(averaged)
            }
            mediumBucket.removeAll(keepingCapacity: true)
            mediumBucketStart = sample.ts
        }
    }

    /// 返回适合渲染的样本序列（最多约 `limit` 个点）。
    public func samples(for range: TrendRange, limit: Int = 240) -> [PowerSample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let source: [PowerSample]
        switch range {
        case .fiveMinutes, .thirtyMinutes:
            source = fine
        case .sixHours:
            source = medium
        case .oneDay:
            source = coarse
        }
        let windowed = source.filter { $0.ts >= cutoff }
        return Downsampler.decimate(windowed, to: limit)
    }

    private func trimFine() {
        let cutoff = Date().addingTimeInterval(-Self.fineWindow)
        if let index = fine.firstIndex(where: { $0.ts >= cutoff }), index > 0 {
            fine.removeFirst(index)
        }
    }

    private func trimMedium() {
        let cutoff = Date().addingTimeInterval(-Self.mediumWindow)
        if let index = medium.firstIndex(where: { $0.ts >= cutoff }), index > 0 {
            medium.removeFirst(index)
        }
    }

    private func trimCoarse() {
        let cutoff = Date().addingTimeInterval(-Self.coarseWindow)
        if let index = coarse.firstIndex(where: { $0.ts >= cutoff }), index > 0 {
            coarse.removeFirst(index)
        }
    }
}
