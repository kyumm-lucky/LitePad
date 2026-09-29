import AppKit
import Combine
import UniformTypeIdentifiers

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
    /// 是否有文件正被拖在窗口上（驱动接收提示）：编辑区由编辑视图在 AppKit 层上报，
    /// 标签栏与状态栏由主栏的投放目标上报
    @Published var isFileDropTargeted = false
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
    private static func fileIdentity(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// 该路径已由哪张标签持有；nil 表示尚无标签持有（KTD16：一个已解析路径只对应一个标签）
    private func tabIndex(holdingFileAt url: URL) -> Int? {
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

    /// 关闭全部标签页：作用集合是当前全部标签，收尾后只剩一个空标签（窗口保留）
    func closeAllTabs() {
        closeTabs(at: Array(tabs.indices))
    }

    /// 关闭族的统一收尾路径（KTD17）：传入作用集合的索引快照 → 逐个确认有改动的标签 →
    /// 全部通过后统一关闭；任一取消（含保存被取消、写盘失败）即中止整轮。
    /// 确认期间不动任何标签、也不动恢复区条目，所以取消后的现场与发起前一致；
    /// 标签右键菜单的五项关闭复用同一入口，各自只是作用集合不同
    func closeTabs(at indices: [Int]) {
        let targets = Array(Set(indices)).sorted().compactMap { tabs.indices.contains($0) ? tabs[$0] : nil }
        guard !targets.isEmpty else { return }

        for tab in targets where tab.isDirty {
            switch confirmSave(of: tab) {
            case .save:
                guard save(tab: tab) else { return } // 保存被取消 / 失败：整轮中止
            case .discard:
                break
            case .cancel:
                return
            }
        }
        finalizeClosedTabs(targets)
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
        // 绑定前按 KTD16 的统一规则查重：目标路径已由别的标签持有时中止，
        // 既不改本标签的绑定，也不动对方标签
        let target = Self.fileIdentity(url)
        if let holder = tabIndex(holdingFileAt: target), tabs[holder] !== tab {
            presentErrorAlert(title: "无法保存到该文件",
                              message: "“\(target.lastPathComponent)”已由标签“\(tabs[holder].displayName)”打开。"
                                  + "请换一个文件名，或先关闭那个标签。")
            return false
        }
        // 清理放在面板确认之后：取消另存为不该改动正文
        let ok = finishSave(tab: tab, to: target)
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
        closeTabs(at: [index])
    }

    /// 关闭族的批量终态动作：只有这里真正移除标签——先摘掉自动保存订阅，再统一移除，
    /// 最后沿用既有 closeTab 的索引规则落位活动标签；标签集合不会被清空，始终保留一个空标签。
    /// 恢复区条目的删除是批量终态动作，U6 接在这一处，不进入逐个确认的过程
    private func finalizeClosedTabs(_ closed: [EditorTab]) {
        guard !closed.isEmpty else { return }
        let closing = Set(closed.map(\.id))
        for id in closing {
            autosaveCancellables.removeValue(forKey: id)
        }

        let previous = tabs
        let previousSelection = selectedTabIndex
        tabs.removeAll { closing.contains($0.id) }

        if tabs.isEmpty {
            let empty = EditorTab() // 始终保留一个空标签，与 Notepad++ 行为一致
            tabs = [empty]
            selectedTabIndex = 0
            installAutosave(for: empty)
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
                // 重载成功即换了基准（markSaved 已记下新的磁盘时间），没有换掉内容才需要自己记
                if reload(tab: tab, from: url) == nil { continue }
            case .ask:
                if confirmReload(of: tab), reload(tab: tab, from: url) == nil { continue }
            case .keepVersion:
                break
            }
            // 没有真的换掉内容（用户选择保留当前版本，或重载失败）：记下磁盘时间，
            // 避免每次应用激活都对同一份读不进来的内容重复提示 / 重复重试
            tab.fileModificationDate = diskDate
        }
    }

    /// 外部改动重载：读盘 → 宽容解码 → 字节往返校验 → 设为干净基准，与显式重读共用同一条链路。
    /// 失败返回原因且保持原样，由调用方静默处理——自动发生的重载失败不该弹模态框打断用户
    private func reload(tab: EditorTab, from url: URL) -> ReloadFailure? {
        // 整串改动与显式重读同一落点：有视图就经它走撤销协议（KTD14），没视图才改模型文本
        loadBaseline(into: tab, from: url, strategy: .tolerant) { [weak self, weak tab] newText in
            guard let self, let tab else { return false }
            return self.replaceWholeText(newText, in: tab)
        }
    }

    // MARK: - 按编码重读（R5）

    /// 按指定编码重新从磁盘读取当前标签：改错编码时无需关闭标签或重启。
    /// 与状态栏编码下拉里「只改保存编码」的选项并存——选项只改保存编码，这里才真的重读正文。
    /// 显式重读无视「文稿被其他应用更改」的既有策略：用户发的指令优先
    func reloadSelectedTab(with encoding: TextEncoding) {
        guard let tab = selectedTab, let url = tab.fileURL else { return }
        // 组字期间拒绝（与编辑视图里两处组字保护同一口径）：组字结束时视图会把自身内容推回模型，
        // 刚重读的正文会被组字前的旧内容覆盖，并在一秒后被自动写盘写回文件
        guard tab.compositionStateProvider?() != true else {
            NSSound.beep()
            return
        }
        // 有未保存改动先走三键确认：取消（含保存被取消、写盘失败）即中止，什么都不改
        if tab.isDirty {
            switch confirmSave(of: tab) {
            case .save:
                guard save(tab: tab) else { return }
            case .discard:
                break
            case .cancel:
                return
            }
        }
        // 用户指定的编码走严格解码：选择错了就报错，绝不宽容兜底成一篇看似合法的乱码
        let failure = loadBaseline(into: tab, from: url, strategy: .strict(encoding),
                                   replaceText: { [weak tab] newText in
                                       guard let tab else { return false }
                                       return replaceWholeText(newText, in: tab)
                                   })
        guard let failure else { return }
        // 失败时不把指定编码留在保存编码上（KTD4：不把指定编码绑成保存编码）：这个编码已经证明
        // 读不通这个文件，留着它只会让下一次显式保存把认得出的正文改写成另一个编码的字节
        tab.encoding = tab.savedEncoding
        presentErrorAlert(title: "无法按此编码重新载入", message: failure.message)
    }

    /// 重读正文的落点：视图存在时把整串正文交给编辑视图走撤销协议（KTD14），
    /// 视图已拆除时直接改模型文本（那时没有撤销栈要清），并按 KTD15 重算查找匹配区间
    private func replaceWholeText(_ newText: String, in tab: EditorTab) -> Bool {
        guard let replaceText = tab.reloadTextHandler else {
            tab.text = newText
            tab.refreshMatches()
            return true
        }
        return replaceText(newText)
    }

    /// 「读盘 → 解码 → 字节往返校验 → 设为干净基准」的唯一实现（KTD4）：
    /// 显式重读与外部改动重载共用它——任何建立「保存基准」的转换都必须可失败。
    /// 失败返回原因，且标签的内容、编码、脏标记三者一律不变：错误解码出来的正文一旦成为
    /// 新的干净基准，下一次敲键或自动写盘就会把乱码覆盖回原文件。
    /// `strategy` 决定解码口径；`replaceText` 是正文替换的落点，返回 false 表示落点拒绝替换
    private func loadBaseline(into tab: EditorTab, from url: URL,
                              strategy: DecodeStrategy,
                              replaceText: (String) -> Bool) -> ReloadFailure? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(error)
        }

        let decoded: (text: String, encoding: TextEncoding)
        switch strategy {
        case .strict(let encoding):
            guard let text = encoding.decodeStrictly(data) else { return .undecodable(encoding) }
            decoded = (text, encoding)
        case .tolerant:
            let settings = AppSettings.shared
            decoded = TextEncoding.decode(data,
                                          priority: settings.encodingPriority,
                                          respectCharsetDeclaration: settings.respectCharsetDeclaration)
        }
        // 字节往返校验（KTD4）：读出的正文按同一编码再编码必须与磁盘字节一致，否则保存会改写文件
        guard decoded.encoding.roundTrips(decoded.text, with: data) else {
            return .roundTripMismatch(decoded.encoding)
        }
        guard replaceText(decoded.text) else { return .replaceRejected }

        tab.encoding = decoded.encoding
        tab.lineEnding = LineEnding.detect(in: decoded.text)
        // 正文、编码、换行符三者一起成为新基准：必须全部落齐后才标记干净
        tab.markSaved(to: url)
        return nil
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

    /// 重读磁盘时的解码口径
    private enum DecodeStrategy {
        /// 显式重读：按用户指定的编码严格解码，跳过 BOM 嗅探与文稿内的编码声明
        case strict(TextEncoding)
        /// 外部改动重载：继续用宽容解码，优先保证读得出内容（与「打开」同一口径）
        case tolerant
    }

    /// 建立保存基准的失败原因（KTD4）：每一种都不写盘、不改内容、不改编码、不标记干净
    private enum ReloadFailure {
        /// 读盘失败（文件已被删除、权限不足等）
        case unreadable(Error)
        /// 严格解码失败：所选编码读不通磁盘上的字节
        case undecodable(TextEncoding)
        /// 字节往返校验失败：读出的正文按同一编码再编码与磁盘字节不一致
        case roundTripMismatch(TextEncoding)
        /// 编辑视图拒绝了整串替换（撤销协议未通过）
        case replaceRejected

        /// 面向用户的失败说明：显式重读据此报错，外部改动重载只关心「有没有失败」
        var message: String {
            switch self {
            case .unreadable(let error):
                return "读不到磁盘上的内容：\(error.localizedDescription)"
            case .undecodable(let encoding):
                return "磁盘上的字节无法用「\(encoding.displayName)」解码，这个编码读不出原文。"
                    + "为避免读出错版正文后被保存覆盖回文件，本次重读已中止："
                    + "正文、编码与保存基准都保持原样（编码已恢复为原来的保存编码）。请换一个编码再试。"
            case .roundTripMismatch(let encoding):
                return "按「\(encoding.displayName)」读出的正文再编码回去与磁盘字节不一致，"
                    + "这个编码认不出原文（很可能是选错了编码）。"
                    + "为避免之后的保存把文件改写成乱码，本次重读已中止："
                    + "正文、编码与保存基准都保持原样（编码已恢复为原来的保存编码）。请换一个编码再试。"
            case .replaceRejected:
                return "编辑视图没有接受这次整串替换，正文与编码都保持原样。"
            }
        }
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

    /// 提示性说明：只为把一批操作的结果交代清楚（如保存全部跳过了哪些标签），不带错误着色
    private func presentNotice(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
