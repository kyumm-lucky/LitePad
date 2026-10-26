import AppKit
import Combine

/// 未标题文稿的恢复区订阅、启动提示与条目生命周期
extension EditorSession {
    // MARK: - 恢复区（R6 / R7）

    /// 未标题标签的恢复区写入：照自动保存的形态，正文停止变化一秒后落盘。
    /// 会话恢复只记文件路径，未标题正文只能走这条并列通道（KTD3）
    func installRecovery(for tab: EditorTab) {
        recoveryCancellables[tab.id] = tab.$text
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink(receiveValue: { [weak self, weak tab] _ in
                Task { @MainActor in
                    guard let self, let tab else { return }
                    self.syncRecoveryEntry(for: tab)
                }
            })
    }

    /// 一次去抖后的同步：正文非空才写入，正文被清空则删除条目（HTD 的四个删除出口之一）。
    /// 已绑定文件的标签不写恢复区 —— 它不是未标题文稿，收尾也已经在绑定那一刻做过
    func syncRecoveryEntry(for tab: EditorTab) {
        guard let title = tab.untitledTitle, tab.fileURL == nil else { return }
        if tab.text.isEmpty {
            // 只删自己写过的条目：同名条目可能属于上一次运行的文稿或其他活标签
            //（恢复区按稳定标题为键），刚建出的空标签没有资格把它删掉
            guard titleOwners[title] == tab.id else { return }
            titleOwners.removeValue(forKey: title)
            recovery.remove(title: title)
            return
        }
        recovery.write(RecoveryEntry(title: title, text: tab.text, savedAt: Date()), writer: tab.id)
        titleOwners[title] = tab.id
    }

    // MARK: - 已命名文稿的恢复草稿

    /// 已命名标签的草稿写入：与自动保存并列的兜底，正文停止变化一秒后落盘
    func installNamedRecovery(for tab: EditorTab) {
        namedRecoveryCancellables[tab.id] = tab.$text
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink(receiveValue: { [weak self, weak tab] _ in
                Task { @MainActor in
                    guard let self, let tab else { return }
                    self.syncNamedRecoveryEntry(for: tab)
                }
            })
    }

    /// 一次去抖后的同步：正文与保存基准一致或为空时删除条目，否则写入草稿。
    /// 启动恢复提示处理完之前不写也不删 —— 否则订阅的初始值会在用户回答提示前
    /// 把待恢复的条目当成「已同步」清掉
    func syncNamedRecoveryEntry(for tab: EditorTab) {
        guard !hasPendingNamedRecovery else { return }
        guard let url = tab.fileURL else { return }
        if tab.text.isEmpty || tab.text == tab.savedText {
            namedRecovery.remove(path: url.path)
            return
        }
        namedRecovery.write(path: url.path, text: tab.text)
    }

    /// 一个标签彻底结束时把它的恢复区条目移出（带墓碑，拦下去抖窗口里的在途写入）。
    /// 三个结束出口共用这一处：关闭标签、正常退出确认通过、另存为绑定文件。
    /// 只有条目真的是这个标签写的才删：同名条目可能已经换了主人（旧标签另存为后释放了标题、
    /// 新标签拿到同名标题并写入），此时删除会连新标签的正文一起删掉；不是自己的条目就只立墓碑，
    /// 让这个写入方的在途写入作废，条目本身留给它的真正主人
    func retireRecoveryEntry(for tab: EditorTab) {
        guard let title = tab.untitledTitle else { return }
        guard titleOwners[title] == tab.id else {
            recovery.tombstone(writer: tab.id)
            return
        }
        titleOwners.removeValue(forKey: title)
        recovery.retire(title: title, writer: tab.id)
    }

    // MARK: - 启动恢复（R6 / R7）

    /// 启动时的恢复入口：恢复区非空就提示恢复或放弃（R7）。
    /// **必须在首帧之后调用** —— 会话构造期还没有窗口，此时弹模态会抢走随后用于设置窗口尺寸与标题的目标窗口。
    /// 与两项启动设置无关：只要恢复区非空就提示
    func presentRecoveryPromptIfNeeded() {
        // 读失败与内容损坏在构造期记下，首帧之后才弹：构造期弹模态会抢走窗口
        if let alert = recovery.takeLoadAlert() {
            reportRecoveryAlert(alert)
        }
        if hasPendingRecovery {
            hasPendingRecovery = false
            let entries = recovery.allEntries()
            if !entries.isEmpty {
                let alert = NSAlert()
                alert.messageText = L10n.format("有 %d 份未保存的未标题文稿", entries.count)
                // 放弃是不可逆的批量删除，必须把名单列出来：不列名单的一键清空会删掉多份找不回的内容
                alert.informativeText = L10n.t("上次运行结束时这些文稿还没有存到文件，已留在恢复区：\n\n")
                    + entries.map { "・\($0.title)" }.joined(separator: "\n")
                    + L10n.format("\n\n「恢复」会把它们重新建成标签页；「放弃并删除」会永久删除这 %d 份内容，无法找回。", entries.count)
                alert.addButton(withTitle: L10n.t("恢复"))
                alert.addButton(withTitle: L10n.t("放弃并删除"))
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    restore(entries)
                case .alertSecondButtonReturn:
                    recovery.removeAll()
                default:
                    break
                }
                // 放弃之后窗口不该空着；恢复的场合已经有标签了，这里只会走「放弃」这一支
                fillLaunchPlaceholderIfNeeded()
            }
        }
        // 未标题恢复处理完再处理已命名草稿：两条通道各自独立，互不阻塞
        presentNamedRecoveryPromptIfNeeded()
    }

    /// 按恢复区里的条目建标签（R6 / R8）：沿用存下来的标题，追加在现有标签之后。
    /// 内容不带保存基准（`savedText` 传空串），因此建出来就是未保存状态 —— 否则正常退出
    /// 不会向用户确认、条目也不会删除，内容会在退出时无声消失，而且每次启动都重复提示
    func restore(_ entries: [RecoveryEntry]) {
        var firstRestored: EditorTab?
        for entry in entries {
            let tab = addUntitledTab(text: entry.text, savedText: "", title: entry.title)
            // 恢复出来的标签就是它自己那条条目的所有者：不登记的话，在这张标签里清空正文时
            // 会被归属校验挡下，条目留在盘上，异常终止后会复活用户已经删掉的内容
            titleOwners[entry.title] = tab.id
            if firstRestored == nil {
                firstRestored = tab
            }
        }
        // 恢复出来的第一张成为活动标签；条目先不清空——新标签的重新写入是去抖的，
        // 提前清空会在窗口期内崩溃时真丢内容
        if let firstRestored, let index = tabs.firstIndex(where: { $0 === firstRestored }) {
            selectedTabIndex = index
        }
    }

    /// 启动占位标签：恢复提示处理完后窗口不该空着（放弃、或提示被关掉时兜底）。
    /// 与会话恢复同一条口径：只有「启动时创建新文稿」才建
    func fillLaunchPlaceholderIfNeeded() {
        guard tabs.isEmpty, AppSettings.shared.launchAction == .newDocument else { return }
        addUntitledTab()
    }

    /// 恢复区的可见提示：上报由存储侧按去重键收敛（同一条连续出现只弹一次），
    /// 这里只按类型给文案
    func reportRecoveryAlert(_ alert: RecoveryAlert) {
        switch alert {
        case .writeFailed(let message):
            presentErrorAlert(title: L10n.t("恢复区无法写入"),
                              message: message + L10n.t("\n未标题文稿的正文没有进入恢复区：")
                                  + L10n.t("在这些内容写入磁盘之前，异常终止（崩溃或强制退出）后会丢失。")
                                  + L10n.t("请手动保存这些文稿。"))
        case .readFailed(let message):
            presentErrorAlert(title: L10n.t("恢复区读不出来"),
                              message: message + L10n.t("\n本次运行不会改写恢复区文件，以免覆盖仍在磁盘上的草稿。")
                                  + L10n.t("未标题文稿在这次运行里没有恢复区保护，请手动保存。"))
        case .contentCorrupted:
            presentErrorAlert(title: L10n.t("恢复区内容已损坏"),
                              message: L10n.t("恢复区文件读得出，但不是可解析的条目表。")
                                  + L10n.t("未标题草稿无法从这份文件恢复；下次写入会用新的条目表替换它。"))
        case .entryTooLarge(let title, let bytes, let limit):
            presentErrorAlert(title: L10n.format("恢复区没有保护“%@”", title),
                              message: L10n.format("这篇文稿的正文有 %@，", Self.byteCountText(bytes))
                                  + L10n.format("超过恢复区单条上限（%@）。", Self.byteCountText(limit))
                                  + L10n.t("它不会被写入恢复区，异常终止后无法恢复，请手动保存。"))
        case .evicted(let title, let limit):
            presentNotice(title: L10n.t("恢复区已满"),
                          message: L10n.format("恢复区最多保留 %d 条未标题文稿，", limit)
                              + L10n.format("最旧的“%@”已被移出：异常终止后无法恢复它，请手动保存。", title))
        }
    }

    /// 字节数的展示口径：提示里只说大概量级
    static func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - 已命名文稿的启动恢复

    /// 启动时的已命名草稿提示：必须在首帧之后调用（由 `presentRecoveryPromptIfNeeded` 串起来）
    func presentNamedRecoveryPromptIfNeeded() {
        if let alert = namedRecovery.takeLoadAlert() {
            reportNamedRecoveryAlert(alert)
        }
        guard hasPendingNamedRecovery else { return }
        hasPendingNamedRecovery = false
        let entries = namedRecovery.allEntries()
        guard !entries.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L10n.format("有 %d 份已命名文稿的未保存草稿", entries.count)
        alert.informativeText = L10n.t("上次运行异常结束时，这些文件在磁盘副本之后还有未保存的修改：\n\n")
            + entries.map { "・\($0.fileName)" }.joined(separator: "\n")
            + L10n.t("\n\n「恢复」会把草稿放回对应标签（不会自动写盘）；")
            + L10n.format("「放弃并删除」会永久删除这 %d 份草稿，无法找回。", entries.count)
        alert.addButton(withTitle: L10n.t("恢复"))
        alert.addButton(withTitle: L10n.t("放弃并删除"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            restoreNamed(entries)
        case .alertSecondButtonReturn:
            namedRecovery.removeAll()
        default:
            break
        }
        fillLaunchPlaceholderIfNeeded()
    }

    /// 把草稿放回标签：文件已打开就替换正文并标脏，未打开则按磁盘原文作保存基准建新标签；
    /// 草稿恢复出的标签停用自动保存，直到用户显式保存（避免恢复动作本身把文件覆盖掉）。
    /// 条目先保留 —— 标签会重新写入同一份内容，等保存 / 关闭 / 正常退出时再删
    func restoreNamed(_ entries: [NamedRecoveryEntry]) {
        var firstRestored: EditorTab?
        for entry in entries {
            let url = URL(fileURLWithPath: entry.path)
            if let index = tabIndex(holdingFileAt: url) {
                let tab = tabs[index]
                tab.text = entry.text
                tab.refreshMatches()
                tab.markRecoveryRestored()
                if firstRestored == nil { firstRestored = tab }
                continue
            }
            if let data = try? Data(contentsOf: url) {
                let settings = AppSettings.shared
                let (content, encoding) = TextEncoding.decode(
                    data,
                    priority: settings.encodingPriority,
                    respectCharsetDeclaration: settings.respectCharsetDeclaration)
                let tab = EditorTab(fileURL: url, text: entry.text, savedText: content,
                                    encoding: encoding,
                                    lineEnding: LineEnding.detect(in: content),
                                    recoveryRestored: true)
                addTab(tab)
                if firstRestored == nil { firstRestored = tab }
            } else {
                // 文件已不存在：内容仍要还给用户，建未标题标签承载，标题里带上原文件名
                let tab = addUntitledTab(text: entry.text, savedText: "",
                                         title: L10n.format("恢复的 %@", url.lastPathComponent))
                tab.markRecoveryRestored()
                if firstRestored == nil { firstRestored = tab }
            }
        }
        if let firstRestored, let index = tabs.firstIndex(where: { $0 === firstRestored }) {
            selectedTabIndex = index
        }
        persistSession()
    }

    /// 已命名恢复区的可见提示：按类型给文案，去重交给存储侧
    func reportNamedRecoveryAlert(_ alert: NamedRecoveryAlert) {
        switch alert {
        case .writeFailed(let message):
            presentErrorAlert(title: L10n.t("已命名文稿的恢复副本无法写入"),
                              message: message + L10n.t("\n自动保存之外的那份草稿没有进入恢复区：")
                                  + L10n.t("自动保存关闭或写盘失败时异常终止，未保存的修改会丢失。请手动保存这些文件。"))
        case .readFailed(let message):
            presentErrorAlert(title: L10n.t("已命名文稿的恢复副本读不出来"),
                              message: message + L10n.t("\n本次运行不会改写该文件，以免覆盖仍在磁盘上的草稿。"))
        case .contentCorrupted:
            presentErrorAlert(title: L10n.t("已命名文稿的恢复副本已损坏"),
                              message: L10n.t("恢复文件读得出，但不是可解析的条目表；这些草稿无法恢复，下次写入会替换它。"))
        case .entryTooLarge(let name, let bytes, let limit):
            presentErrorAlert(title: L10n.format("恢复副本没有保护“%@”", name),
                              message: L10n.format("这篇文稿的正文有 %@，", Self.byteCountText(bytes))
                                  + L10n.format("超过单条上限（%@）。", Self.byteCountText(limit))
                                  + L10n.t("它不会被写入恢复区，异常终止后无法恢复，请手动保存。"))
        case .evicted(let name, let limit):
            presentNotice(title: L10n.t("恢复副本已满"),
                          message: L10n.format("最多保留 %d 份已命名文稿草稿，最旧的“%@”已被移出；请手动保存。", limit, name))
        }
    }
}
