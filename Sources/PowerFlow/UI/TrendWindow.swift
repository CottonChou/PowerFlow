import SwiftUI
import PowerFlowCore

enum RankingScope: String, CaseIterable, Identifiable {
    case all = "全部"
    case batteryOnly = "🔋 仅纯电池"

    var id: String { rawValue }
}

/// 趋势窗口的纯视图，数据由外部注入。
struct TrendContent: View {
    let range: TrendRange
    let samples: [PowerSample]
    let capabilities: Capabilities
    var onRangeChange: (TrendRange) -> Void = { _ in }
    var onClearHistory: () -> Void = {}
    /// 离屏渲染时，ScrollView 与系统控件无法绘制，改用等价布局。
    var isOffscreen: Bool = false

    @State private var rankingScope: RankingScope = .all

    private var latest: PowerSample? { samples.last }

    private var rankingSamples: [PowerSample] {
        switch rankingScope {
        case .all:
            return samples
        case .batteryOnly:
            return samples.filter { !$0.onAC }
        }
    }

    private var rangeApps: [AppUsage] {
        // 0.0W 的行只是噪声：空闲进程会一直挂在尾部，把真正有量的挤下去。
        AppUsageAggregator.aggregate(rankingSamples, limit: 8)
            .filter { $0.watts >= 0.05 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if isOffscreen {
                VStack(alignment: .leading, spacing: 14) {
                    systemSection
                    batterySection
                    rankingSection
                    footnote
                }
                .padding(16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        systemSection
                        batterySection
                        rankingSection
                        footnote
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PowerFlow")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("功耗走向")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let sample = latest {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.watts(sample.pSystem))
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("W 系统负载")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                StatePill(sample: sample)
                if let charge = sample.chargePower {
                    metricChip("充电", Fmt.watts(charge) + " W", Theme.mint)
                } else if let discharge = sample.dischargePower {
                    metricChip("放电", Fmt.watts(discharge) + " W", Theme.amber)
                }
                if let coverage = sample.coverage {
                    metricChip("归因", Fmt.percent(coverage),
                               CoverageStyle.tint(coverage: coverage,
                                                  attributed: sample.attributed))
                }
            }

            Spacer()

            RangePicker(selection: range, onChange: onRangeChange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metricChip(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.10)))
    }

    // MARK: - 主图

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("系统负载分解")
                    .font(.system(size: 11, weight: .medium))
                ForEach(PowerBand.allCases, id: \.self) { band in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.color(for: band))
                            .frame(width: 7, height: 7)
                        Text(band.title)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.9))
                        .frame(width: 9, height: 1.5)
                    Text("实测总量")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("背景 蓝=插电 绿=电池")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary.opacity(0.7))
            }

            TrendChart(samples: samples, range: range)
                .frame(height: 250)

            if samples.isEmpty {
                Text("该时间窗口暂无数据，采样 1 分钟后开始出现曲线。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(panel)
    }

    // MARK: - 电池副图

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("电池功率")
                    .font(.system(size: 11, weight: .medium))
                Text("正=充入 · 负=放出")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if let sample = latest, let battery = sample.pBattery {
                    Text((battery >= 0 ? "+" : "") + Fmt.watts(battery) + " W")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(battery >= 0 ? Theme.mint : Theme.amber)
                }
            }
            BatteryTrendChart(samples: samples)
                .frame(height: 96)
        }
        .padding(12)
        .background(panel)
    }

    // MARK: - 排行

    private var rankingSection: some View {
        let apps = rangeApps
        let peak = apps.map(\.watts).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("App 能耗排行")
                    .font(.system(size: 11, weight: .medium))
                Text(range.title + (rankingScope == .batteryOnly ? " · 仅电池供电" : " · 平均"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)

                HStack(spacing: 2) {
                    ForEach(RankingScope.allCases) { scope in
                        Button {
                            rankingScope = scope
                        } label: {
                            Text(scope.rawValue)
                                .font(.system(size: 9, weight: rankingScope == scope ? .semibold : .regular))
                                .foregroundStyle(rankingScope == scope ? (scope == .batteryOnly ? Theme.amber : .primary) : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(
                                    Capsule().fill(rankingScope == scope ? (scope == .batteryOnly ? Theme.amber.opacity(0.18) : Color.white.opacity(0.12)) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(1.5)
                .background(Capsule().fill(Color.white.opacity(0.05)))

                Spacer()
                Text("≈ 为估算值")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary.opacity(0.7))
            }

            if apps.isEmpty {
                let emptyHint = rankingScope == .batteryOnly
                    ? "所选时间窗口内未检测到纯电池放电记录（一直在外接电源供电）。"
                    : "暂无归因数据。"
                Text(emptyHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        Text(app.name)
                            .font(.system(size: 10.5))
                            .frame(width: 150, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.06))
                                Capsule()
                                    .fill(Theme.amber.opacity(0.55))
                                    .frame(width: max(2, geometry.size.width * CGFloat(app.watts / peak)))
                            }
                        }
                        .frame(height: 6)
                        Text(Fmt.watts(app.watts) + " W")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                        Text(app.estimated ? "≈" : "")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                    }
                }
            }
        }
        .padding(12)
        .background(panel)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("残差 = 实测系统负载 − 已归因 App − 屏幕背光 − USB-C 接口，包含无线、SSD、风扇、内核与 DC-DC 损耗。")
            Text(capabilities.summary + "  ·  采样间隔 2s")
        }
        .font(.system(size: 8.5))
        .foregroundStyle(.secondary.opacity(0.8))
        .padding(.horizontal, 2)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.06), lineWidth: 0.7)
            )
    }
}

/// 自绘分段控件：系统 Picker 无法离屏渲染，且这里需要更紧凑的样式。
struct RangePicker: View {
    let selection: TrendRange
    var onChange: (TrendRange) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TrendRange.allCases) { item in
                Button {
                    onChange(item)
                } label: {
                    Text(item.title)
                        .font(.system(size: 10, weight: selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(selection == item ? Color.white.opacity(0.14) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
    }
}

/// 趋势窗口容器：负责取数与范围切换。
struct TrendWindow: View {
    @ObservedObject var sampler: PowerSampler
    @State private var range: TrendRange = .thirtyMinutes
    @State private var samples: [PowerSample] = []

    var body: some View {
        TrendContent(
            range: range,
            samples: samples,
            capabilities: sampler.capabilities,
            onRangeChange: { newValue in
                range = newValue
                samples = sampler.history(for: newValue)
            },
            onClearHistory: { sampler.clearHistory() }
        )
        .task { refresh() }
        .onChange(of: sampler.current?.ts) { _, _ in refresh() }
        .onChange(of: range) { _, _ in refresh() }
    }

    private func refresh() {
        samples = sampler.history(for: range)
    }
}
