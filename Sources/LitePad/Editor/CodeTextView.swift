import SwiftUI
import AppKit

/// NSTextView 的 SwiftUI 封装：等宽字体、软换行、系统撤销/重做、行号栏。
/// 文本编辑经由 delegate 回写模型；模型侧变化仅在内容确实不同时才回写视图，
/// 避免逐键输入时丢失光标位置。
struct CodeTextView: NSViewRepresentable {
    @ObservedObject var tab: EditorTab

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 非零初始 frame：SwiftUI 稍后才给 scrollView 实际尺寸，
        // 零尺寸 frame 会让 [.width] 自适应算出多余宽度，导致文字被行号栏遮住
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        // 代码场景关闭系统自动替换
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        // 软换行模式下不会产生水平溢出，禁用水平滚动条避免底部空轨道
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true

        // 滚动 / 窗口尺寸变化时刷新行号栏
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak ruler] _ in
            ruler?.needsDisplay = true
        }

        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        textView.string = tab.text
        SyntaxHighlighter.highlight(textView: textView, language: tab.language)
        context.coordinator.highlightedLanguage = tab.language
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let languageChanged = context.coordinator.highlightedLanguage != tab.language

        if textView.string != tab.text {
            let selection = textView.selectedRanges.compactMap { $0 as? NSRange }
            textView.string = tab.text
            let maxLoc = (tab.text as NSString).length
            let clamped = selection.map { range -> NSRange in
                let loc = min(range.location, maxLoc)
                return NSRange(location: loc, length: min(range.length, maxLoc - loc))
            }
            textView.selectedRanges = clamped.map { NSValue(range: $0) }
            context.coordinator.highlightedLanguage = tab.language
            SyntaxHighlighter.highlight(textView: textView, language: tab.language)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        } else if languageChanged {
            context.coordinator.highlightedLanguage = tab.language
            SyntaxHighlighter.highlight(textView: textView, language: tab.language)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let tab: EditorTab
        weak var textView: NSTextView?
        var highlightedLanguage: LanguageDefinition?
        var boundsObserver: NSObjectProtocol?

        init(tab: EditorTab) {
            self.tab = tab
            super.init()
        }

        deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            tab.text = textView.string
            highlightedLanguage = tab.language
            SyntaxHighlighter.highlight(textView: textView, language: tab.language)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}
