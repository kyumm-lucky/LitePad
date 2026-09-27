import SwiftUI
import AppKit

@main
struct LitePadApp: App {
    @StateObject private var session = EditorSession()

    init() {
        // 以 `swift run` 裸进程方式运行时也能获得常规 App 形态（Dock 图标、菜单栏）
        NSApplication.shared.setActivationPolicy(.regular)
        // 按设置应用浅色 / 深色外观
        AppSettings.shared.applyAppearance()
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
                Menu("打开最近") {
                    ForEach(session.recentFiles, id: \.absoluteString) { url in
                        Button(url.lastPathComponent) { session.openRecent(url) }
                    }
                }
                .disabled(session.recentFiles.isEmpty)
                Button("保存") { session.saveSelectedTab() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("另存为…") { session.saveAsSelectedTab() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("查找…") { session.toggleFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("跳转到行…") { session.goToLine() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("关闭标签页") { session.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            // 应用菜单「设置…」由 Settings 场景自动插入（系统本地化，含 ⌘, 快捷键），无需显式声明
        }
        Settings {
            SettingsView()
        }
    }
}
