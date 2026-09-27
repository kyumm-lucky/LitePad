import AppKit
import Combine

/// 管理所有标签页的会话：新建 / 打开 / 保存 / 关闭 / 会话恢复 / 自动保存 / 外部修改检测
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

    /// 启动会话恢复的 UserDefaults 键
    private static let sessionKey = "lastSession.urls"
    /// 每个标签页的自动保存订阅（防抖写盘）
    private var autosaveCancellables: [UUID: AnyCancellable] = [:]

    init() {
        restoreSessionOrNewTab()
        // 应用激活时检测外部修改；退出前记录当前会话
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkExternalChanges() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistSession() }
        }
    }

    /// 启动恢复：按设置重开上次会话的文件；无文件可恢复时按设置决定是否新建
    private func restoreSessionOrNewTab() {
        let settings = AppSettings.shared
        if settings.restoreSessionOnLaunch {
            let urls = UserDefaults.standard.stringArray(forKey: Self.sessionKey)?
                .compactMap(URL.init(string:)) ?? []
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                open(url: url, recordsRecent: false, alertOnError: false)
            }
        }
        guard tabs.isEmpty, settings.launchAction == .newDocument else { return }
        let empty = EditorTab()
        tabs = [empty]
        selectedTabIndex = 0
        installAutosave(for: empty)
    }

    var selectedTab: EditorTab? {
        guard tabs.indices.contains(selectedTabIndex) else { return nil }
        return tabs[selectedTabIndex]
    }

    /// 新增标签页的统一入口：挂接自动保存订阅
    private func addTab(_ tab: EditorTab) {
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
        installAutosave(for: tab)
    }

    func newTab() {
        addTab(EditorTab())
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
        open(url: url, recordsRecent: true, alertOnError: true)
    }

    /// 打开的完整路径：会话恢复不记录最近列表、不弹错误框
    func open(url: URL, recordsRecent: Bool, alertOnError: Bool) {
        do {
            let data = try Data(contentsOf: url)
            let settings = AppSettings.shared
            let (content, encoding) = TextEncoding.decode(
                data,
                priority: settings.encodingPriority,
                respectCharsetDeclaration: settings.respectCharsetDeclaration)
            let lineEnding = LineEnding.detect(in: content)
            addTab(EditorTab(fileURL: url, text: content,
                             encoding: encoding, lineEnding: lineEnding))
            if recordsRecent {
                recordRecent(url)
            }
            persistSession()
        } catch where alertOnError {
            presentErrorAlert(title: "无法读取文件", message: error.localizedDescription)
        } catch {
            // 会话恢复场景静默跳过坏文件
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

    /// 统一落盘：统一换行符 → 按所选编码真实转码写出（含 BOM 变体）→ 改绑基准。
    /// 自动保存路径传 alertOnError: false，失败保持脏状态不打扰输入
    private func write(tab: EditorTab, to url: URL, alertOnError: Bool = true) -> Bool {
        do {
            try tab.encoding.encode(tab.lineEnding.applying(to: tab.text))
                .write(to: url, options: .atomic)
            tab.markSaved(to: url)
            persistSession()
            return true
        } catch {
            if alertOnError {
                presentErrorAlert(title: "无法保存文件", message: error.localizedDescription)
            }
            return false
        }
    }

    /// 文件标签的自动保存：文本变化 1 秒后写盘（可在设置关闭；未标题文稿不参与）
    private func installAutosave(for tab: EditorTab) {
        autosaveCancellables[tab.id] = tab.$text
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink(receiveValue: { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          AppSettings.shared.autosaveEnabled,
                          let url = tab.fileURL,
                          tab.text != tab.savedText else { return }
                    _ = self.write(tab: tab, to: url, alertOnError: false)
                }
            })
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

        autosaveCancellables.removeValue(forKey: tab.id)
        tabs.remove(at: index)
        if tabs.isEmpty {
            let empty = EditorTab() // 始终保留一个空标签，与 Notepad++ 行为一致
            tabs = [empty]
            selectedTabIndex = 0
            installAutosave(for: empty)
        } else if index < selectedTabIndex {
            selectedTabIndex -= 1
        } else {
            selectedTabIndex = min(selectedTabIndex, tabs.count - 1)
        }
        persistSession()
    }

    /// 把当前文件标签写入 UserDefaults，供下次启动恢复
    func persistSession() {
        UserDefaults.standard.set(tabs.compactMap(\.fileURL).map(\.absoluteString),
                                  forKey: Self.sessionKey)
    }

    /// 外部修改检测：只处理无未保存改动的文件标签；已察觉后记录新时间避免重复提示
    func checkExternalChanges() {
        for tab in tabs {
            guard let url = tab.fileURL, !tab.isDirty,
                  let diskDate = EditorTab.fileDate(at: url),
                  let knownDate = tab.fileModificationDate,
                  diskDate > knownDate else { continue }
            switch AppSettings.shared.externalChangeAction {
            case .update:
                reload(tab: tab, from: url)
            case .ask:
                if confirmReload(of: tab) {
                    reload(tab: tab, from: url)
                } else {
                    tab.fileModificationDate = diskDate
                }
            case .keepVersion:
                tab.fileModificationDate = diskDate
            }
        }
    }

    /// 用磁盘内容覆盖标签（外部修改"更新到被更改的版本" / 询问后重载）
    private func reload(tab: EditorTab, from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let settings = AppSettings.shared
        let (content, encoding) = TextEncoding.decode(
            data,
            priority: settings.encodingPriority,
            respectCharsetDeclaration: settings.respectCharsetDeclaration)
        tab.text = content
        tab.encoding = encoding
        tab.lineEnding = LineEnding.detect(in: content)
        tab.markSaved(to: url)
    }

    private func confirmReload(of tab: EditorTab) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(tab.displayName)”已被其他程序修改"
        alert.informativeText = "是否重新载入磁盘上的版本？当前内容将被替换。"
        alert.addButton(withTitle: "重新载入")
        alert.addButton(withTitle: "保留当前版本")
        return alert.runModal() == .alertFirstButtonReturn
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
