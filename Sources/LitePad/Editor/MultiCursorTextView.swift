import AppKit

/// 多光标：Cmd+单击追加插入点，普通输入 / 退格 / 删除同时在所有插入点生效。
/// 主光标仍由 `selectedRange` 表示，额外插入点存 `extraCursors`；
/// 每次批量编辑都用标准插入 / 删除路径，撤销分组保证一次 Cmd+Z 整体回退
extension LiteTextView {
    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), isEditable {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            window?.makeFirstResponder(self)
            addExtraCursor(at: index)
            return
        }
        clearExtraCursors()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Esc：多光标优先清除（保持现有行为）；否则弹出文档内词补全列表（R6）。
        // 候选为空时只响提示音，不弹空列表
        if event.keyCode == 53 {
            // 组字期间 Esc 属于取消输入法组字，必须交回系统处理，不抢作补全 / 清光标
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            if !extraCursors.isEmpty {
                // Esc 清除属于用户明确的光标动作，登记快照供 Cmd+U 恢复（R3）
                clearExtraCursors(registerUndo: true)
                return
            }
            var index = 0
            let candidates = completions(forPartialWordRange: wordRangeBeforeCaret(),
                                         indexOfSelectedItem: &index) ?? []
            guard !candidates.isEmpty else {
                NSSound.beep()
                return
            }
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// 文档内词补全的候选（R6）：大文件模式、前缀为空或没有候选时返回空数组。
    /// 插入补全由系统 `complete(nil)` 完成，走与普通输入相同的撤销路径
    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let nsText = string as NSString
        guard string.utf8.count < EditorTab.largeDocumentByteLimit,
              charRange.location != NSNotFound,
              NSMaxRange(charRange) <= nsText.length else { return [] }
        let prefix = nsText.substring(with: charRange)
        guard !prefix.isEmpty else { return [] }
        return BufferCompletion.candidates(in: string, prefix: prefix)
    }

    /// 光标前一个词的字符区间（供 Esc 预判候选）；前面不是词字符时返回零长区间。
    /// 词字符判定复用 FindEngine（与查找、补全候选同一口径）
    private func wordRangeBeforeCaret() -> NSRange {
        let nsText = string as NSString
        let caret = min(selectedRange().location, nsText.length)
        var start = caret
        while start > 0, FindEngine.isWordChar(at: start - 1, in: nsText) {
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }

    // MARK: - 输入

    override func insertText(_ insertString: Any) {
        guard !extraCursors.isEmpty, !hasMarkedText(), selectedRange().length == 0 else {
            if hasMarkedText() || selectedRange().length > 0 { clearExtraCursors() }
            // 单光标路径的自动闭合（KTD10）：组字、多光标与非零选区都不触发
            if let text = insertString as? String, handleAutoPair(text) { return }
            super.insertText(insertString)
            return
        }
        guard let text = insertString as? String, !text.isEmpty else {
            super.insertText(insertString)
            return
        }
        let positions = allCaretPositions()
        guard positions.count > 1 else { return }
        let inserted = (text as NSString).length
        isPerformingMultiCursorEdit = true
        defer { isPerformingMultiCursorEdit = false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        for position in positions.sorted(by: >) {
            setSelectedRange(NSRange(location: position, length: 0))
            super.insertText(text)
        }
        undoManager?.endUndoGrouping()
        applyCaretPositions(positions.enumerated().map { index, position in
            position + inserted * (index + 1)
        })
    }

    /// 系统输入可能经 NSTextInputClient 的两参数入口进来：额外光标存在时同一套批量逻辑，
    /// 批量编辑自身的 super 调用用标记挡回，避免递归。单光标路径同样要覆盖自动闭合（KTD10）：
    /// 系统走这个入口时若只挂在单参数入口上，自动闭合会整体失效
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !extraCursors.isEmpty, !isPerformingMultiCursorEdit,
              !hasMarkedText(), selectedRange().length == 0,
              replacementRange.length == 0 else {
            // 非零替换范围是系统改写（如自动补全替换）的落点，不介入自动闭合
            if extraCursors.isEmpty, replacementRange.length == 0,
               let text = insertString as? String, handleAutoPair(text) { return }
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        insertText(insertString)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !extraCursors.isEmpty, !hasMarkedText() else {
            super.deleteBackward(sender)
            return
        }
        let positions = allCaretPositions()
        guard positions.count > 1, positions.allSatisfy({ $0 > 0 }) else {
            clearExtraCursors()
            super.deleteBackward(sender)
            return
        }
        isPerformingMultiCursorEdit = true
        defer { isPerformingMultiCursorEdit = false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        for position in positions.sorted(by: >) {
            setSelectedRange(NSRange(location: position - 1, length: 1))
            super.deleteBackward(sender)
        }
        undoManager?.endUndoGrouping()
        // 升序第 i 个光标前面共删掉 i+1 个字符
        applyCaretPositions(positions.enumerated().map { index, position in
            position - (index + 1)
        })
    }

    override func deleteForward(_ sender: Any?) {
        guard !extraCursors.isEmpty, !hasMarkedText() else {
            super.deleteForward(sender)
            return
        }
        let length = (string as NSString).length
        let positions = allCaretPositions()
        guard positions.count > 1, positions.allSatisfy({ $0 < length }) else {
            clearExtraCursors()
            super.deleteForward(sender)
            return
        }
        isPerformingMultiCursorEdit = true
        defer { isPerformingMultiCursorEdit = false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        for position in positions.sorted(by: >) {
            setSelectedRange(NSRange(location: position, length: 1))
            super.deleteForward(sender)
        }
        undoManager?.endUndoGrouping()
        applyCaretPositions(positions.enumerated().map { index, position in
            position - index
        })
    }

    // MARK: - 光标管理

    func addExtraCursor(at index: Int) {
        let length = (string as NSString).length
        let caret = min(max(index, 0), length)
        if selectedRange().length > 0 {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        guard caret != selectedRange().location, !extraCursors.contains(caret) else { return }
        pushCursorUndoSnapshot()
        extraCursors.append(caret)
        extraCursors.sort()
        needsDisplay = true
    }

    /// 批量设置额外光标（全选所有匹配，R2）：先把选区收拢成零长插入点（与 addExtraCursor 同一写法），
    /// 再按正文长度夹取、去重排序、去掉主光标位置，最多取前 1000 个。
    /// 结果与当前完全一致时不登记快照，免得连按两次快捷键后第一次 Cmd+U 毫无变化
    func setExtraCursors(_ positions: [Int]) {
        if selectedRange().length > 0 {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        let length = (string as NSString).length
        let caret = selectedRange().location
        let clamped = positions
            .map { min(max($0, 0), length) }
            .filter { $0 != caret }
        let next = Array(Set(clamped).sorted().prefix(LiteTextView.extraCursorLimit))
        guard next != extraCursors else { return }
        pushCursorUndoSnapshot()
        extraCursors = next
        needsDisplay = true
    }

    /// 清除额外光标：`registerUndo` 为真时先登记一次可撤销的快照（Esc 清除走这条）；
    /// 默认不登记——鼠标点击、正文改动等隐式清理不该留下撤销记录（KTD4）
    func clearExtraCursors(registerUndo: Bool = false) {
        guard !extraCursors.isEmpty else { return }
        if registerUndo { pushCursorUndoSnapshot() }
        extraCursors.removeAll()
        needsDisplay = true
    }

    /// 主光标 + 额外光标，去重升序
    private func allCaretPositions() -> [Int] {
        var positions = extraCursors
        positions.append(selectedRange().location)
        return Array(Set(positions)).sorted()
    }

    /// 主光标落在第一个位置，其余作为额外光标
    private func applyCaretPositions(_ positions: [Int]) {
        let length = (string as NSString).length
        let clamped = positions.map { min(max($0, 0), length) }
        guard let first = clamped.first else { return }
        setSelectedRange(NSRange(location: first, length: 0))
        extraCursors = Array(Set(clamped.dropFirst())).sorted()
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !extraCursors.isEmpty, isEditable,
              let layoutManager, let textContainer else { return }
        let color = insertionPointColor ?? NSColor.controlAccentColor
        color.setFill()
        let length = (string as NSString).length
        for cursor in extraCursors where cursor <= length {
            if let rect = caretRect(at: cursor, layoutManager: layoutManager,
                                    textContainer: textContainer) {
                rect.fill()
            }
        }
    }

    private func caretRect(at cursor: Int, layoutManager: NSLayoutManager,
                           textContainer: NSTextContainer) -> NSRect? {
        let length = (string as NSString).length
        let origin = textContainerOrigin
        if length == 0 {
            return NSRect(x: origin.x, y: origin.y, width: 1.5, height: lineHeight)
        }
        let characterIndex = min(cursor, length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let x: CGFloat
        if cursor >= length {
            let lastGlyph = max(0, layoutManager.numberOfGlyphs - 1)
            let lastRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: lastGlyph, length: 1), in: textContainer)
            x = lastRect.maxX
        } else {
            x = layoutManager.location(forGlyphAt: glyphIndex).x
        }
        return NSRect(x: origin.x + x, y: origin.y + lineRect.minY,
                      width: 1.5, height: lineRect.height)
    }

    private var lineHeight: CGFloat {
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return layoutManager?.defaultLineHeight(for: font) ?? font.ascender - font.descender
    }
}
