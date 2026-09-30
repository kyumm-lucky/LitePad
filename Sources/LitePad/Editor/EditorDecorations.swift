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
