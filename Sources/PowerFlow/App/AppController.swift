import AppKit
import SwiftUI
import Combine
import PowerFlowCore

/// 菜单栏图标 + 弹出面板 + 趋势窗口的容器。
@MainActor
final class AppController: NSObject, NSApplicationDelegate {

    private let sampler = PowerSampler.shared
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var panelHosting: NSHostingController<PanelView>?
    /// 面板内容的布局签名：行数、供电状态变化时才重新测量高度。
    private var panelSignature = ""
    /// macOS 26 会把「菜单栏项是否可见」写进本应用的偏好里（key 为 `NSStatusItem VisibleCC <name>`）。
    /// 一旦某次被挤进溢出区存成 0，之后即使有空位也永远不显示，所以这里用固定名字并在启动时复位。
    private static let statusAutosaveName = "PowerFlow"
    private var trendWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    private static let panelWidth: CGFloat = 364

    func applicationDidFinishLaunching(_ notification: Notification) {
        sampler.start()
        configureStatusItem()
        configurePopover()
        observeSamples()

        // 调试开关：便于无人值守地验证真实窗口的渲染。
        let arguments = CommandLine.arguments
        if let idx = arguments.firstIndex(of: "--render-panel"), arguments.indices.contains(idx + 1) {
            let outPath = arguments[idx + 1]
            renderOffscreenSample(to: outPath)
        }
        if arguments.contains("--show-panel") {
            popover.behavior = .applicationDefined
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.togglePopover(nil)
            }
        }
        if arguments.contains("--show-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showTrendWindow()
                // 验证截图时确保窗口真的在最前面，不被其他 App 的窗口盖住。
                self?.trendWindow?.level = .floating
                self?.trendWindow?.orderFrontRegardless()
                // 截图验证时窗口可能被创建在别的 Space，这里让它跟到当前 Space。
                self?.trendWindow?.collectionBehavior = [.moveToActiveSpace]
                if CommandLine.arguments.contains("--debug-size") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let window = self?.trendWindow else {
                            FileHandle.standardError.write("trend window: nil\n".data(using: .utf8)!)
                            return
                        }
                        let line = "trend windowNumber=\(window.windowNumber) frame=\(window.frame) visible=\(window.isVisible) "
                            + "occlusion=\(window.occlusionState.rawValue) "
                            + "screens=\(NSScreen.screens.map(\.frame))\n"
                        FileHandle.standardError.write(line.data(using: .utf8)!)
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showTrendWindow() }
        return true
    }

    // MARK: - 菜单栏

    private func configureStatusItem() {
        UserDefaults.standard.set(
            true,
            forKey: "NSStatusItem VisibleCC \(Self.statusAutosaveName)"
        )
        // 固定宽度 62pt：保证 100W+ 三位数字不会被截断为省略号，且避免 variableLength 引起的挤压。
        let item = NSStatusBar.system.statusItem(withLength: 62)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "bolt.fill",
                accessibilityDescription: "PowerFlow"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = " --"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func observeSamples() {
        if CommandLine.arguments.contains("--debug-size") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let button = self?.statusItem?.button else { return }
                let line = "statusItem frame=\(button.frame) window=\(button.window?.frame.debugDescription ?? "nil") "
                    + "title=\(button.title) image=\(button.image != nil) "
                    + "itemVisible=\(self?.statusItem?.isVisible ?? false) "
                    + "buttonHidden=\(button.isHidden) "
                    + "screenVisible=\(NSScreen.main?.visibleFrame.debugDescription ?? "nil")\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
        }
        // 菜单栏被占满时，系统会把新状态项塞到时钟底下（窗口落到屏幕外），图标就"消失"了。
        // 这种情况下至少把主窗口打开，别让应用启动后什么都看不到。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, let window = self.statusItem?.button?.window else { return }
            let parked = window.frame.origin.x <= 0 || window.frame.origin.y <= 0
            if parked {
                FileHandle.standardError.write(
                    "菜单栏没有空位，PowerFlow 图标被系统隐藏，改为打开主窗口。\n".data(using: .utf8)!
                )
                self.showTrendWindow()
            }
        }
        sampler.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] sample in
                guard let button = self?.statusItem?.button else { return }
                if let watts = sample?.pSystem {
                    button.title = String(format: " %.0f", watts)
                } else {
                    button.title = " --"
                }
                // App 列表行数会随首次归因结果变化，面板高度必须跟着重算。
                self?.resizePanel()
            }
            .store(in: &cancellables)
    }

    // MARK: - 弹出面板

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(
            rootView: PanelView(sampler: sampler, onOpenTrend: { [weak self] in
                self?.showTrendWindow()
            })
        )
        popover.contentViewController = hosting
        panelHosting = hosting
        resizePanel()
    }

    /// 用真实布局结果决定弹层高度。
    ///
    /// `sizeThatFits(in:)` 在视图尚未挂进窗口时拿到的是未布局的估值，会少算几十点，
    /// 底部 App 行与「趋势」入口就被裁掉。这里先给定宽度跑一次布局，再读 `fittingSize`。
    private func resizePanel(force: Bool = false) {
        guard let hosting = panelHosting else { return }
        let sample = sampler.current
        let signature = [
            sample == nil ? "waiting" : "ready",
            sample?.onAC == true ? "ac" : "batt",
            (sample?.chargePower ?? 0) > 0.05 ? "chg" : "-",
            sample?.dischargePower != nil ? "dis" : "-",
            sample?.pInput != nil ? "in" : "-",
            "ports\(sample?.pPorts != nil ? 1 : 0)",
            "rows\(min(3, sample?.apps.count ?? 0))"
        ].joined(separator: "|")
        if !force && signature == panelSignature { return }
        panelSignature = signature

        let width = Self.panelWidth
        // 测量用的临时高度，测完必须还原：否则 SwiftUI 会把内容在过高的视图里居中，
        // 弹层按 contentSize 裁剪后顶部状态行就被切掉。
        hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        hosting.view.layoutSubtreeIfNeeded()

        let fit = hosting.sizeThatFits(in: NSSize(width: width, height: 2_000))
        var height = ceil(max(fit.height, hosting.view.fittingSize.height))
        guard height > 120 && height < 1_200 else { return }

        // 为 Popover 增加安全缓冲（+18pt），彻底杜绝 macOS 弹窗圆角与未挂载字体度量差异对底部文字的遮挡
        height += 18

        hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let target = NSSize(width: width, height: height)
        if abs(popover.contentSize.height - target.height) > 0.5
            || abs(popover.contentSize.width - target.width) > 0.5 {
            popover.contentSize = target
            if CommandLine.arguments.contains("--debug-size") {
                let line = "popover \(Int(target.width))×\(Int(target.height)) [\(signature)]\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            showStatusMenu(relativeTo: button)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            resizePanel(force: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                self?.resizePanel(force: true)
            }
            if CommandLine.arguments.contains("--debug-size") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, let hosting = self.panelHosting else { return }
                    let window = hosting.view.window
                    let line = "shown hosting=\(hosting.view.frame.size) "
                        + "windowContent=\(window?.contentView?.bounds.size ?? .zero) "
                        + "contentSize=\(self.popover.contentSize) "
                        + "windowNumber=\(window?.windowNumber ?? -1)\n"
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                }
            }
        }
    }

    /// 右键菜单：面板之外再给一个入口，顺带解决「无 Dock 图标、无主菜单时无处退出」。
    private func showStatusMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()

        let trend = NSMenuItem(title: "打开功耗走向", action: #selector(openTrendFromMenu), keyEquivalent: "")
        trend.target = self
        menu.addItem(trend)

        let panel = NSMenuItem(title: "打开面板", action: #selector(openPanelFromMenu), keyEquivalent: "")
        panel.target = self
        menu.addItem(panel)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 PowerFlow", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        popover.performClose(nil)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func openTrendFromMenu() {
        showTrendWindow()
    }

    @objc private func openPanelFromMenu() {
        if !popover.isShown { togglePopover(nil) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 趋势窗口

    func showTrendWindow() {
        if let window = trendWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: TrendWindow(sampler: sampler))
        let window = NSWindow(contentViewController: hosting)
        window.title = "PowerFlow · 功耗走向"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 高度要一次装下 主图 + 电池副图 + 排行 + 脚注，否则首屏会把脚注挤到折叠线以下。
        window.setContentSize(NSSize(width: 940, height: 800))
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        // 后台启动（登录项 / 终端拉起）时窗口会跑到别的 Space，用户看不到。
        window.collectionBehavior = [.moveToActiveSpace]
        trendWindow = window

        popover.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        // 后台启动时 activate 常常被系统拒绝，窗口会留在别的 App 后面；
        // 这时至少把窗口提到最前（不抢焦点），否则用户以为应用没起来。
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func renderOffscreenSample(to path: String) {
        let isChg = path.contains("charging")
        let sample = PowerSample(
            ts: Date(),
            onAC: true,
            charging: isChg,
            batteryPercent: isChg ? 45 : 80,
            batteryMinutes: isChg ? 55 : nil,
            pInput: isChg ? 45.0 : 7.0,
            pSystem: 12.5,
            pBattery: isChg ? 30.0 : 0.0,
            pDisplay: 2.1,
            pPorts: nil,
            apps: [
                AppUsage(key: "1", name: "Xcode", watts: 6.8, estimated: false, processCount: 4),
                AppUsage(key: "2", name: "Antigravity", watts: 2.4, estimated: false, processCount: 1)
            ]
        )
        let view = PanelContent(
            sample: sample,
            capabilities: Capabilities(smc: true, telemetry: true, displayKey: "DBLB", ports: true, energy: true),
            errorText: nil
        )
        .environment(\.isOffscreenRender, true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("Rendered panel to \(path)")
        }
        exit(0)
    }
}
