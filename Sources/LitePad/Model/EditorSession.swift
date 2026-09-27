import AppKit
import Combine

/// 管理所有标签页的会话：新建 / 打开 / 保存 / 关闭
@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published var selectedTabIndex: Int = 0
    /// 状态栏当前展开的下拉面板；nil 表示全部收起
    @Published var expandedMenu: StatusBarMenuKind?
    /// 面板中悬停的选项行索引（用于悬停高亮）
    @Published var hoveredPanelIndex: Int?
    /// 最近打开的文件（驱动"打开最近"菜单）
    @Published var recentFiles: [URL] = RecentFiles.load()

    init() {
        tabs = [EditorTab()]
    }

    var selectedTab: EditorTab? {
        guard tabs.indices.contains(selectedTabIndex) else { return nil }
        return tabs[selectedTabIndex]
    }

    func newTab() {
        tabs.append(EditorTab())
        selectedTabIndex = tabs.count - 1
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要编辑的文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    /// 打开指定文件并建标签；最近文件菜单复用
    func open(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let (content, encoding) = TextEncoding.decode(data)
            let lineEnding = LineEnding.detect(in: content)
            tabs.append(EditorTab(fileURL: url, text: content,
                                  encoding: encoding, lineEnding: lineEnding))
            selectedTabIndex = tabs.count - 1
            recordRecent(url)
        } catch {
            presentErrorAlert(title: "无法读取文件", message: error.localizedDescription)
        }
    }

    /// 从最近列表打开：文件已不存在时提示并清除该记录
    func openRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            recentFiles = RecentFiles.remove(url)
            presentErrorAlert(title: "无法打开文件",
                              message: "文件不存在或已被移动：\(url.lastPathComponent)")
            return
        }
        open(url: url)
    }

    func saveSelectedTab() {
        guard let tab = selectedTab else { return }
        save(tab: tab)
    }

    @discardableResult
    func save(tab: EditorTab) -> Bool {
        if let url = tab.fileURL {
            return write(tab: tab, to: url)
        }
        // 未绑定文件的标签走另存为流程
        return saveAs(tab: tab)
    }

    /// 当前标签另存为新文件，成功后标签改绑新文件
    @discardableResult
    func saveAsSelectedTab() -> Bool {
        guard let tab = selectedTab else { return false }
        return saveAs(tab: tab)
    }

    @discardableResult
    private func saveAs(tab: EditorTab) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.fileURL?.lastPathComponent ?? "未命名.txt"
        panel.message = "选择保存位置"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let ok = write(tab: tab, to: url)
        if ok {
            recordRecent(url)
        }
        return ok
    }

    /// 统一落盘：统一换行符 → 按所选编码真实转码写出（含 BOM 变体）→ 改绑基准
    private func write(tab: EditorTab, to url: URL) -> Bool {
        do {
            try tab.encoding.encode(tab.lineEnding.applying(to: tab.text))
                .write(to: url, options: .atomic)
            tab.markSaved(to: url)
            return true
        } catch {
            presentErrorAlert(title: "无法保存文件", message: error.localizedDescription)
            return false
        }
    }

    func closeSelectedTab() {
        guard tabs.indices.contains(selectedTabIndex) else { return }
        closeTab(at: selectedTabIndex)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]

        if tab.isDirty {
            switch confirmSave(of: tab) {
            case .save:
                guard save(tab: tab) else { return } // 保存被取消则不关闭
            case .discard:
                break
            case .cancel:
                return
            }
        }

        tabs.remove(at: index)
        if tabs.isEmpty {
            tabs = [EditorTab()] // 始终保留一个空标签，与 Notepad++ 行为一致
            selectedTabIndex = 0
        } else if index < selectedTabIndex {
            selectedTabIndex -= 1
        } else {
            selectedTabIndex = min(selectedTabIndex, tabs.count - 1)
        }
    }

    /// 打开/关闭查找面板（Cmd+F 切换）
    func toggleFind() {
        guard let tab = selectedTab else { return }
        if tab.findState == nil {
            tab.applyFindState(FindState())
        } else {
            tab.findState = nil
        }
    }

    /// 弹出行号输入框并跳转到指定行；非法输入蜂鸣且不跳转
    func goToLine() {
        guard let tab = selectedTab else { return }
        let maxLine = max(1, tab.stats.totalLines)
        let alert = NSAlert()
        alert.messageText = "跳转到行"
        alert.informativeText = "输入要跳转到的行号（1 - \(maxLine)）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "行号"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let line = Int(input.stringValue.trimmingCharacters(in: .whitespaces)),
              (1...maxLine).contains(line) else {
            NSSound.beep()
            return
        }
        tab.goToLineHandler?(line)
    }

    // MARK: - Private

    /// 记录最近文件并刷新菜单数据源
    private func recordRecent(_ url: URL) {
        recentFiles = RecentFiles.record(url)
    }

    private enum SaveChoice { case save, discard, cancel }

    private func confirmSave(of tab: EditorTab) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = "是否保存对“\(tab.displayName)”的更改？"
        alert.informativeText = "如果不保存，更改将会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
