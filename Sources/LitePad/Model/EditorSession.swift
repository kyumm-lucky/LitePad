import AppKit
import Combine

/// 管理所有标签页的会话：新建 / 打开 / 保存 / 关闭 / 会话恢复 / 自动保存 / 外部修改检测
@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published var selectedTabIndex: Int = 0
    /// 当前展开的下拉面板（状态栏三项 / 工具）；nil 表示全部收起
    @Published var expandedMenu: WindowMenuKind?
    /// 面板中悬停的选项行索引（用于悬停高亮）
    @Published var hoveredPanelIndex: Int?
    /// 最近打开的文件（驱动"打开最近"菜单）
    @Published var recentFiles: [URL] = RecentFiles.load()
    /// 工具面板当前打开的工具；nil 表示面板关闭
    @Published var activeTool: TextToolKind?
    /// 主窗口左侧设置抽屉是否展开
    @Published var isSettingsPresented = false
    /// 工具抽屉的实时宽度：拖拽调宽逐帧更新，松手才落盘（同时供下拉面板避让抽屉）
    @Published var toolsDrawerWidth = CGFloat(AppSettings.defaultToolsPanelWidth(for: .unicode))
    /// 工具面板的输入 / 选项 / 结果
    let tools = TextToolsState()

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
        if let index = tabs.firstIndex(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            selectedTabIndex = index
            if recordsRecent {
                recordRecent(url)
            }
            return
        }
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
            return finishSave(tab: tab, to: url)
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
        // 清理放在面板确认之后：取消另存为不该改动正文
        let ok = finishSave(tab: tab, to: url)
        if ok {
            recordRecent(url)
        }
        return ok
    }

    /// 显式保存的统一入口：先在写盘前按设置清理正文，再落盘。
    /// 清理被编辑视图拒绝时中止本次保存并报错——不能默默跳过设置项
    @discardableResult
    private func finishSave(tab: EditorTab, to url: URL) -> Bool {
        switch prepareSaveCleanup(for: tab) {
        case .rejected(let reason):
            return abortSave(tab: tab, reason: reason)
        case .done, .noEditor:
            guard let failure = write(tab: tab, to: url) else { return true }
            // 用户已看到失败：登记后自动写盘不再就同一问题重复打扰
            tab.writeFailureReported = true
            presentErrorAlert(title: "无法保存文件",
                              message: failure.message + WriteFailure.dirtyNote + "请在处理问题后重试。")
            return false
        }
    }

    /// 显式保存前的正文清理（KTD5：只有显式保存清理，自动保存不动正文）。
    /// 有编辑视图的标签（当前标签）经撤销协议就地清理，清理是一次可整体撤销的编辑动作；
    /// 没有视图的标签（保存全部与退出确认里的多数）没有撤销栈可走，直接作用于模型文本。
    /// 下面的模型侧改写只走得到无视图的标签：视图存在时上面的回调只会返回 done / rejected。
    /// 这条不得推广到有视图的保存上——那既违背 KTD5，又会给撤销栈埋下失效区间（KTD14）
    private func prepareSaveCleanup(for tab: EditorTab) -> SaveCleanupOutcome {
        let settings = AppSettings.shared
        guard settings.saveCleanupApplies(to: tab.language) else { return .done }

        if tab === selectedTab, let cleanup = tab.saveCleanupHandler {
            switch cleanup() {
            case .done:
                return .done
            case .rejected(let reason):
                return .rejected(reason: reason)
            case .noEditor:
                break // 视图已拆除：继续按无视图标签处理
            }
        }

        let cleaned = SaveCleanup.applying(to: tab.text,
                                           trimTrailingWhitespace: settings.trimTrailingWhitespaceOnSave,
                                           ensureFinalNewline: settings.ensureFinalNewlineOnSave,
                                           lineEnding: tab.lineEnding)
        guard cleaned != tab.text else { return .done }
        tab.text = cleaned
        // 模型侧整串替换后匹配区间已失效，必须重算（KTD15）
        tab.refreshMatches()
        return .done
    }

    /// 清理被拒后中止保存：保持脏状态与原内容，给出可执行的失败原因
    @discardableResult
    private func abortSave(tab: EditorTab, reason: String) -> Bool {
        tab.writeFailureReported = true
        presentErrorAlert(title: "无法保存文件", message: reason + WriteFailure.dirtyNote)
        return false
    }

    /// 统一落盘：统一换行符 → 按所选编码真实转码（无法表示正文即拒绝写入，KTD4）→ 原子写 → 改绑基准。
    /// 只返回失败原因，提示由各入口按自己的打扰口径处理；失败时不写盘、不改基准、不标记干净
    private func write(tab: EditorTab, to url: URL) -> WriteFailure? {
        guard let data = tab.encoding.encode(tab.lineEnding.applying(to: tab.text)) else {
            return .unrepresentable(tab.encoding)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .io(error)
        }
        tab.markSaved(to: url)
        tab.writeFailureReported = false
        persistSession()
        return nil
    }

    /// 文件标签的自动保存：文本变化 1 秒后写盘（可在设置关闭；未标题文稿不参与）。
    /// 自动保存不做保存时清理（KTD5），失败也只在首次给一次显著提示
    private func installAutosave(for tab: EditorTab) {
        autosaveCancellables[tab.id] = tab.$text
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink(receiveValue: { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          AppSettings.shared.autosaveEnabled,
                          let url = tab.fileURL,
                          tab.text != tab.savedText else { return }
                    guard let failure = self.write(tab: tab, to: url) else { return }
                    self.reportAutosaveFailure(failure, tab: tab)
                }
            })
    }

    /// 自动写盘失败：同一标签连续失败只显著提示一次，既避免每秒打扰，
    /// 也避免与状态栏的「未保存」混同（用户必须知道磁盘上的副本没有更新）
    private func reportAutosaveFailure(_ failure: WriteFailure, tab: EditorTab) {
        guard !tab.writeFailureReported else { return }
        tab.writeFailureReported = true
        presentErrorAlert(title: "自动保存失败",
                          message: "“\(tab.displayName)”未能自动写盘。\(failure.message)"
                              + WriteFailure.dirtyNote + "请手动保存或先处理该问题。")
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

    /// 退出前的未保存保护：逐个确认有更改的标签，任一标签被取消（含保存面板被取消、
    /// 写盘失败）即中止退出。与 closeTab 共用同一套确认与保存流程，保证两个入口语义一致
    func confirmTermination() -> Bool {
        for tab in tabs where tab.isDirty {
            switch confirmSave(of: tab) {
            case .save:
                guard save(tab: tab) else { return false } // 保存被取消 / 失败则不退出
            case .discard:
                break
            case .cancel:
                return false
            }
        }
        return true
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

    // MARK: - 工具抽屉

    /// 打开工具抽屉并切换工具：先切工具再取文本，保证取到的文本填入正确的一栏
    func openTool(_ kind: TextToolKind) {
        guard let tab = selectedTab else { return }
        activeTool = kind
        toolsDrawerWidth = CGFloat(AppSettings.shared.toolsPanelWidth(for: kind))
        tools.select(kind: kind)
        seedToolsFromEditor(tab: tab)
    }

    /// 关闭工具面板（输入与选项保留，下次打开继续用）
    func closeTool() {
        activeTool = nil
    }

    // MARK: - 设置抽屉

    /// 切换主窗口设置抽屉；打开时收起其他悬浮面板，避免左右抽屉与下拉层叠加
    func toggleSettings() {
        isSettingsPresented.toggle()
        guard isSettingsPresented else { return }
        expandedMenu = nil
        hoveredPanelIndex = nil
        activeTool = nil
    }

    /// 关闭主窗口设置抽屉
    func closeSettings() {
        isSettingsPresented = false
    }

    /// 拖拽调宽：实时宽度只驱动布局，落盘由 commitToolsDrawerWidth 在松手时完成
    func resizeToolsDrawer(to width: CGFloat) {
        toolsDrawerWidth = width
    }

    /// 按当前工具记住抽屉宽度
    func commitToolsDrawerWidth() {
        guard let kind = activeTool else { return }
        AppSettings.shared.setToolsPanelWidth(Double(toolsDrawerWidth), for: kind)
    }

    /// 把编辑器当前选区（无选区取全文）送入工具面板；面板内「取编辑器」按钮复用
    func seedToolsFromEditor(tab: EditorTab) {
        let source = tab.textSourceProvider?() ?? (selection: "", fullText: tab.text)
        tools.seed(from: source.selection.isEmpty ? source.fullText : source.selection)
    }

    /// 把工具结果写回编辑器：replaceSelection 为真替换选区（无选区则插入光标处），为假替换全文
    func writeBackToolsResult(_ text: String, replaceSelection: Bool, tab: EditorTab) {
        tab.writeBackHandler?(text, replaceSelection)
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

    /// 落盘失败的原因：两种都必须不写盘、不改基准、不标记干净
    private enum WriteFailure {
        /// 所选编码无法表示正文中的部分字符（不得兜底成空数据，KTD4）
        case unrepresentable(TextEncoding)
        /// 写盘本身的 I/O 失败
        case io(Error)

        /// 面向用户的失败说明；显式保存与自动写盘共用同一份，提示框只在标题上区分来源
        var message: String {
            switch self {
            case .unrepresentable(let encoding):
                return "当前编码（\(encoding.displayName)）无法表示文稿中的部分字符。"
            case .io(let error):
                return error.localizedDescription
            }
        }

        /// 失败后文稿状态的统一交代：任何路径都不允许出现「已保存但内容为空」这类第三态
        static let dirtyNote = "文件未写入，文稿保持未保存状态。"
    }

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
