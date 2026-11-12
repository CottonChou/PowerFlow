import SwiftUI
import Charts
import PowerFlowCore

struct StackedPoint: Identifiable {
    let ts: Date
    let band: PowerBand
    let lower: Double
    let upper: Double
    var id: String { "\(ts.timeIntervalSince1970)-\(band.rawValue)" }
}

struct ACSpan: Identifiable {
    let start: Date
    let end: Date
    let onAC: Bool
    var id: Date { start }
}

/// 主趋势图：堆叠分解 + 实测系统负载白线。
struct TrendChart: View {
    let samples: [PowerSample]
    let range: TrendRange

    private static let bandOrder: [PowerBand] = [.apps, .display, .ports, .residual]

    private var points: [StackedPoint] {
        var result: [StackedPoint] = []
        result.reserveCapacity(samples.count * Self.bandOrder.count)
        for sample in samples {
            var accumulator = 0.0
            for band in Self.bandOrder {
                let value = band.value(in: sample)
                let lower = accumulator
                accumulator += value
                result.append(StackedPoint(ts: sample.ts, band: band, lower: lower, upper: accumulator))
            }
        }
        return result
    }

    private var yMax: Double {
        let peak = samples.compactMap(\.pSystem).max() ?? 0
        let stackPeak = points.map(\.upper).max() ?? 0
        return max(5, max(peak, stackPeak) * 1.18)
    }

    /// 右侧留 1.5% 余量：最后一个时间刻度压在绘图区边缘时会被 Charts 截断成 "17:…"。
    private var xDomain: ClosedRange<Date> {
        guard let first = samples.first?.ts, let last = samples.last?.ts, last > first else {
            let now = Date()
            return now...now.addingTimeInterval(60)
        }
        return first...last.addingTimeInterval(last.timeIntervalSince(first) * 0.015)
    }

    private var spans: [ACSpan] {
        guard let first = samples.first else { return [] }
        var result: [ACSpan] = []
        var runStart = first.ts
        var runState = first.onAC
        let tail = samples.last?.ts ?? first.ts
        let extend = max(1, (tail.timeIntervalSince(first.ts)) / Double(max(1, samples.count)) / 2)

        for sample in samples.dropFirst() {
            if sample.onAC != runState {
                result.append(ACSpan(start: runStart, end: sample.ts, onAC: runState))
                runStart = sample.ts
                runState = sample.onAC
            }
        }
        result.append(ACSpan(
            start: result.isEmpty ? runStart.addingTimeInterval(-extend) : runStart,
            end: tail.addingTimeInterval(extend),
            onAC: runState
        ))
        return result
    }

    var body: some View {
        Chart {
            ForEach(spans) { span in
                RectangleMark(
                    xStart: .value("起", span.start),
                    xEnd: .value("止", span.end),
                    yStart: .value("底", 0),
                    yEnd: .value("顶", yMax)
                )
                .foregroundStyle(
                    (span.onAC ? Theme.blue : Theme.mint).opacity(0.10)
                )
            }

            ForEach(Array(spans.dropFirst())) { span in
                RuleMark(x: .value("切换", span.start))
                    .foregroundStyle(.white.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }

            ForEach(points) { point in
                AreaMark(
                    x: .value("时间", point.ts),
                    yStart: .value("W", point.lower),
                    yEnd: .value("W", point.upper)
                )
                .foregroundStyle(by: .value("构成", point.band.title))
                .interpolationMethod(.monotone)
            }

            ForEach(samples) { sample in
                if let system = sample.pSystem {
                    LineMark(
                        x: .value("时间", sample.ts),
                        y: .value("W", system)
                    )
                    .foregroundStyle(.white.opacity(0.92))
                    .lineStyle(StrokeStyle(lineWidth: 1.3))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartXScale(domain: xDomain)
        .chartForegroundStyleScale(
            domain: PowerBand.allCases.map(\.title),
            range: PowerBand.allCases.map { Theme.color(for: $0).opacity(0.45) }
        )
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [2, 3]))
                    .foregroundStyle(.white.opacity(0.10))
                AxisValueLabel()
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(.white.opacity(0.06))
                AxisValueLabel(format: axisFormat)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .chartLegend(.hidden)
    }

    private var axisFormat: Date.FormatStyle {
        range == .oneDay || range == .sixHours
            ? .dateTime.hour().minute()
            : .dateTime.hour().minute().second()
    }
}

/// 副图：电池功率走向（正=充电，负=放电）。
struct BatteryTrendChart: View {
    let samples: [PowerSample]

    private var limit: Double {
        let peak = samples.compactMap { $0.pBattery.map(abs) }.max() ?? 1
        return max(5, peak * 1.3)
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("零", 0))
                .foregroundStyle(.white.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 0.6))

            ForEach(samples) { sample in
                if let battery = sample.pBattery {
                    AreaMark(
                        x: .value("时间", sample.ts),
                        yStart: .value("W", 0),
                        yEnd: .value("W", max(0, battery))
                    )
                    .foregroundStyle(by: .value("方向", "充电"))
                    .interpolationMethod(.monotone)

                    AreaMark(
                        x: .value("时间", sample.ts),
                        yStart: .value("W", min(0, battery)),
                        yEnd: .value("W", 0)
                    )
                    .foregroundStyle(by: .value("方向", "放电"))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("时间", sample.ts),
                        y: .value("W", battery)
                    )
                    .foregroundStyle(by: .value("方向", battery >= 0 ? "充电" : "放电"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: -limit...limit)
        .chartForegroundStyleScale(
            domain: ["充电", "放电"],
            range: [Theme.mint.opacity(0.55), Theme.amber.opacity(0.55)]
        )
        .chartYAxis {
            AxisMarks(position: .leading, values: [-limit, 0, limit]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(.white.opacity(0.08))
                AxisValueLabel()
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
    }
}
