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
    var pageGuideColumn: Int?
    var currentLine: Bool
    var extraScroll: Double
    var opacity: Double

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
            pageGuideColumn: settings.pageGuideEnabled ? settings.pageGuideColumn : nil,
            currentLine: settings.highlightCurrentLine,
            extraScroll: settings.extraScrollPercent,
            opacity: settings.editorOpacity
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

        if appearance.currentLine {
            drawCurrentLine(origin: origin, textView: textView, content: content)
        }
        if appearance.indentGuides {
            drawIndentGuides(glyphsToShow: glyphsToShow, origin: origin, textView: textView, content: content)
        }
        if let column = appearance.pageGuideColumn {
            drawPageGuide(column: column, origin: origin, textView: textView)
        }
        if let invisibles = appearance.invisibles {
            drawInvisibles(invisibles, glyphsToShow: glyphsToShow, origin: origin,
                           textView: textView, content: content)
        }
    }

    // MARK: - 当前行

    private func drawCurrentLine(origin: NSPoint, textView: NSTextView, content: NSString) {
        guard let range = currentLineCharRange, range.location <= content.length, numberOfGlyphs > 0 else { return }
        let color = NSColor.controlAccentColor.withAlphaComponent(0.08)
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

    private func drawIndentGuides(glyphsToShow: NSRange, origin: NSPoint,
                                  textView: NSTextView, content: NSString) {
        guard let font = textView.font else { return }
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let tabUnit = textView.defaultParagraphStyle?.defaultTabInterval ?? 28
        let guideColor = NSColor.separatorColor.withAlphaComponent(0.35)

        enumerateLineFragments(forGlyphRange: glyphsToShow) { fragmentRect, _, _, glyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0 else { return }
            // 统计行首空白宽度；含制表符时按制表宽度对齐，否则按 4 空格一级
            var width: CGFloat = 0
            var usesTab = false
            var index = charRange.location
            while index < NSMaxRange(charRange) {
                let ch = content.character(at: index)
                guard ch == 0x20 || ch == 0x09 else { break }
                width += ch == 0x20 ? spaceWidth : tabUnit
                usesTab = usesTab || ch == 0x09
                index += 1
            }
            let unit = usesTab ? tabUnit : spaceWidth * 4
            guard width > 0, unit > 0 else { return }
            var offset = unit
            while offset <= width + 0.5 {
                let rect = NSRect(x: origin.x + fragmentRect.minX + offset - 0.5,
                                  y: origin.y + fragmentRect.minY,
                                  width: 1, height: fragmentRect.height)
                guideColor.setFill()
                rect.fill()
                offset += unit
            }
        }
    }

    // MARK: - 列位置页面指示线

    private func drawPageGuide(column: Int, origin: NSPoint, textView: NSTextView) {
        guard let font = textView.font else { return }
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let x = origin.x + charWidth * CGFloat(max(1, column))
        guard x >= 0, x <= textView.bounds.width + 1 else { return }
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        NSRect(x: x - 0.5, y: 0, width: 1, height: textView.bounds.height).fill()
    }

    // MARK: - 不可见元素

    private func drawInvisibles(_ options: InvisiblesOptions, glyphsToShow: NSRange, origin: NSPoint,
                                textView: NSTextView, content: NSString) {
        guard let font = textView.font else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(8, font.pointSize - 3), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
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

/// 支持"额外滚动"的文本视图：在内容底部追加一段与可视高度成比例的空白区。
/// （本机 SDK 已移除 constrainFrameRect 的 Swift 重写入口，改在 layout 后扩展 frame）
final class LiteTextView: NSTextView {
    /// 额外可滚动区域占可视高度的比例（0 = 关闭）
    var extraScrollFraction: CGFloat = 0
    /// 文件拖入 / 离开编辑区的通知（驱动接收提示）
    var onFileDragActive: ((Bool) -> Void)?
    /// 文件投放：把地址交给会话的统一打开入口
    var onFileDrop: (([URL]) -> Void)?

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
        guard droppedFileURLs(sender) != nil else { return super.draggingUpdated(sender) }
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

    override func layout() {
        super.layout()
        guard extraScrollFraction > 0, let scrollView = enclosingScrollView else { return }
        let target = frame.height + scrollView.contentSize.height * extraScrollFraction
        if abs(frame.height - target) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: target))
        }
    }
}
