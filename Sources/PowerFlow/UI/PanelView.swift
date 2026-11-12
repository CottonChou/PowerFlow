import SwiftUI
import PowerFlowCore

/// 菜单栏弹出面板的纯视图：只吃数据，不依赖采样器，便于离屏渲染校验。
struct PanelContent: View {
    let sample: PowerSample?
    let capabilities: Capabilities
    let errorText: String?
    var onOpenTrend: () -> Void = {}

    @Environment(\.isOffscreenRender) private var offscreen

    var body: some View {
        VStack(spacing: 0) {
            header
            if let sample {
                headline(sample)
                FlowDiagram(sample: sample)
                    .padding(.horizontal, 14)
                Divider()
                    .padding(.horizontal, 14)
                    .opacity(0.25)
                appList(sample)
                footer
            } else {
                waiting
            }
        }
        .frame(width: 364)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if offscreen {
                Color(red: 0.11, green: 0.12, blue: 0.14)
            } else {
                ZStack {
                    GlassBackground()
                    // `.hudWindow` 的 behindWindow 采样会把桌面内容透上来，文字对比度不够；
                    // 压一层足够深的渐变，保留一点玻璃质感但不牺牲可读性。
                    LinearGradient(
                        colors: [Color.black.opacity(0.74), Color.black.opacity(0.66)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatePill(sample: sample)
            Spacer()
            if let percent = sample?.batteryPercent {
                HStack(spacing: 3) {
                    Image(systemName: batteryIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(percent)%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
            if let remaining = Fmt.duration(minutes: sample?.batteryMinutes) {
                Text(remaining)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 6)
    }

    private var batteryIcon: String {
        guard let percent = sample?.batteryPercent else { return "battery.0percent" }
        let level = Int((Double(percent) / 100 * 4).rounded())
        let base = ["battery.0percent", "battery.25percent", "battery.50percent",
                    "battery.75percent", "battery.100percent"][min(4, max(0, level))]
        return sample?.charging == true ? base + ".bolt" : base
    }

    private func headline(_ sample: PowerSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Fmt.watts(sample.pSystem))
                        .font(.system(size: 40, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("W")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("系统负载")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let charge = sample.chargePower {
                    secondaryRow(label: "充电", value: charge, tint: Theme.mint)
                } else if let discharge = sample.dischargePower {
                    secondaryRow(label: "放电", value: discharge, tint: Theme.amber)
                } else {
                    secondaryRow(label: "电池", text: "待机", tint: Theme.gray)
                }
                if let input = sample.pInput, sample.onAC {
                    secondaryRow(label: "输入", value: input, tint: Theme.blue)
                }
                if let coverage = sample.coverage {
                    HStack(spacing: 3) {
                        Text("归因")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(Fmt.percent(coverage))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(CoverageStyle.tint(coverage: coverage,
                                                                attributed: sample.attributed))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func secondaryRow(label: String, value: Double? = nil, text: String? = nil, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(text ?? (Fmt.watts(value) + " W"))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private func appList(_ sample: PowerSample) -> some View {
        let apps = Array(sample.apps.filter { $0.watts >= 0.05 }.prefix(3))
        return VStack(spacing: 4) {
            if apps.isEmpty {
                Text(errorText ?? "正在建立进程能量基线…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                // 固定 3 行：Top 列表随时在换人，行数一变面板就跟着伸缩，看着像在抖。
                ForEach(0..<3, id: \.self) { index in
                    if index < apps.count {
                        appRow(apps[index])
                    } else {
                        emptyRow
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private static let appRowHeight: CGFloat = 15

    /// 占位行：保持面板高度恒定，又不至于看起来像布局漏了一块。
    private var emptyRow: some View {
        HStack {
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.35))
            Spacer()
        }
        .frame(height: Self.appRowHeight)
    }

    private func appRow(_ app: AppUsage) -> some View {
        HStack(spacing: 6) {
            Text(app.name)
                .font(.system(size: 10.5))
                .lineLimit(1)
            if app.estimated {
                Text("≈")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(Fmt.watts(app.watts) + " W")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.amber)
        }
        .frame(height: Self.appRowHeight)
    }

    private var footer: some View {
        HStack {
            Text(capabilities.summary)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onOpenTrend) {
                HStack(spacing: 3) {
                    Text("趋势")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mint)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.white.opacity(0.03))
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在读取电源遥测…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
    }
}

/// 归因覆盖率的配色：低负载时归因天然偏低，不该报警。
enum CoverageStyle {
    static func tint(coverage: Double, attributed: Double) -> Color {
        if attributed < 2 { return Theme.gray }
        if coverage >= 0.6 { return Theme.mint }
        if coverage >= 0.35 { return Theme.amber }
        return Theme.danger
    }
}

/// 菜单栏面板容器：把采样器接到纯视图上。
struct PanelView: View {
    @ObservedObject var sampler: PowerSampler
    var onOpenTrend: () -> Void = {}

    var body: some View {
        PanelContent(
            sample: sampler.current,
            capabilities: sampler.capabilities,
            errorText: sampler.lastError
        ) { onOpenTrend() }
    }
}
