import AppKit

/// 编辑器外观配置快照：设置变化时整体重应用到文本视图与装饰层
struct EditorAppearanceConfig: Equatable {
    var fontName: String
    var fontSize: CGFloat
    var ligatures: Bool
    var lineHeight: Double
    var wraps: Bool
    var wrapIndent: Int
    var writingDirection: NSWritingDirection
    var lineNumbers: Bool
    /// 系统拼写检查开关：设置页切换后由 apply(config:) 即时同步到编辑视图
    var spellCheck: Bool
    var invisibles: InvisiblesOptions?
    var indentGuides: Bool
    /// 一级缩进的宽度：驱动缩进指示线，并换算文本视图的制表位宽度（KTD10）
    var indentWidth: Int
    var pageGuideColumn: Int?
    var currentLine: Bool
    var extraScroll: Double
    var opacity: Double
    /// 语法配色主题：装饰层与行号栏的用色由它解析（KTD6）
    var syntaxTheme: SyntaxTheme

    static func from(_ settings: AppSettings) -> EditorAppearanceConfig {
        EditorAppearanceConfig(
            fontName: settings.editorFont.fontName,
            fontSize: CGFloat(settings.editorFontSize),
            ligatures: settings.ligaturesEnabled,
            lineHeight: settings.lineHeightMultiple,
            wraps: settings.wrapLines,
            wrapIndent: settings.wrapIndentEnabled ? settings.wrapIndentChars : 0,
            writingDirection: settings.writingDirection == .rtl ? .rightToLeft : .leftToRight,
            lineNumbers: settings.showLineNumbers,
            spellCheck: settings.spellCheckEnabled,
            invisibles: settings.showInvisibles ? settings.invisibles : nil,
            indentGuides: settings.showIndentGuides,
            indentWidth: IndentRules.clampedWidth(settings.indentWidth),
            pageGuideColumn: settings.pageGuideEnabled ? settings.pageGuideColumn : nil,
            currentLine: settings.highlightCurrentLine,
            extraScroll: settings.extraScrollPercent,
            opacity: settings.editorOpacity,
            syntaxTheme: settings.syntaxTheme
        )
    }
}

/// 承担装饰绘制的排版管理器：不可见元素 / 缩进指示 / 列位置页面指示线 / 当前行高亮。
/// 复用 TextKit 1 兼容路径（与查找高亮的临时属性一致），在 drawBackground 里画在文字下方
final class DecorationsLayoutManager: NSLayoutManager {
    var appearance: EditorAppearanceConfig?
    /// 当前行高亮对应的字符区间；由 CodeTextView 在光标 / 文本变化时刷新并触发重绘
    private var currentLineCharRange: NSRange?
    /// 括号配对高亮的字符区间：由 CodeTextView 在光标 / 文本变化时刷新，空数组表示不画
    var bracketMatchRanges: [NSRange] = []

    /// 跟随光标更新当前行区间；区间变化时整页重绘
    func updateCurrentLine(for textView: NSTextView) {
        guard appearance?.currentLine == true else {
            if currentLineCharRange != nil {
                currentLineCharRange = nil
                firstTextView?.needsDisplay = true
            }
            return
        }
        let content = textView.string as NSString
        let caret = min(textView.selectedRange().location, content.length)
        var start = 0
        var lineEnd = 0
        content.getLineStart(&start, end: &lineEnd, contentsEnd: nil,
                             for: NSRange(location: caret, length: 0))
        let newRange = NSRange(location: start, length: lineEnd - start)
        if newRange != currentLineCharRange {
            currentLineCharRange = newRange
            firstTextView?.needsDisplay = true
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let appearance, let textView = firstTextView else { return }
        let content = textView.string as NSString
        // 用色按当前外观从主题解析：系统语义色与固定取值都落成这个外观下的具体色值，
        // 解析只十二个颜色，绘制期直接取，不必另存一份缓存
        let palette = EditorPalette.resolve(appearance.syntaxTheme, for: textView.effectiveAppearance)

        if appearance.currentLine {
            drawCurrentLine(origin: origin, textView: textView, content: content,
                            color: palette.currentLine)
        }
        if !bracketMatchRanges.isEmpty {
            drawBracketMatch(origin: origin, textView: textView, content: content,
                             color: NSColor.controlAccentColor.withAlphaComponent(0.2))
        }
        if appearance.indentGuides {
            drawIndentGuides(indentWidth: appearance.indentWidth, glyphsToShow: glyphsToShow,
                             origin: origin, textView: textView, content: content,
                             color: palette.indentGuide)
        }
        if let column = appearance.pageGuideColumn {
            drawPageGuide(column: column, origin: origin, textView: textView,
                          color: palette.pageGuide)
        }
        if let invisibles = appearance.invisibles {
            drawInvisibles(invisibles, glyphsToShow: glyphsToShow, origin: origin,
                           textView: textView, content: content,
                           color: palette.invisibles)
        }
    }

    // MARK: - 当前行

    private func drawCurrentLine(origin: NSPoint, textView: NSTextView, content: NSString, color: NSColor) {
        guard let range = currentLineCharRange, range.location <= content.length, numberOfGlyphs > 0 else { return }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var drew = false
        if glyphs.length > 0 {
            // 软换行会把一行拆成多个片段，逐片段铺满整行
            enumerateLineFragments(forGlyphRange: glyphs) { fragmentRect, _, _, _, _ in
                let rect = NSRect(x: 0, y: origin.y + fragmentRect.minY,
                                  width: textView.bounds.width, height: fragmentRect.height)
                color.setFill()
                rect.fill()
                drew = true
            }
        }
        if !drew {
            // 行尾空行（字符区间长度为 0）没有对应字形，取相邻字形所在行绘制
            let index = range.location < content.length
                ? glyphIndexForCharacter(at: range.location)
                : numberOfGlyphs - 1
            guard index >= 0, index < numberOfGlyphs else { return }
            let fragment = lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
            let rect = NSRect(x: 0, y: origin.y + fragment.minY,
                              width: textView.bounds.width, height: fragment.height)
            color.setFill()
            rect.fill()
        }
    }

    // MARK: - 括号配对

    /// 配对括号的圆角底色：按字符所在字形的行片段与 x 位置绘制，左右各让出 1pt
    private func drawBracketMatch(origin: NSPoint, textView: NSTextView,
                                  content: NSString, color: NSColor) {
        guard let font = textView.font, numberOfGlyphs > 0 else { return }
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        color.setFill()
        for range in bracketMatchRanges {
            guard range.location >= 0, range.length > 0,
                  NSMaxRange(range) <= content.length else { continue }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.location != NSNotFound, glyphs.length > 0 else { continue }
            let glyphIndex = min(glyphs.location, numberOfGlyphs - 1)
            let fragment = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let x = location(forGlyphAt: glyphIndex).x
            let rect = NSRect(x: origin.x + x - 1, y: origin.y + fragment.minY,
                              width: max(charWidth, 2) + 2, height: fragment.height)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    // MARK: - 缩进指示

    private func drawIndentGuides(indentWidth: Int, glyphsToShow: NSRange, origin: NSPoint,
                                  textView: NSTextView, content: NSString, color: NSColor) {
        guard let font = textView.font else { return }
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        // 一级缩进的宽度与插入的缩进同源（KTD10）：空格行按缩进宽度算，
        // 制表符按文本视图的制表位宽度算——制表位本身也按缩进宽度设置，两者因此对齐
        let unit = spaceWidth * CGFloat(IndentRules.clampedWidth(indentWidth))
        let tabUnit = textView.defaultParagraphStyle?.defaultTabInterval ?? unit
        // 行内字符从文本容器的行内边距之后开始画，制表位计在同一基准上：
        // 指示线要落在缩进段结束、正文开始的位置，起点必须同样加上这段边距
        let textPadding = textView.textContainer?.lineFragmentPadding ?? 0

        enumerateLineFragments(forGlyphRange: glyphsToShow) { fragmentRect, _, _, glyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0 else { return }
            // 统计行首空白宽度
            var width: CGFloat = 0
            var index = charRange.location
            while index < NSMaxRange(charRange) {
                let ch = content.character(at: index)
                guard ch == 0x20 || ch == 0x09 else { break }
                width += ch == 0x20 ? spaceWidth : tabUnit
                index += 1
            }
            guard width > 0, unit > 0 else { return }
            var offset = unit
            while offset <= width + 0.5 {
                let rect = NSRect(x: origin.x + fragmentRect.minX + textPadding + offset - 0.5,
                                  y: origin.y + fragmentRect.minY,
                                  width: 1, height: fragmentRect.height)
                color.setFill()
                rect.fill()
                offset += unit
            }
        }
    }

    // MARK: - 列位置页面指示线

    private func drawPageGuide(column: Int, origin: NSPoint, textView: NSTextView, color: NSColor) {
        guard let font = textView.font else { return }
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let x = origin.x + charWidth * CGFloat(max(1, column))
        guard x >= 0, x <= textView.bounds.width + 1 else { return }
        color.setFill()
        NSRect(x: x - 0.5, y: 0, width: 1, height: textView.bounds.height).fill()
    }

    // MARK: - 不可见元素

    private func drawInvisibles(_ options: InvisiblesOptions, glyphsToShow: NSRange, origin: NSPoint,
                                textView: NSTextView, content: NSString, color: NSColor) {
        guard let font = textView.font else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(8, font.pointSize - 3), weight: .regular),
            .foregroundColor: color
        ]
        let markerHeight = ("·" as NSString).size(withAttributes: attributes).height

        func draw(_ mark: String, atX x: CGFloat, in fragment: NSRect) {
            mark.draw(at: NSPoint(x: x, y: origin.y + fragment.minY + (fragment.height - markerHeight) / 2),
                      withAttributes: attributes)
        }

        enumerateLineFragments(forGlyphRange: glyphsToShow) { fragmentRect, usedRect, _, glyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0 else { return }
            // 行尾标记：片段以换行字符结尾时画在片段右端（\r\n 只画一次）
            if options.lineEndings {
                switch content.character(at: NSMaxRange(charRange) - 1) {
                case 0x0A, 0x0D, 0x2028, 0x2029:
                    draw("↩", atX: origin.x + usedRect.maxX + 2, in: fragmentRect)
                default: break
                }
            }
            var index = charRange.location
            while index < NSMaxRange(charRange) {
                let ch = content.character(at: index)
                let mark: String?
                if ch == 0x20 {
                    mark = options.spaces ? "·" : nil
                } else if ch == 0x09 {
                    mark = options.tabs ? "→" : nil
                } else if Self.isOtherWhitespace(ch) {
                    mark = options.otherWhitespace ? "␣" : nil
                } else if Self.isOtherControl(ch) {
                    mark = options.otherControl ? "�" : nil
                } else {
                    mark = nil
                }
                if let mark {
                    let glyphIndex = self.glyphIndexForCharacter(at: index)
                    if glyphIndex < self.numberOfGlyphs {
                        let location = self.location(forGlyphAt: glyphIndex)
                        draw(mark, atX: origin.x + location.x, in: fragmentRect)
                    }
                }
                index += 1
            }
        }
    }

    /// 常规空格之外的空白（不换行空格、全角空格等）
    private static func isOtherWhitespace(_ ch: unichar) -> Bool {
        switch ch {
        case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// 换行三件套之外的控制字符
    private static func isOtherControl(_ ch: unichar) -> Bool {
        switch ch {
        case 0x09, 0x0A, 0x0D: return false
        case 0x00...0x1F, 0x7F: return true
        default: return false
        }
    }
}

/// 自动缩进需要的文档上下文：语言决定块开头判定，行尾符决定回车插入的换行。
/// 编辑视图不持有标签，由 CodeTextView 在装配时注入（与文件投放同一接法）
struct EditorIndentContext {
    var language: LanguageDefinition
    var lineSeparator: String
}

/// 支持"额外滚动"的文本视图：在内容底部追加一段与可视高度成比例的空白区。
/// （本机 SDK 已移除 constrainFrameRect 的 Swift 重写入口，改在 layout 后扩展 frame）
final class LiteTextView: NSTextView {
    /// 额外可滚动区域占可视高度的比例（0 = 关闭）
    var extraScrollFraction: CGFloat = 0
    /// 文件拖入 / 离开编辑区的通知（驱动接收提示）
    var onFileDragActive: ((Bool) -> Void)?
    /// 文件投放：把地址交给会话的统一打开入口
    var onFileDrop: (([URL]) -> Void)?
    /// 自动缩进的文档上下文；未装配时按键全部回落为系统默认行为
    var indentContextProvider: (() -> EditorIndentContext)?
    /// 系统深浅切换（或外观模式切换）后的通知：高亮与装饰的取色都按外观解析，外观变了要按新外观重取（KTD6）
    var onAppearanceChanged: (() -> Void)?
    /// 多光标：除主光标（selectedRange）外的额外插入点（字符偏移，升序）
    var extraCursors: [Int] = []
    /// 批量设置额外光标时的条数上限（全选所有匹配）：再多的光标没有批量编辑价值，
    /// 且每次输入都会退化成整篇重排
    static let extraCursorLimit = 1000
    /// 光标撤销快照的条数上限：超出丢弃最旧的一条
    static let cursorUndoLimit = 50
    /// 光标动作的撤销快照栈：只记额外光标的增减，不回写正文（KTD4）。
    /// 只在用户入口登记（Cmd+单击追加 / 全选所有匹配 / Esc 清除），鼠标点击、正文改动等隐式清理不登记
    private(set) var cursorUndoStack: [[Int]] = []
    /// 批量编辑进行中：此时正文变化由多光标自己发起，不清掉光标组
    var isPerformingMultiCursorEdit = false
    /// 成为第一响应者时的回调（参考栏据此把自己提升为主编辑区）
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    /// 投放内容里的文件地址；纯文字投放返回 nil，那类投放维持系统默认行为。
    /// 可编辑的文本视图自带拖放并先消费落在文字区的投放，其后的 SwiftUI 投放目标收不到事件，
    /// 所以文件投放必须在 AppKit 这一层接管
    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedFileURLs(sender) != nil else { return super.draggingEntered(sender) }
        onFileDragActive?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 这里只判「是不是文件投放」，不解码地址：draggingUpdated 在指针移动期间高频回调，
        // 每次 readObjects 都要读粘贴板并构造数组；解码留给真正落下的 performDragOperation
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else {
            return super.draggingUpdated(sender)
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragActive?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onFileDragActive?(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = droppedFileURLs(sender) else { return super.performDragOperation(sender) }
        onFileDragActive?(false)
        onFileDrop?(urls)
        return true
    }

    // MARK: - 自动缩进与 Tab

    /// 回车（R13）：继承当前行的行首空白，光标前是可见的块开头时再加一级。
    /// 换行与缩进合成一次插入、经 shouldChangeText 撤销协议登记（KTD14），一次撤销即可整体回退；
    /// 插入前断开输入合并，否则这一下回车会被并进上一段输入，撤销时连前面的字符一起回退
    override func insertNewline(_ sender: Any?) {
        // 回车带缩进上下文，多光标下不做批量处理：先收起额外光标，按主光标插入
        clearExtraCursors()
        guard !hasMarkedText(), let context = indentContextProvider?() else {
            super.insertNewline(sender)
            return
        }
        let settings = AppSettings.shared
        let line = caretLineContext()
        let indent = IndentRules.newLineIndent(
            leadingWhitespace: line.leading,
            opensBlock: IndentRules.opensBlock(before: line.prefix, language: context.language),
            width: settings.indentWidth,
            insertSpaces: settings.insertSpacesForTab)
        breakUndoCoalescing()
        insertText(context.lineSeparator + indent, replacementRange: selectedRange())
    }

    /// Tab（R14）：开启插入空格时按缩进宽度插入空格，否则插入一个制表符；
    /// 制表符的显示宽度由外观应用按同一缩进宽度设置的制表位保证，与缩进指示线对齐（KTD10）
    override func insertTab(_ sender: Any?) {
        clearExtraCursors()
        guard !hasMarkedText() else {
            super.insertTab(sender)
            return
        }
        let settings = AppSettings.shared
        breakUndoCoalescing()
        insertText(IndentRules.unit(width: settings.indentWidth,
                                    insertSpaces: settings.insertSpacesForTab),
                   replacementRange: selectedRange())
    }

    // MARK: - 光标撤销（R3）

    /// 登记一次光标快照：只压旧值，不注册到文本撤销栈（KTD4：光标是视图状态，不与正文共用撤销栈）
    func pushCursorUndoSnapshot() {
        cursorUndoStack.append(extraCursors)
        if cursorUndoStack.count > LiteTextView.cursorUndoLimit {
            cursorUndoStack.removeFirst(cursorUndoStack.count - LiteTextView.cursorUndoLimit)
        }
    }

    /// 撤销上一次光标动作（Cmd+U）：弹栈恢复额外光标；栈空时只响提示音。
    /// 快照里的偏移按当前正文长度夹取并去掉主光标位置：快照之后正文可能已被删短，
    /// 越界偏移会在随后输入时落进 setSelectedRange 而抛异常
    func undoLastCursorAction() {
        guard let snapshot = cursorUndoStack.popLast() else {
            NSSound.beep()
            return
        }
        let length = (string as NSString).length
        let caret = selectedRange().location
        extraCursors = Array(Set(snapshot
            .map { min(max($0, 0), length) }
            .filter { $0 != caret })
            .sorted())
        needsDisplay = true
    }

    /// 清空光标撤销栈：整串正文替换后旧快照的偏移已失效
    func clearCursorUndoStack() {
        cursorUndoStack.removeAll()
    }

    // MARK: - 自动闭合（R4）

    /// 自动闭合括号与引号：单光标输入开括号时补上配对字符，输入闭括号时跳过已有的那一个。
    /// 返回 true 表示这次输入已被处理。入口是 MultiCursorTextView 两个 insertText 覆写的单光标分支
    /// （单参数键绑定入口与系统两参数入口都要覆盖，KTD10）；组字、多光标批量输入与非零选区不触发
    func handleAutoPair(_ text: String) -> Bool {
        guard AppSettings.shared.autoCloseBrackets,
              !hasMarkedText(),
              extraCursors.isEmpty,
              selectedRange().length == 0,
              text.count == 1,
              let typed = text.first else { return false }

        let nsText = string as NSString
        let caret = min(selectedRange().location, nsText.length)
        let left = character(before: caret, in: nsText)

        // 先判闭括号跳过：否则输入第二个引号时会走下面的补全分支，在已有的 `""` 之间再补一对
        if AutoPair.isClosing(typed),
           caret < nsText.length,
           let right = character(at: caret, in: nsText),
           right == typed,
           let left, AutoPair.closing(for: left) == typed {
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return true
        }

        guard let closer = AutoPair.closing(for: typed) else { return false }
        let context = AutoPairContext(
            left: left,
            right: caret < nsText.length ? character(at: caret, in: nsText) : nil,
            atLineStart: isLineStart(caret, in: nsText),
            atLineEnd: isLineEnd(caret, in: nsText))
        guard AutoPair.shouldAutoClose(opener: typed, context: context) else { return false }

        // 写入走 insertText 撤销协议：一次 Cmd+Z 可整体回退（与普通输入同一路径）
        super.insertText(String([typed, closer]), replacementRange: selectedRange())
        setSelectedRange(NSRange(location: caret + 1, length: 0))
        return true
    }

    /// 取 UTF-16 偏移前一个字符（按组合字符整体取，不拆开代理对）
    private func character(before offset: Int, in nsText: NSString) -> Character? {
        guard offset > 0, offset <= nsText.length else { return nil }
        let range = nsText.rangeOfComposedCharacterSequence(at: offset - 1)
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return nil }
        return Character(nsText.substring(with: range))
    }

    /// 取 UTF-16 偏移处的一个字符（按组合字符整体取，不拆开代理对）
    private func character(at offset: Int, in nsText: NSString) -> Character? {
        guard offset >= 0, offset < nsText.length else { return nil }
        let range = nsText.rangeOfComposedCharacterSequence(at: offset)
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return nil }
        return Character(nsText.substring(with: range))
    }

    /// 光标是否位于行首（上一单元是换行符）
    private func isLineStart(_ caret: Int, in nsText: NSString) -> Bool {
        guard caret > 0 else { return true }
        let before = nsText.character(at: caret - 1)
        return before == 0x0A || before == 0x0D
    }

    /// 光标是否位于行尾（下一单元是换行符或已到正文末尾）
    private func isLineEnd(_ caret: Int, in nsText: NSString) -> Bool {
        guard caret < nsText.length else { return true }
        let after = nsText.character(at: caret)
        return after == 0x0A || after == 0x0D
    }

    /// 光标所在行的行首空白与光标之前的行内文本：行中回车按行首空白继承、不引入行内空格，
    /// 块开头判定只看光标之前，光标之后已有的字符不参与
    private func caretLineContext() -> (leading: String, prefix: String) {
        let content = string as NSString
        let caret = min(selectedRange().location, content.length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        content.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                             for: NSRange(location: caret, length: 0))
        let line = content.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        let prefixEnd = min(caret, contentsEnd)
        let prefix = content.substring(with: NSRange(location: lineStart, length: prefixEnd - lineStart))
        return (IndentRules.leadingWhitespace(of: line), prefix)
    }

    override func layout() {
        super.layout()
        guard extraScrollFraction > 0, let scrollView = enclosingScrollView else { return }
        let target = frame.height + scrollView.contentSize.height * extraScrollFraction
        if abs(frame.height - target) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: target))
        }
    }
}
