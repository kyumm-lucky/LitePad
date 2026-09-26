import SwiftUI
import AppKit

@main
struct LitePadApp: App {
    @StateObject private var session = EditorSession()

    init() {
        // 以 `swift run` 裸进程方式运行时也能获得常规 App 形态（Dock 图标、菜单栏）
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("LitePad") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建标签页") { session.newTab() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("打开…") { session.openFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("保存") { session.saveSelectedTab() }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("关闭标签页") { session.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}
