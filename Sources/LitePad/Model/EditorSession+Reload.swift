import AppKit

/// 外部改动重载与按编码重读（R5）
extension EditorSession {
    /// 重读磁盘时的解码口径
    enum DecodeStrategy {
        /// 显式重读：按用户指定的编码严格解码，跳过 BOM 嗅探与文稿内的编码声明
        case strict(TextEncoding)
        /// 外部改动重载：继续用宽容解码，优先保证读得出内容（与「打开」同一口径）
        case tolerant
    }

    /// 建立保存基准的失败原因（KTD4）：每一种都不写盘、不改内容、不改编码、不标记干净
    enum ReloadFailure {
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
    func reload(tab: EditorTab, from url: URL) -> ReloadFailure? {
        // 整串改动与显式重读同一落点：有视图就经它走撤销协议（KTD14），没视图才改模型文本
        loadBaseline(into: tab, from: url, strategy: .tolerant)
    }

    // MARK: - 按编码重读（R5）

    /// 按指定编码重新从磁盘读取当前标签：改错编码时无需关闭标签或重启。
    /// 与状态栏编码下拉里「只改保存编码」的选项并存——选项只改保存编码，这里才真的重读正文。
    /// 显式重读无视「文稿被其他应用更改」的既有策略：用户发的指令优先
    func reloadSelectedTab(with encoding: TextEncoding) {
        guard let tab = selectedTab, let url = tab.fileURL else { return }
        // 组字期间拒绝（与编辑视图里两处组字保护同一口径）：组字结束时视图会把自身内容推回模型，
        // 刚重读的正文会被组字前的旧内容覆盖，并在一秒后被自动写盘写回文件
        guard tab.bridge.isComposing?() != true else {
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
        let failure = loadBaseline(into: tab, from: url, strategy: .strict(encoding))
        guard let failure else { return }
        // 失败时不把指定编码留在保存编码上（KTD4：不把指定编码绑成保存编码）：这个编码已经证明
        // 读不通这个文件，留着它只会让下一次显式保存把认得出的正文改写成另一个编码的字节
        tab.encoding = tab.savedEncoding
        presentErrorAlert(title: "无法按此编码重新载入", message: failure.message)
    }

    /// 重读正文的落点：视图存在时把整串正文交给编辑视图走撤销协议（KTD14），
    /// 视图已拆除时直接改模型文本（那时没有撤销栈要清），并按 KTD15 重算查找匹配区间
    func replaceWholeText(_ newText: String, in tab: EditorTab) -> Bool {
        guard let replaceText = tab.bridge.reloadText else {
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
    /// `strategy` 决定解码口径；正文替换经 `replaceWholeText` 落到视图或模型（KTD14）
    func loadBaseline(into tab: EditorTab, from url: URL,
                              strategy: DecodeStrategy) -> ReloadFailure? {
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
        guard replaceWholeText(decoded.text, in: tab) else { return .replaceRejected }

        tab.encoding = decoded.encoding
        tab.lineEnding = LineEnding.detect(in: decoded.text)
        // 正文、编码、换行符三者一起成为新基准：必须全部落齐后才标记干净
        tab.markSaved(to: url)
        return nil
    }

    func confirmReload(of tab: EditorTab) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(tab.displayName)”已被其他程序修改"
        alert.informativeText = "是否重新载入磁盘上的版本？当前内容将被替换。"
        alert.addButton(withTitle: "重新载入")
        alert.addButton(withTitle: "保留当前版本")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
