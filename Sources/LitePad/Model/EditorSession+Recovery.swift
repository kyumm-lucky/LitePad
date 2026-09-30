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
        guard hasPendingRecovery else { return }
        hasPendingRecovery = false
        let entries = recovery.allEntries()
        guard !entries.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "有 \(entries.count) 份未保存的未标题文稿"
        // 放弃是不可逆的批量删除，必须把名单列出来：不列名单的一键清空会删掉多份找不回的内容
        alert.informativeText = "上次运行结束时这些文稿还没有存到文件，已留在恢复区：\n\n"
            + entries.map { "・\($0.title)" }.joined(separator: "\n")
            + "\n\n「恢复」会把它们重新建成标签页；「放弃并删除」会永久删除这 \(entries.count) 份内容，无法找回。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "放弃并删除")
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
            presentErrorAlert(title: "恢复区无法写入",
                              message: message + "\n未标题文稿的正文没有进入恢复区："
                                  + "在这些内容写入磁盘之前，异常终止（崩溃或强制退出）后会丢失。"
                                  + "请手动保存这些文稿。")
        case .readFailed(let message):
            presentErrorAlert(title: "恢复区读不出来",
                              message: message + "\n本次运行不会改写恢复区文件，以免覆盖仍在磁盘上的草稿。"
                                  + "未标题文稿在这次运行里没有恢复区保护，请手动保存。")
        case .contentCorrupted:
            presentErrorAlert(title: "恢复区内容已损坏",
                              message: "恢复区文件读得出，但不是可解析的条目表。"
                                  + "未标题草稿无法从这份文件恢复；下次写入会用新的条目表替换它。")
        case .entryTooLarge(let title, let bytes, let limit):
            presentErrorAlert(title: "恢复区没有保护“\(title)”",
                              message: "这篇文稿的正文有 \(Self.byteCountText(bytes))，"
                                  + "超过恢复区单条上限（\(Self.byteCountText(limit))）。"
                                  + "它不会被写入恢复区，异常终止后无法恢复，请手动保存。")
        case .evicted(let title, let limit):
            presentNotice(title: "恢复区已满",
                          message: "恢复区最多保留 \(limit) 条未标题文稿，"
                              + "最旧的“\(title)”已被移出：异常终止后无法恢复它，请手动保存。")
        }
    }

    /// 字节数的展示口径：提示里只说大概量级
    static func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
