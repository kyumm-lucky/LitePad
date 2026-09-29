import SwiftUI
import AppKit

@main
struct LitePadApp: App {
    @StateObject private var session = EditorSession()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 以 `swift run` 裸进程方式运行时也能获得常规 App 形态（Dock 图标、菜单栏）
        NSApplication.shared.setActivationPolicy(.regular)
        // 按设置应用浅色 / 深色外观
        AppSettings.shared.applyAppearance()
        NSApplication.shared.activate(ignoringOtherApps: true)
        // 非编辑区统一箭头光标（见 CursorArbiter.swift）
        CursorArbiter.shared.install()
    }

    var body: some Scene {
        WindowGroup("LitePad") {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 760, minHeight: 480)
                // 退出保护需要会话：委托对象由 SwiftUI 在 App 构造期创建，早于 @StateObject
                // 的会话，所以在这里补上引用（首帧之前没有脏标签，晚接不影响保护）
                .onAppear { appDelegate.session = session }
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

/// 应用级委托：目前只负责退出前的未保存保护。`Cmd+Q`、菜单「退出」、Dock 菜单退出、
/// 注销 / 关机都会经由 applicationShouldTerminate，在这里统一交给会话逐个确认脏标签
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 LitePadApp 在根视图出现时注入（见那里的说明）
    weak var session: EditorSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 会话尚未注入时是启动早期，此时不可能有未保存内容
        guard let session else { return .terminateNow }
        return session.confirmTermination() ? .terminateNow : .terminateCancel
    }
}
