import AppKit
import Combine
import UniformTypeIdentifiers

/// 管理所有标签页的会话：新建 / 打开 / 保存 / 关闭 / 会话恢复 / 自动保存 / 外部修改检测。
/// 保存与自动写盘见 `EditorSession+Persistence`，恢复区见 `EditorSession+Recovery`，
/// 重读与外部改动重载见 `EditorSession+Reload`
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
    /// 是否有文件正被拖在窗口上（驱动接收提示）：编辑区由编辑视图在 AppKit 层上报，
    /// 标签栏与状态栏由主栏的投放目标上报。只经 `setFileDropTargeted` 写
    @Published private(set) var isFileDropTargeted = false
    /// 工具抽屉的实时宽度：拖拽调宽逐帧更新，松手才落盘（同时供下拉面板避让抽屉）
    @Published var toolsDrawerWidth = CGFloat(AppSettings.defaultToolsPanelWidth(for: .unicode))
    /// 工具面板的输入 / 选项 / 结果
    let tools = TextToolsState()

    /// 启动会话恢复的 UserDefaults 键
    static let sessionKey = "lastSession.urls"
    /// 每个标签页的自动保存订阅（防抖写盘）
    var autosaveCancellables: [UUID: AnyCancellable] = [:]
    /// 每个标签页的恢复区订阅（R6：未标题正文去抖写入，照自动保存的形态）
    var recoveryCancellables: [UUID: AnyCancellable] = [:]
    /// 未标题文稿的恢复区（R6 / R7）：与会话恢复并列的另一条通道，两者互不读写对方的键
    let recovery = RecoveryStore.shared
    /// 条目归属表：标题 → 当前写下这条条目的标签。恢复区按稳定标题为键，同名条目可能来自
    /// 上一次运行、也可能已经换了写入方，只有真正写过它的标签才有资格删掉它 ——
    /// 按标题查找的删除出口一旦不校验归属，就会误删同名标签刚写进去的正文
    var titleOwners: [String: UUID] = [:]
    /// 启动时恢复区里有待恢复的条目：会话构造期读一次，提示要等首帧之后才弹
    var hasPendingRecovery = false

    init() {
        hasPendingRecovery = !recovery.allEntries().isEmpty
        restoreSessionOrNewTab()
        // 恢复区的写入失败与超限要有可见提示：写不进去等于「内容不丢」降级成无保护
        recovery.onAlert = { [weak self] alert in
            self?.reportRecoveryAlert(alert)
        }
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
        // 恢复区里有待恢复的内容时先不建空占位标签：恢复提示要等首帧之后才弹，
        // 而空占位标签的标题会同待恢复条目撞名，一秒后的去抖同步会把那份内容删掉
        guard tabs.isEmpty, settings.launchAction == .newDocument, !hasPendingRecovery else { return }
        addUntitledTab()
    }

    var selectedTab: EditorTab? {
        guard tabs.indices.contains(selectedTabIndex) else { return nil }
        return tabs[selectedTabIndex]
    }

    /// 新增标签页的统一入口：挂接自动保存与恢复区订阅
    private func addTab(_ tab: EditorTab) {
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
        installAutosave(for: tab)
        // 恢复区只承载未标题文稿：文件标签永不写恢复区，不必为它常驻一条去抖管线
        if tab.untitledTitle != nil {
            installRecovery(for: tab)
        }
    }

    /// 建一张未标题标签并纳入会话：标题在这里统一分配（R8 / KD4），
    /// 三处新建入口与启动恢复共用这一条路径，不各自造一份标题规则。
    /// `savedText` 默认取 `text`（新建的空标签）；恢复出来的内容必须显式传空串，
    /// 让它带脏标记（没有保存基准），否则正常退出不会向用户确认、条目也不会删除；
    /// `title` 只在恢复时传入（沿用存下来的标题），其余场合按当前标签集合往后编号
    @discardableResult
    func addUntitledTab(text: String = "", savedText: String? = nil,
                        title: String? = nil) -> EditorTab {
        let tab = EditorTab(text: text, savedText: savedText,
                            untitledTitle: title ?? nextUntitledTitle())
        addTab(tab)
        return tab
    }

    /// 下一个未标题标题：扫描当前所有标签的未标题标题取最大序号 + 1（KD4）。
    /// 已绑定文件的标签也要算进来 —— 它的标题在关闭前仍然占位，只看未绑定的标签会让
    /// 另存为之后的编号被下一个新标签复用，两张标签随后共用一个标题：恢复区按标题为键，
    /// 前者的收尾动作会把后者刚写进去的正文整条删掉
    private func nextUntitledTitle() -> String {
        UntitledTitle.next(after: tabs.compactMap(\.untitledTitle))
    }

    func newTab() {
        addUntitledTab()
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
        // 标签的文件取解析后的地址：此后读写都对着真实文件，不会经链接把链接本身写掉
        let target = Self.fileIdentity(url)
        if let index = tabIndex(holdingFileAt: target) {
            selectedTabIndex = index
            if recordsRecent {
                recordRecent(url)
            }
            return
        }
        do {
            let data = try Data(contentsOf: target)
            let settings = AppSettings.shared
            let (content, encoding) = TextEncoding.decode(
                data,
                priority: settings.encodingPriority,
                respectCharsetDeclaration: settings.respectCharsetDeclaration)
            let lineEnding = LineEnding.detect(in: content)
            addTab(EditorTab(fileURL: target, text: content,
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

    /// 清空最近文件列表；列表清空后「打开最近」里只剩置灰的清空项
    func clearRecentFiles() {
        RecentFiles.clear()
        recentFiles = []
    }

    /// 拖入提示的开关：同值不写 —— @Published 没有等值闸门，而一次拖放结束通常会连着
    /// 上报 exited 与 ended 两次，重复赋值会让整窗白跑一遍布局与高亮重建
    func setFileDropTargeted(_ active: Bool) {
        guard isFileDropTargeted != active else { return }
        isFileDropTargeted = active
    }

    /// 拖入文件的统一入口：编辑区与主栏的投放都走这里。
    /// 目录与明确的非文本类型在入口处过滤，被拒的项目汇总成一次提示；
    /// 其余交给统一打开入口——查重与符号链接解析都在那里，不在这里另立一份
    func openDroppedFiles(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls where url.isFileURL {
            guard Self.isOpenableByDrop(url) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            open(url: url)
        }
        guard !rejected.isEmpty else { return }
        presentNotice(title: "已跳过 \(rejected.count) 个项目",
                      message: "下面这些不能打开为文稿（目录、图片、影音、压缩包等）：\n"
                          + rejected.joined(separator: "\n"))
    }

    /// 拖入的项目能否作为文稿打开：目录一律不能；明确的非文本类型（图片 / 影音 / 压缩包 /
    /// 磁盘映像 / 可执行文件 / PDF）拒绝，免得建出一屏乱码标签。类型判不出来时放行——
    /// 没有扩展名的文本文件（Makefile 这类）不该被挡在外面，打开后的解码路径本来就能兜底
    private static func isOpenableByDrop(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return false }
        guard let type = values?.contentType else { return true }
        let nonText: [UTType] = [.image, .audio, .movie, .archive, .diskImage, .executable, .pdf]
        return !nonText.contains { type.conforms(to: $0) }
    }

    // MARK: - 文件身份（KTD16）

    /// 文件身份的统一判定：规范化路径并把符号链接解析到真实文件。
    /// 解析后的地址即标签的文件——经链接写盘会把链接本身替换成普通文件；
    /// 打开、另存为与后续的拖入都必须经这一处取身份，不做只比字符串的第二套判断，
    /// 否则同一个文件会被两张标签持有，其中一个还会被外部改动检测静默重载
    static func fileIdentity(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// 该路径已由哪张标签持有；nil 表示尚无标签持有（KTD16：一个已解析路径只对应一个标签）
    func tabIndex(holdingFileAt url: URL) -> Int? {
        let identity = Self.fileIdentity(url)
        return tabs.firstIndex { tab in
            guard let bound = tab.fileURL else { return false }
            return Self.fileIdentity(bound) == identity
        }
    }

    // MARK: - 批量与收尾

    /// 保存全部（R10）：一次写盘所有有改动且已绑定文件的标签。
    /// 未标题的脏标签没有可写的文件，跳过并在末尾汇总提示一次；
    /// 任一次写盘失败或用户取消即停止，后面的标签保持原样
    func saveAll() {
        let skippedUntitled = tabs.filter { $0.isDirty && $0.fileURL == nil }.count
        for tab in tabs where tab.isDirty && tab.fileURL != nil {
            guard save(tab: tab) else { return }
        }
        guard skippedUntitled > 0 else { return }
        presentNotice(title: "已跳过未标题标签",
                      message: "有 \(skippedUntitled) 个未标题标签存在未保存的改动，它们还没有对应的文件。"
                          + "请先对这些标签使用「另存为…」指定文件。")
    }

    /// 标签右键菜单五项关闭的作用集合（KTD17 / R11）：以被右键的那张标签为「当前」一次算清，
    /// 调用方按集合是否为空决定置灰——置灰判定与作用集合共用这一份计算，
    /// 不在视图层另算一份，否则会出现「亮着却无事可做」的项
    struct TabCloseTargets {
        let current: [Int]
        let others: [Int]
        let left: [Int]
        let right: [Int]
        let all: [Int]
    }

    /// 算出某项关闭的作用集合；索引越界时全部为空（调用方据此全部置灰）
    func tabCloseTargets(at index: Int) -> TabCloseTargets {
        guard tabs.indices.contains(index) else {
            return TabCloseTargets(current: [], others: [], left: [], right: [], all: [])
        }
        let all = Array(tabs.indices)
        return TabCloseTargets(current: [index],
                               others: all.filter { $0 != index },
                               left: Array(all.prefix(index)),
                               right: index + 1 < tabs.count ? Array(all.suffix(from: index + 1)) : [],
                               all: all)
    }

    /// 在 Finder 中定位标签对应的文件（R28 / KTD18）：走系统的文件定位接口（打开所在文件夹并选中）。
    /// 路径取标签打开时已解析的地址（KTD16），未标题标签没有文件可定位；
    /// 文件已从磁盘消失时给一次明确提示——定位随时可能失败，静默无反应会被当成菜单坏了
    func revealInFinder(_ tab: EditorTab?) {
        guard let tab, let url = tab.fileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentErrorAlert(title: "找不到文件",
                              message: "“\(url.lastPathComponent)”已不在原位置：\(url.path)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 关闭全部标签页：作用集合是当前全部标签，收尾后只剩一个空标签（窗口保留）
    func closeAllTabs() {
        closeTabs(at: Array(tabs.indices))
    }

    /// 关闭族的统一收尾路径（KTD17）：传入作用集合的索引快照 → 逐个确认有改动的标签 →
    /// 全部通过后统一关闭；任一取消（含保存被取消、写盘失败）即中止整轮。
    /// 确认期间不动任何标签、也不动恢复区条目，所以取消后的现场与发起前一致；
    /// 标签右键菜单的五项关闭复用同一入口，各自只是作用集合不同。
    /// `selecting` 是发起这次关闭的那张标签（右键点中的那张）：它还在时收尾后成为活动标签，
    /// 它已被关掉时沿用上面的索引落位规则
    func closeTabs(at indices: [Int], selecting tab: EditorTab? = nil) {
        let targets = Array(Set(indices)).sorted().compactMap { tabs.indices.contains($0) ? tabs[$0] : nil }
        guard !targets.isEmpty else { return }

        guard confirmDirtyTabs(targets) else { return }
        finalizeClosedTabs(targets)
        if let tab, let index = tabs.firstIndex(where: { $0 === tab }) {
            selectedTabIndex = index
        }
    }

    /// 逐个确认有改动的标签：任一取消（含保存面板被取消、写盘失败）即中止，
    /// 返回是否全部通过。关闭族与退出保护共用这一份确认循环，各自只负责通过之后的终态动作
    func confirmDirtyTabs(_ tabs: [EditorTab]) -> Bool {
        for tab in tabs where tab.isDirty {
            switch confirmSave(of: tab) {
            case .save:
                guard save(tab: tab) else { return false } // 保存被取消 / 失败：整轮中止
            case .discard:
                break
            case .cancel:
                return false
            }
        }
        return true
    }

    func closeSelectedTab() {
        guard tabs.indices.contains(selectedTabIndex) else { return }
        closeTab(at: selectedTabIndex)
    }

    func closeTab(at index: Int) {
        closeTabs(at: [index])
    }

    /// 关闭族的批量终态动作：只有这里真正移除标签——先摘掉自动保存与恢复区订阅，再统一移除，
    /// 最后沿用既有 closeTab 的索引规则落位活动标签；标签集合不会被清空，始终保留一个空标签。
    /// 恢复区条目的删除是批量终态动作，接在这一处、不进入逐个确认的过程（KTD17）
    private func finalizeClosedTabs(_ closed: [EditorTab]) {
        guard !closed.isEmpty else { return }
        let closing = Set(closed.map(\.id))
        for id in closing {
            autosaveCancellables.removeValue(forKey: id)
            recoveryCancellables.removeValue(forKey: id)
        }
        // 关闭标签且确认不保存或已保存：这些标签的恢复区条目到此离开（HTD 的第二个出口）
        for tab in closed {
            retireRecoveryEntry(for: tab)
        }

        let previous = tabs
        let previousSelection = selectedTabIndex
        tabs.removeAll { closing.contains($0.id) }

        if tabs.isEmpty {
            // 始终保留一个空标签，与 Notepad++ 行为一致
            addUntitledTab()
        } else if previous.indices.contains(previousSelection),
                  let kept = tabs.firstIndex(where: { $0 === previous[previousSelection] }) {
            // 活动标签没被关掉：让它继续是活动标签（与 closeTab 关非活动标签时的落位一致）
            selectedTabIndex = kept
        } else {
            // 活动标签被关掉：落到它原位置右侧的第一张存留标签，右侧没有则落到最后一张
            let survivingBefore = previous.prefix(previousSelection).filter { !closing.contains($0.id) }.count
            selectedTabIndex = min(survivingBefore, tabs.count - 1)
        }
        persistSession()
    }

    /// 退出前的未保存保护：逐个确认有更改的标签，任一标签被取消（含保存面板被取消、
    /// 写盘失败）即中止退出。与 closeTab 共用确认循环，保证两个入口语义一致
    func confirmTermination() -> Bool {
        guard confirmDirtyTabs(tabs) else { return false }
        // 全部确认通过：本次运行的未标题内容到此离开恢复区（HTD 的「正常退出」出口）。
        // 逐个确认期间一条都不动——取消退出时现场必须与发起前一致（KTD17）
        for tab in tabs {
            retireRecoveryEntry(for: tab)
        }
        return true
    }

    /// 把当前文件标签写入 UserDefaults，供下次启动恢复
    func persistSession() {
        UserDefaults.standard.set(tabs.compactMap(\.fileURL).map(\.absoluteString),
                                  forKey: Self.sessionKey)
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
        let source = tab.bridge.textSource?() ?? (selection: "", fullText: tab.text)
        tools.seed(from: source.selection.isEmpty ? source.fullText : source.selection)
    }

    /// 把工具结果写回编辑器：replaceSelection 为真替换选区（无选区则插入光标处），为假替换全文
    func writeBackToolsResult(_ text: String, replaceSelection: Bool, tab: EditorTab) {
        tab.bridge.writeBack?(text, replaceSelection)
    }

    // MARK: - 行操作

    /// 对当前标签执行一项行操作：目标行范围与写回都在视图层完成（撤销协议路径必须在视图层走），
    /// 标签还没有编辑视图时无动作
    func applyLineOperation(_ kind: LineOperationKind) {
        selectedTab?.bridge.lineOperation?(kind)
    }

    /// 行操作在当前标签上是否可用：没有打开的标签一律不可用；
    /// 注释类操作还要求当前语法有行注释符号（纯文本、HTML、JSON 置灰），
    /// 与抽屉里操作按钮的可用性同一个口径
    func isLineOperationAvailable(_ kind: LineOperationKind) -> Bool {
        guard let tab = selectedTab else { return false }
        return !kind.requiresLineComment || tab.language.lineComment != nil
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
        tab.bridge.goToLine?(line)
    }

    // MARK: - Private

    /// 记录最近文件并刷新菜单数据源
    func recordRecent(_ url: URL) {
        recentFiles = RecentFiles.record(url)
    }

    enum SaveChoice { case save, discard, cancel }

    func confirmSave(of tab: EditorTab) -> SaveChoice {
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

    func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    /// 提示性说明：只为把一批操作的结果交代清楚（如保存全部跳过了哪些标签），不带错误着色
    func presentNotice(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
