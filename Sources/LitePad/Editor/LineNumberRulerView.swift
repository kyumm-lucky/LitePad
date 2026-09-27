import AppKit

/// 行号栏（骨架版）：每次绘制从可见首行重新推算行号，
/// 行号推算是 O(n) 全文扫描，大文件场景待优化（可改为增量缓存行起点）。
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let labelColor = NSColor.secondaryLabelColor
    private let separatorColor = NSColor.separatorColor
    /// 行号栏底色跟随编辑器透明度，半透明时不产生整块白色遮挡
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

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let bounds = self.bounds
        gutterColor.setFill()
        bounds.fill()
        separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 1
        separator.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor
        ]
        let labelHeight = ("0" as NSString).size(withAttributes: attributes).height

        func drawNumber(_ number: Int, atY y: CGFloat) {
            let label = String(number)
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 6, y: y), withAttributes: attributes)
        }

        let content = textView.string as NSString
        let textOrigin = convert(NSPoint.zero, from: textView)

        if content.length == 0 {
            drawNumber(1, atY: textOrigin.y + textView.textContainerInset.height + 2)
            return
        }

        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visibleChars.location != NSNotFound else { return }

        var lineNumber = content.substring(to: visibleChars.location)
            .components(separatedBy: "\n").count
        var charIndex = visibleChars.location
        let visibleEnd = NSMaxRange(visibleChars)
        var lastFragment: NSRect?

        while charIndex < visibleEnd {
            let lineRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            if lineRange.length == 0 { break }
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if glyphs.location != NSNotFound, glyphs.length > 0 {
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                drawNumber(lineNumber, atY: fragment.minY + textOrigin.y + (fragment.height - labelHeight) / 2)
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
                y = lastFragment.minY + textOrigin.y + lastFragment.height + (lastFragment.height - labelHeight) / 2
            } else {
                y = textOrigin.y + textView.textContainerInset.height + 2
            }
            drawNumber(lineNumber, atY: y)
        }
    }
}
