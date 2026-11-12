import SwiftUI
import AppKit
import PowerFlowCore

/// 离屏渲染模式：把两个界面直接画成 PNG，用于无人值守的布局校验。
///
/// 用法：`PowerFlow --render <输出目录>`
@MainActor
enum RenderMode {

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render") else { return false }
        let directory = arguments.indices.contains(index + 1) ? arguments[index + 1] : "render-out"

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let samples = syntheticSamples()
        let latest = samples.last
        let capabilities = Capabilities(
            smc: true, telemetry: true, displayKey: "PDBR", ports: true, energy: true
        )

        render(
            PanelContent(sample: latest, capabilities: capabilities, errorText: nil)
                .environment(\.isOffscreenRender, true),
            width: 364,
            height: nil,
            to: url.appendingPathComponent("panel.png")
        )

        render(
            TrendContent(
                range: .thirtyMinutes,
                samples: samples.suffix(900).map { $0 },
                capabilities: capabilities,
                isOffscreen: true
            ),
            width: 900,
            height: 700,
            to: url.appendingPathComponent("trend.png")
        )

        print("已输出到 \(url.path)")
        exit(0)
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?, to url: URL) {
        let framed: AnyView
        if let height {
            framed = AnyView(view.frame(width: width, height: height))
        } else {
            framed = AnyView(view.frame(width: width))
        }
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage else {
            print("渲染失败: \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// 构造一段「电池 → 插电充电」的合成曲线，覆盖两种供电状态与插拔事件。
    static func syntheticSamples() -> [PowerSample] {
        var result: [PowerSample] = []
        let end = Date()
        let total = 1_800
        let step: TimeInterval = 2

        for index in 0..<total {
            let ts = end.addingTimeInterval(-Double(total - index) * step)
            let progress = Double(index) / Double(total)
            let onAC = progress > 0.62
            let wave = sin(Double(index) / 23.0) * 1.6 + sin(Double(index) / 7.0) * 0.5

            let system: Double
            let battery: Double
            let input: Double
            if onAC {
                system = 26 + wave
                battery = 34 + sin(Double(index) / 31.0) * 4
                input = system + battery + 4.5
            } else {
                system = 17 + wave
                battery = -system
                input = 0
            }

            let display = 2.4 + sin(Double(index) / 17.0) * 0.2
            let ports = onAC ? 0.0 : 1.2
            let scale = system / 17.0
            let apps = [
                AppUsage(key: "app:/Applications/Cursor.app", name: "Cursor",
                         watts: 3.4 * scale, estimated: false, processCount: 6),
                AppUsage(key: "app:/Applications/Google Chrome.app", name: "Google Chrome",
                         watts: 2.6 * scale, estimated: false, processCount: 14),
                AppUsage(key: "app:/Applications/SeaTalk.app", name: "SeaTalk",
                         watts: 1.15 * scale, estimated: true, processCount: 3),
                AppUsage(key: "app:/Applications/ChatGPT.app", name: "ChatGPT",
                         watts: 0.9 * scale, estimated: false, processCount: 4)
            ]

            result.append(PowerSample(
                ts: ts,
                onAC: onAC,
                charging: onAC,
                batteryPercent: onAC ? 76 : 62,
                batteryMinutes: onAC ? 46 : 203,
                pInput: input,
                pSystem: system,
                pBattery: battery,
                pDisplay: display,
                pPorts: ports,
                apps: apps
            ))
        }
        return result
    }
}
