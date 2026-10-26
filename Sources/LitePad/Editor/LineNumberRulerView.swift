import AppKit

/// 行号栏：行号按可见区首字符二分查找，行首偏移表在文本编辑后失效并重建，
/// 绘制不再是每次全文扫描
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// 行首偏移表（含 0）：正文编辑后由文本存储通知清空，下次绘制重建
    private var lineStarts: [Int] = []
    /// 书签所在行的行首偏移：闭包从标签读，行号栏不直接持有标签
    var bookmarkOffsets: (() -> Set<Int>)?
    /// 折叠块所在行号：在行号右侧画一个小三角，提示该行下面藏着内容
    var foldedOwnerLines: (() -> Set<Int>)?
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// 行号栏底色跟随编辑器透明度，半透明时不产生整块白色遮挡。
    /// 底色是编辑器同一块背景，不随语法主题走；行号与分隔线随主题解析
    private var gutterColor: NSColor {
        NSColor.textBackgroundColor.withAlphaComponent(
            CGFloat(max(0.1, min(1, AppSettings.shared.editorOpacity / 100))))
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    /// 正文编辑后由协调器调用：行首偏移表失效，下次绘制重建
    func invalidateLineStarts() {
        lineStarts.removeAll(keepingCapacity: true)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 系统深浅切换后底色与主题取色都要按新外观重取
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        // 行号栏的用色按当前外观从主题解析：主题换侧或系统深浅切换后重画即得新色。
        // 主题取装饰层里那份配置（编辑器按设置同步过来），两处不各读一次设置、将来也不会分化
        let theme = (layoutManager as? DecorationsLayoutManager)?.appearance?.syntaxTheme
            ?? AppSettings.shared.syntaxTheme
        let palette = EditorPalette.resolve(theme, for: effectiveAppearance)
        let bounds = self.bounds
        gutterColor.setFill()
        bounds.fill()
        palette.gutterSeparator.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 1
        separator.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: palette.gutterLabel
        ]
        let labelHeight = ("0" as NSString).size(withAttributes: attributes).height

        /// 行首偏移表：首次绘制时扫一遍，之后命中缓存；文本编辑由通知清空
        func lineStartTable() -> [Int] {
            if !lineStarts.isEmpty { return lineStarts }
            var offsets: [Int] = [0]
            var index = 0
            while index < content.length {
                if content.character(at: index) == 0x0A {
                    offsets.append(index + 1)
                }
                index += 1
            }
            lineStarts = offsets
            return offsets
        }

        func lineNumber(at location: Int, in content: NSString) -> Int {
            let offsets = lineStartTable()
            var low = 0
            var high = offsets.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if offsets[mid] <= location { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }

        func drawNumber(_ number: Int, atY y: CGFloat) {
            let label = String(number)
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 6, y: y), withAttributes: attributes)
        }

        let content = textView.string as NSString
        // fragment.minY 是文本容器内坐标（不含 textContainerInset），换算到行号栏必须补上顶部内边距，
        // 否则所有行号整体偏高一个 inset（约 8pt）
        let baseY = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height

        if content.length == 0 {
            drawNumber(1, atY: baseY + 2)
            return
        }

        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visibleChars.location != NSNotFound else { return }

        var lineNumber = lineNumber(at: visibleChars.location, in: content)
        var charIndex = visibleChars.location
        let visibleEnd = NSMaxRange(visibleChars)
        var lastFragment: NSRect?

        while charIndex < visibleEnd {
            let lineRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            if lineRange.length == 0 { break }
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if glyphs.location != NSNotFound, glyphs.length > 0 {
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                drawNumber(lineNumber, atY: baseY + fragment.minY + (fragment.height - labelHeight) / 2)
                if let bookmarkOffsets, bookmarkOffsets().contains(charIndex) {
                    NSColor.controlAccentColor.setFill()
                    let dot = NSRect(x: 7,
                                     y: baseY + fragment.minY + fragment.height / 2 - 2.5,
                                     width: 5, height: 5)
                    NSBezierPath(ovalIn: dot).fill()
                }
                if let foldedOwnerLines, foldedOwnerLines().contains(lineNumber) {
                    palette.gutterLabel.setFill()
                    let centerY = baseY + fragment.minY + fragment.height / 2
                    let triangle = NSBezierPath()
                    triangle.move(to: NSPoint(x: 13, y: centerY - 3))
                    triangle.line(to: NSPoint(x: 13, y: centerY + 3))
                    triangle.line(to: NSPoint(x: 18, y: centerY))
                    triangle.close()
                    triangle.fill()
                }
                lastFragment = fragment
                lineNumber += 1
            }
            charIndex = NSMaxRange(lineRange)
        }

        // 文档以换行结尾且末尾空行可见时，为其补行号
        if charIndex >= content.length,
           content.character(at: content.length - 1) == 0x0A {
            let y: CGFloat
            if let lastFragment {
                y = baseY + lastFragment.minY + lastFragment.height + (lastFragment.height - labelHeight) / 2
            } else {
                y = baseY + 2
            }
            drawNumber(lineNumber, atY: y)
        }
    }
}
