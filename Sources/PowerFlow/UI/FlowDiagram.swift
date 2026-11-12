import SwiftUI
import PowerFlowCore

/// 一条按宽度比例缩放的平滑流带（Sankey Ribbon）。
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

/// 供电流向图：方案 A（物理分流拓扑）
///
/// 核心准则：严格遵循能量守恒：
/// 1. 插电充电时：适配器总输入在前端直接分流为「电池充电」与「系统负载」；
/// 2. 插电闲置时：电池自动折叠为待机徽章，输入 100% 进入系统负载；
/// 3. 系统负载流入 Mac 后，再细分为：已归因 App、屏幕、USB-C、未归因残差；
/// 4. 电池供电时：电池放电作为总源头流入 Mac 系统。
struct FlowDiagram: View {
    let sample: PowerSample

    private struct Branch: Identifiable {
        let id: String
        let title: String
        let watts: Double
        let color: Color
        let icon: String
    }

    /// 系统负载的构成项（总和严格等于 sample.pSystem）。
    private var systemBranches: [Branch] {
        var items: [Branch] = [
            Branch(id: "apps", title: "已归因 App", watts: sample.attributed,
                   color: Theme.amber, icon: "cpu"),
            Branch(id: "display", title: "屏幕", watts: sample.pDisplay ?? 0,
                   color: Theme.blue, icon: "display")
        ]
        if let ports = sample.pPorts, ports > 0.05 {
            items.append(Branch(id: "ports", title: "USB-C", watts: ports,
                                color: Theme.purple, icon: "cable.connector"))
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
        if sample.onAC {
            return sample.pInput ?? ((sample.pSystem ?? 0) + (sample.chargePower ?? 0))
        }
        return sample.dischargePower ?? sample.pSystem ?? 0
    }

    private var sourceIcon: String {
        sample.onAC ? "powerplug.fill" : "battery.75percent"
    }

    private static let height: CGFloat = 204
    private static let maxThickness: CGFloat = 20
    private static let minThickness: CGFloat = 2.0

    private func thickness(_ watts: Double, scale: Double) -> CGFloat {
        guard scale > 0.01 else { return Self.minThickness }
        let ratio = min(1, max(0, watts / scale))
        return Self.minThickness + CGFloat(ratio) * (Self.maxThickness - Self.minThickness)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = Self.height

            // 比例尺度基准
            let branchMax = systemBranches.map(\.watts).max() ?? 0
            let scale = max(sourceWatts, sample.pSystem ?? 0, sample.chargePower ?? 0, branchMax, 1)

            // 水平基准锚点（与整体面板两端 14pt 边距严格对齐）
            let sourceRight: CGFloat = 54
            let macLeft: CGFloat = 105
            let macRight: CGFloat = 173
            let branchLeft: CGFloat = width - 112
            let branchCenterX: CGFloat = width - 56

            let isCharging = sample.onAC && (sample.chargePower ?? 0) > 0.05
            let chargeWatts = sample.chargePower ?? 0

            // 垂直锚点计算
            let sourceCenterY: CGFloat = isCharging ? 110 : 102
            let macCenterY: CGFloat = isCharging ? 132 : 102

            ZStack {
                // MARK: - 第一级流向：输入 -> (电池充电 + 系统负载)
                if isCharging {
                    // 1. 输入 -> 电池充电（直接分流到右上角电池节点）
                    Ribbon(
                        startY: sourceCenterY - 14, endY: 24,
                        startThickness: thickness(chargeWatts, scale: scale),
                        endThickness: thickness(chargeWatts, scale: scale)
                    )
                    .fill(LinearGradient(
                        colors: [Theme.mint.opacity(0.36), Theme.mint.opacity(0.18)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: branchLeft - sourceRight, height: height)
                    .position(x: (sourceRight + branchLeft) / 2, y: height / 2)

                    // 2. 输入 -> Mac 系统负载节点
                    Ribbon(
                        startY: sourceCenterY + 10, endY: macCenterY,
                        startThickness: thickness(sample.pSystem ?? 0, scale: scale),
                        endThickness: thickness(sample.pSystem ?? 0, scale: scale)
                    )
                    .fill(LinearGradient(
                        colors: [Theme.mint.opacity(0.30), Theme.amber.opacity(0.30)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: macLeft - sourceRight, height: height)
                    .position(x: (sourceRight + macLeft) / 2, y: height / 2)

                    // 右上角电池充入节点
                    batteryChargingNode(watts: chargeWatts, x: branchCenterX, y: 24)

                } else {
                    // 非充电状态（纯电池放电 或 插电待机）：总输入 100% 进入系统负载
                    let flowColor = sample.onAC ? Theme.mint : Theme.amber
                    Ribbon(
                        startY: sourceCenterY, endY: macCenterY,
                        startThickness: thickness(sourceWatts, scale: scale),
                        endThickness: thickness(sample.pSystem ?? sourceWatts, scale: scale)
                    )
                    .fill(LinearGradient(
                        colors: [flowColor.opacity(0.24), flowColor.opacity(0.38)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: macLeft - sourceRight, height: height)
                    .position(x: (sourceRight + macLeft) / 2, y: height / 2)
                }

                // MARK: - 第二级流向：Mac 系统负载 -> 各构成分支
                let rows = systemBranches
                let branchCount = rows.count
                let topY: CGFloat = isCharging ? 68 : 26
                let bottomY: CGFloat = isCharging ? 186 : 178

                // 核心修复：Sankey 流带分层堆叠（每个分支在 Mac 右侧有独立的起始 Y，绝不挤压重叠）
                let branchThicknesses = rows.map { thickness($0.watts, scale: scale) }
                let ribbonGap: CGFloat = 1.5
                let totalThickness = branchThicknesses.reduce(0, +) + ribbonGap * CGFloat(max(0, branchCount - 1))
                let stackTop = macCenterY - totalThickness / 2

                var currentY = stackTop
                let ribbonOrigins: [CGFloat] = branchThicknesses.map { t in
                    let origin = currentY + t / 2
                    currentY += t + ribbonGap
                    return origin
                }

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, branch in
                    let branchY = branchCount == 1 ? (topY + bottomY) / 2
                        : topY + (bottomY - topY) * CGFloat(index) / CGFloat(branchCount - 1)
                    let branchThickness = branchThicknesses[index]

                    Ribbon(
                        startY: ribbonOrigins[index], endY: branchY,
                        startThickness: branchThickness,
                        endThickness: branchThickness
                    )
                    .fill(LinearGradient(
                        colors: [branch.color.opacity(0.24), branch.color.opacity(0.08)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: branchLeft - macRight, height: height)
                    .position(x: (macRight + branchLeft) / 2, y: height / 2)

                    branchNode(branch, x: branchCenterX, y: branchY)
                }

                // 源节点与系统节点
                sourceNode(centerY: sourceCenterY)
                macNode(centerY: macCenterY)
            }
        }
        .frame(height: Self.height)
    }

    // MARK: - 子视图节点

    private func batteryChargingNode(watts: Double, x: CGFloat, y: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "battery.100percent.bolt")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.mint)
            Text("电池充入")
                .font(.system(size: 9))
                .foregroundStyle(Theme.mint.opacity(0.9))
            Spacer(minLength: 0)
            Text("+" + Fmt.watts(watts) + " W")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.mint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.mint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.mint.opacity(0.35), lineWidth: 0.8)
                )
        )
        .frame(width: 112)
        .position(x: x, y: y)
    }

    private func branchNode(_ branch: Branch, x: CGFloat, y: CGFloat) -> some View {
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
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(branch.color.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(branch.color.opacity(0.20), lineWidth: 0.6)
                )
        )
        .frame(width: 112)
        .position(x: x, y: y)
    }

    private func sourceNode(centerY: CGFloat) -> some View {
        let isAC = sample.onAC
        let tint = isAC ? Theme.mint : Theme.amber
        return VStack(spacing: 2) {
            Image(systemName: sourceIcon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(tint)
            Text(Fmt.watts(sourceWatts) + " W")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(sourceTitle)
                .font(.system(size: 7.5))
                .foregroundStyle(tint.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 54, height: 72)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.18), .white.opacity(0.02)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(tint.opacity(0.24), lineWidth: 0.7)
                )
        )
        .position(x: 27, y: centerY)
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
        .frame(width: 68, height: 74)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.08), lineWidth: 0.6)
                )
        )
        .position(x: 139, y: centerY)
    }
}
