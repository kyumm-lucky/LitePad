import AppKit
import Combine

/// 显式保存、另存为、自动写盘与保存前清理
extension EditorSession {
    /// 落盘失败的原因：两种都必须不写盘、不改基准、不标记干净
    enum WriteFailure {
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
    func saveAs(tab: EditorTab) -> Bool {
        let panel = NSSavePanel()
        // 默认文件名取标签的标题（R8）：未标题标签是「新文件2」，就默认存成「新文件2.txt」
        panel.nameFieldStringValue = tab.fileURL?.lastPathComponent ?? "\(tab.displayName).txt"
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
    func finishSave(tab: EditorTab, to url: URL) -> Bool {
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
    func prepareSaveCleanup(for tab: EditorTab) -> SaveCleanupOutcome {
        let settings = AppSettings.shared
        guard settings.saveCleanupApplies(to: tab.language) else { return .done }

        if tab === selectedTab, let cleanup = tab.bridge.saveCleanup {
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
    func abortSave(tab: EditorTab, reason: String) -> Bool {
        tab.writeFailureReported = true
        presentErrorAlert(title: "无法保存文件", message: reason + WriteFailure.dirtyNote)
        return false
    }

    /// 统一落盘：统一换行符 → 按所选编码真实转码（无法表示正文即拒绝写入，KTD4）→ 原子写 → 改绑基准。
    /// 只返回失败原因，提示由各入口按自己的打扰口径处理；失败时不写盘、不改基准、不标记干净
    func write(tab: EditorTab, to url: URL) -> WriteFailure? {
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
        // 标签一旦绑定了文件就不再是未标题文稿，恢复区里的条目就此离开（HTD 的
        // 「另存为成功并绑定文件」出口；显式保存与另存为共用这一个落点）
        retireRecoveryEntry(for: tab)
        persistSession()
        return nil
    }

    /// 文件标签的自动保存：文本变化 1 秒后写盘（可在设置关闭；未标题文稿不参与）。
    /// 自动保存不做保存时清理（KTD5），失败也只在首次给一次显著提示
    func installAutosave(for tab: EditorTab) {
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
    func reportAutosaveFailure(_ failure: WriteFailure, tab: EditorTab) {
        guard !tab.writeFailureReported else { return }
        tab.writeFailureReported = true
        presentErrorAlert(title: "自动保存失败",
                          message: "“\(tab.displayName)”未能自动写盘。\(failure.message)"
                              + WriteFailure.dirtyNote + "请手动保存或先处理该问题。")
    }
}
