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
        // Esc：只清额外光标，不关闭查找面板等其他 Esc 行为
        if event.keyCode == 53, !extraCursors.isEmpty {
            clearExtraCursors()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - 输入

    override func insertText(_ insertString: Any) {
        guard !extraCursors.isEmpty, !hasMarkedText(), selectedRange().length == 0 else {
            if hasMarkedText() || selectedRange().length > 0 { clearExtraCursors() }
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
    /// 批量编辑自身的 super 调用用标记挡回，避免递归
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !extraCursors.isEmpty, !isPerformingMultiCursorEdit,
              !hasMarkedText(), selectedRange().length == 0,
              replacementRange.length == 0 else {
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
        extraCursors.append(caret)
        extraCursors.sort()
        needsDisplay = true
    }

    func clearExtraCursors() {
        guard !extraCursors.isEmpty else { return }
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
