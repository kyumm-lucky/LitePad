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
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { session.toggleSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // 菜单栏「工具」：与标题栏「工具」下拉同一入口，供键盘 / 触控板访问
            CommandMenu("工具") {
                ForEach(TextToolKind.allCases) { kind in
                    Button(kind.displayName) { session.openTool(kind) }
                }
            }
        }
    }
}
