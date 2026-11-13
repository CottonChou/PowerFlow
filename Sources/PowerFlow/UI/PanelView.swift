import SwiftUI
import AppKit
import PowerFlowCore

/// 解决并缓存 App 图标（参考 bar-control 的紧凑应用图标呈现）。
struct AppIconView: View {
    let key: String
    let name: String

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let icon = resolveIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary.opacity(0.75))
            }
        }
        .frame(width: 15, height: 15)
        .clipShape(RoundedRectangle(cornerRadius: 3.2))
    }

    private var fallbackIcon: String {
        key.hasPrefix("bin:") ? "terminal" : "app.dashed"
    }

    private func resolveIcon() -> NSImage? {
        let cacheKey = key as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            return cached
        }
        var icon: NSImage?
        if key.hasPrefix("app:") {
            let path = String(key.dropFirst(4))
            if FileManager.default.fileExists(atPath: path) {
                icon = NSWorkspace.shared.icon(forFile: path)
            }
        } else if key.hasPrefix("bin:") {
            let path = String(key.dropFirst(4))
            if FileManager.default.fileExists(atPath: path) {
                icon = NSWorkspace.shared.icon(forFile: path)
            }
        }
        if icon == nil {
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == name || $0.bundleIdentifier == key
            }) {
                icon = running.icon
            }
        }
        if let found = icon {
            Self.cache.setObject(found, forKey: cacheKey)
        }
        return icon
    }
}

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
                hardwareSpecsRow(sample)
                underpoweredWarning(sample)
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
            if let temp = sample?.batteryTemperature {
                Text(String(format: "%.0f°C", temp))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.75))
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

    /// 硬件规格与快照摘要条（参考 bar-control 的电源与线缆协商指标展示）。
    @ViewBuilder
    private func hardwareSpecsRow(_ sample: PowerSample) -> some View {
        HStack(spacing: 6) {
            if sample.onAC, let spec = sample.adapterSummary {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.blue)
                    Text(spec)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else if let health = sample.batteryHealthPercent {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 7.5))
                        .foregroundStyle(Theme.mint)
                    Text("健康度 \(Int(health))%")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                    if let cycles = sample.batteryCycleCount {
                        Text("(\(cycles)次循环)")
                            .font(.system(size: 8.5, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                }
            }

            Spacer(minLength: 0)

            if let health = sample.batteryHealthPercent, sample.onAC {
                Text("健康度 \(Int(health))%")
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
    }

    /// 供电不足报警提示（参考 bar-control 的电源瓶颈诊断）。
    @ViewBuilder
    private func underpoweredWarning(_ sample: PowerSample) -> some View {
        if sample.isUnderpowered {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.amber)
                Text(String(format: "供电不足：输入 %.1fW < 负载 %.1fW，电池正在辅助放电",
                            sample.pInput ?? 0, sample.pSystem ?? 0))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.amber.opacity(0.12))
            .cornerRadius(6)
            .padding(.horizontal, 14)
            .padding(.bottom, 5)
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

    private static let appRowHeight: CGFloat = 18

    /// 占位行：保持面板高度恒定，又不至于看起来像布局漏了一块。
    private var emptyRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 15, height: 15)
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.35))
            Spacer()
        }
        .frame(height: Self.appRowHeight)
    }

    private func appRow(_ app: AppUsage) -> some View {
        HStack(spacing: 6) {
            AppIconView(key: app.key, name: app.name)
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
