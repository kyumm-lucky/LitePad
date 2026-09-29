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
        // 必须用单窗口的 Window 场景：WindowGroup 在收到「打开文稿」Apple Event 时
        // 会自己再开一个窗口（与委托里的分页处理叠加就成了重复窗口），而本应用是
        // 「一个窗口 + 多个标签页」的模型，文件一律进标签，不开新窗口
        Window("LitePad", id: mainWindowID) {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 760, minHeight: 480)
                .background(ReopenWindowBridge { appDelegate.reopenWindow = $0 })
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
                    if !session.recentFiles.isEmpty {
                        Divider()
                    }
                    Button("清空最近") { session.clearRecentFiles() }
                        .disabled(session.recentFiles.isEmpty)
                }
                Button("保存") { session.saveSelectedTab() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("另存为…") { session.saveAsSelectedTab() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("保存全部") { session.saveAll() }
                Button("查找…") { session.toggleFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("跳转到行…") { session.goToLine() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("关闭标签页") { session.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: .command)
                // 不用框架自带的「全部关闭」：那一个关的是窗口，这里关的是全部标签
                Button("关闭全部") { session.closeAllTabs() }
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

/// 应用级委托：负责退出前的未保存保护，以及窗口全关后再点 Dock 图标时把窗口建回来。
/// `Cmd+Q`、菜单「退出」、Dock 菜单退出、注销 / 关机都会经由 applicationShouldTerminate，
/// 在那里统一交给会话逐个确认脏标签
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 LitePadApp 在根视图出现时注入（见那里的说明）
    weak var session: EditorSession? {
        didSet {
            guard let session else { return }
            for url in pendingOpenFiles {
                session.open(url: url)
            }
            pendingOpenFiles.removeAll()
        }
    }
    /// 启动时系统可能先交付文件，再创建主窗口和编辑会话
    private var pendingOpenFiles: [URL] = []
    /// 由根视图注入的 openWindow 动作，用于重建窗口（见 applicationShouldHandleReopen）
    var reopenWindow: (() -> Void)?

    func application(_ sender: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let session {
            for url in files {
                session.open(url: url)
            }
            if !sender.windows.contains(where: { $0.canBecomeMain || $0.isMiniaturized }) {
                reopenWindow?()
            }
        } else {
            pendingOpenFiles.append(contentsOf: files)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 会话尚未注入时是启动早期，此时不可能有未保存内容
        guard let session else { return .terminateNow }
        return session.confirmTermination() ? .terminateNow : .terminateCancel
    }

    /// 窗口全关掉后点 Dock 图标（或 Dock 的「重新打开」）会走到这里。实测本工程的窗口关闭后
    /// 即被释放，SwiftUI 不会自己把窗口建回来（同样结构的最小 App 会），
    /// 所以必须显式重建——否则图标点下去毫无反应，未保存的内容也就再也回不到屏幕上。
    /// 窗口还在（`Cmd+H` 隐藏、最小化）时 AppKit 自己会把它恢复到前台，这里不插手。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let reopenWindow else { return true }
        if let window = sender.windows.first(where: { $0.canBecomeMain || $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenWindow()
        }
        return true
    }
}

/// 主窗口的场景标识（重建窗口时按它取）
private let mainWindowID = "main"

/// 取当前窗口的 openWindow 动作交给应用委托：环境值只能在视图里读，读到的动作转交出去，
/// 供窗口全关后重建窗口。同 WindowSizeSync 的写法，零尺寸视图只为挂 onAppear
private struct ReopenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let install: (@escaping () -> Void) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { install { openWindow(id: mainWindowID) } }
    }
}
