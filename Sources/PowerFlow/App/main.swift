import AppKit
import SwiftUI
import PowerFlowCore

// 用 AppKit 手动搭建菜单栏应用，而不是 SwiftUI 的 MenuBarExtra 场景：
// 后者在 .app bundle 里会因「没有可见窗口」在启动阶段直接结束进程。

MainActor.assumeIsolated {
    if RenderMode.runIfRequested() {
        exit(0)
    }

    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.setActivationPolicy(.accessory)
    application.run()
}
