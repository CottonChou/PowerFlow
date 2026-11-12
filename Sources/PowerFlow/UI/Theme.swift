import SwiftUI
import PowerFlowCore

enum Theme {
    static let mint = Color(red: 0.49, green: 0.88, blue: 0.75)
    static let amber = Color(red: 0.94, green: 0.71, blue: 0.35)
    static let blue = Color(red: 0.42, green: 0.66, blue: 0.94)
    static let purple = Color(red: 0.69, green: 0.55, blue: 0.94)
    static let gray = Color(red: 0.48, green: 0.52, blue: 0.58)
    static let danger = Color(red: 0.95, green: 0.45, blue: 0.42)

    static func color(for band: PowerBand) -> Color {
        switch band {
        case .apps: amber
        case .display: blue
        case .ports: purple
        case .residual: gray
        }
    }
}

enum Fmt {
    /// 功率：一位小数，缺失显示破折号。
    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    static func wattsUnit(_ value: Double?) -> String {
        watts(value) + " W"
    }

    /// 剩余时间：分钟转 “3h12m”。
    static func duration(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 离屏渲染时跳过 NSViewRepresentable（ImageRenderer 无法绘制 AppKit 视图）。
private struct RenderModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isOffscreenRender: Bool {
        get { self[RenderModeKey.self] }
        set { self[RenderModeKey.self] = newValue }
    }
}

struct StatePill: View {
    let sample: PowerSample?

    private var label: String {
        guard let sample else { return "等待采样" }
        if sample.charging { return "充电中" }
        if sample.onAC {
            return (sample.batteryPercent ?? 0) >= 99 ? "外接供电 · 满电" : "外接供电"
        }
        return "电池供电"
    }

    private var tint: Color {
        guard let sample else { return Theme.gray }
        if sample.charging { return Theme.mint }
        return sample.onAC ? Theme.blue : Theme.amber
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 0.6))
        .foregroundStyle(tint)
    }
}
