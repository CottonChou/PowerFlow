import SwiftUI
import PowerFlowCore

/// 一条按宽度比例缩放的流带。
struct Ribbon: Shape {
    let startY: CGFloat
    let endY: CGFloat
    var startThickness: CGFloat
    var endThickness: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let control = rect.width * 0.5

        path.move(to: CGPoint(x: rect.minX, y: startY - startThickness / 2))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: endY - endThickness / 2),
            control1: CGPoint(x: rect.minX + control, y: startY - startThickness / 2),
            control2: CGPoint(x: rect.maxX - control, y: endY - endThickness / 2)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: endY + endThickness / 2))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: startY + startThickness / 2),
            control1: CGPoint(x: rect.maxX - control, y: endY + endThickness / 2),
            control2: CGPoint(x: rect.minX + control, y: startY + startThickness / 2)
        )
        path.closeSubpath()
        return path
    }
}

/// 供电流向图。流带宽度与瓦数成正比 —— 这是相对参考项目的关键改动。
struct FlowDiagram: View {
    let sample: PowerSample

    private struct Branch: Identifiable {
        let id: String
        let title: String
        let watts: Double
        let color: Color
        let icon: String
    }

    private var branches: [Branch] {
        var items: [Branch] = [
            Branch(id: "apps", title: "已归因 App", watts: sample.attributed,
                   color: Theme.amber, icon: "cpu"),
            Branch(id: "display", title: "屏幕", watts: sample.pDisplay ?? 0,
                   color: Theme.blue, icon: "display")
        ]
        if let ports = sample.pPorts, ports > 0.1 {
            items.append(Branch(id: "ports", title: "USB-C", watts: ports,
                                color: Theme.purple, icon: "cable.connector"))
        }
        if let charge = sample.chargePower {
            items.append(Branch(id: "charge", title: "电池充电", watts: charge,
                                color: Theme.mint, icon: "battery.100percent.bolt"))
        }
        items.append(Branch(id: "residual", title: "未归因", watts: sample.residual ?? 0,
                            color: Theme.gray, icon: "questionmark.circle"))
        return items
    }

    private var sourceTitle: String {
        if sample.onAC { return "电源输入" }
        return sample.dischargePower == nil ? "电池供电" : "电池放电"
    }

    private var sourceWatts: Double {
        if sample.onAC { return sample.pInput ?? sample.pSystem ?? 0 }
        return sample.dischargePower ?? sample.pSystem ?? 0
    }

    private var sourceIcon: String {
        sample.onAC ? "powerplug.fill" : "battery.75percent"
    }

    private static let height: CGFloat = 220
    private static let maxThickness: CGFloat = 22
    private static let minThickness: CGFloat = 2.5

    private func thickness(_ watts: Double, scale: Double) -> CGFloat {
        guard scale > 0.01 else { return Self.minThickness }
        let ratio = min(1, max(0, watts / scale))
        return Self.minThickness + CGFloat(ratio) * (Self.maxThickness - Self.minThickness)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = Self.height
            let centerY = height / 2
            let rows = branches
            let scale = max(rows.map(\.watts).max() ?? 0, sourceWatts, sample.pSystem ?? 0, 1)

            let sourceRight: CGFloat = 60
            let macLeft: CGFloat = 94
            let macRight: CGFloat = 166
            let branchLeft = width - 108

            ZStack {
                Ribbon(
                    startY: centerY, endY: centerY,
                    startThickness: thickness(sourceWatts, scale: scale),
                    endThickness: thickness(sample.pSystem ?? sourceWatts, scale: scale)
                )
                .fill(LinearGradient(
                    colors: [Theme.mint.opacity(0.22), Theme.mint.opacity(0.42)],
                    startPoint: .leading, endPoint: .trailing
                ))
                // 高度必须给满：Ribbon 的 startY/endY 是整张图坐标，
                // 只给宽度会让它落在未知高度的局部坐标里，流带起点就会偏。
                .frame(width: macLeft - sourceRight, height: height)
                .position(x: (sourceRight + macLeft) / 2, y: centerY)

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, branch in
                    let y = rowCenter(index: index, count: rows.count, height: height)
                    let endThickness = thickness(branch.watts, scale: scale)
                    Ribbon(
                        startY: centerY, endY: y,
                        startThickness: endThickness,
                        endThickness: endThickness
                    )
                    .fill(LinearGradient(
                        colors: [branch.color.opacity(0.22), branch.color.opacity(0.08)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: branchLeft - macRight, height: height)
                    .position(x: (macRight + branchLeft) / 2, y: centerY)

                    branchNode(branch, width: width, y: y)
                }

                sourceNode(centerY: centerY)
                macNode(centerY: centerY)
            }
        }
        .frame(height: Self.height)
    }

    private func rowCenter(index: Int, count: Int, height: CGFloat) -> CGFloat {
        guard count > 1 else { return height / 2 }
        let inset: CGFloat = 26
        let usable = height - inset * 2
        return inset + usable * CGFloat(index) / CGFloat(count - 1)
    }

    private func branchNode(_ branch: Branch, width: CGFloat, y: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: branch.icon)
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(branch.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.watts(branch.watts) + " W")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(branch.title)
                    .font(.system(size: 8))
                    .foregroundStyle(branch.color.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(branch.color.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(branch.color.opacity(0.20), lineWidth: 0.6)
                )
        )
        .frame(width: 108)
        .position(x: width - 54, y: y)
    }

    private func sourceNode(centerY: CGFloat) -> some View {
        VStack(spacing: 2) {
            Image(systemName: sourceIcon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Theme.mint)
            Text(Fmt.watts(sourceWatts) + " W")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(sourceTitle)
                .font(.system(size: 7.5))
                .foregroundStyle(Theme.mint.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 56, height: 78)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(LinearGradient(
                    colors: [Theme.mint.opacity(0.18), .white.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Theme.mint.opacity(0.24), lineWidth: 0.7)
                )
        )
        .position(x: 32, y: centerY)
    }

    private func macNode(centerY: CGFloat) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 18, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.85))
            Text(Fmt.watts(sample.pSystem))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("系统 W")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
        }
        .frame(width: 72, height: 84)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.08), lineWidth: 0.6)
                )
        )
        .position(x: 130, y: centerY)
    }
}
