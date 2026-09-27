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

        tab.goToLineHandler = { [weak textView] line in
            goToLine(line, in: textView)
        }
        tab.findNavigationHandler = { [weak coordinator = context.coordinator] index in
            guard let coordinator,
                  let textView = coordinator.textView,
                  let state = coordinator.tab.findState,
                  state.matches.indices.contains(index) else { return }
            textView.selectedRange = state.matches[index]
            textView.scrollRangeToVisible(state.matches[index])
        }
        tab.replaceHandler = { [weak coordinator = context.coordinator] replaceAll in
            guard let coordinator, let textView = coordinator.textView else { return }
            performReplace(textView: textView, tab: coordinator.tab, all: replaceAll)
        }

        textView.string = tab.text
        SyntaxHighlighter.highlight(textView: textView, language: tab.language)
        context.coordinator.highlightedLanguage = tab.language
        context.coordinator.publishStats(from: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 输入法组字期间（拼音预输入）视图里是 marked text，与模型必然不一致；
        // 此时回写 string / 选区会立刻中止组字，导致中文无法输入，必须整段跳过
        guard !textView.hasMarkedText() else { return }
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
            // 整串重写会清空 layoutManager 临时属性，重置高亮守卫让下方按新状态重建
            context.coordinator.appliedFindState = nil
        } else if languageChanged {
            context.coordinator.highlightedLanguage = tab.language
            SyntaxHighlighter.highlight(textView: textView, language: tab.language)
        }

        // 查找状态变化（含面板关闭）时重建高亮；选区/滚动只由 findNavigationHandler 驱动，
        // 避免用户输入时被抢走光标
        if context.coordinator.appliedFindState != tab.findState {
            let oldState = context.coordinator.appliedFindState
            context.coordinator.appliedFindState = tab.findState
            applyFindHighlight(textView: textView, oldState: oldState, state: tab.findState)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let tab: EditorTab
        weak var textView: NSTextView?
        var highlightedLanguage: LanguageDefinition?
        var boundsObserver: NSObjectProtocol?
        /// 已应用过查找高亮的面板状态，避免无变化时重复全文清设
        var appliedFindState: FindState?

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
            // 组字（marked text）阶段的内容不写入模型、不重刷高亮，
            // 等选字上屏或取消后 NSTextView 会再次回调，届时再同步
            if !textView.hasMarkedText() {
                tab.text = textView.string
                highlightedLanguage = tab.language
                SyntaxHighlighter.highlight(textView: textView, language: tab.language)
                textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
                tab.refreshMatches()
            }
            publishStats(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publishStats(from: textView)
        }

        /// 把光标与文本统计发布到标签页模型，驱动状态栏刷新
        func publishStats(from textView: NSTextView) {
            tab.updateStats(DocumentStats.compute(text: textView.string,
                                                  caretOffset: textView.selectedRange().location))
        }
    }
}

/// 跳转到指定行（从 1 起）：行枚举口径与 NSString 行分割一致（\n、\r\n、\r 均算一行），
/// 与状态栏 DocumentStats 的行号对齐；光标定位到行首并滚动到可见
private func goToLine(_ line: Int, in textView: NSTextView?) {
    guard let textView, line >= 1 else { return }
    let nsText = textView.string as NSString
    let length = nsText.length

    var lineStart = 0
    var lineNumber = 1
    while lineNumber < line, lineStart < length {
        var lineEnd = 0
        nsText.getLineStart(nil, end: &lineEnd, contentsEnd: nil,
                            for: NSRange(location: lineStart, length: 0))
        lineStart = lineEnd
        lineNumber += 1
    }
    // 请求行号超过总行数时不跳转（会话层已挡，这里兜底）
    guard lineNumber == line, lineStart <= length else { return }

    textView.selectedRange = NSRange(location: lineStart, length: 0)
    textView.scrollRangeToVisible(NSRange(location: lineStart, length: 0))
}

/// 执行替换：当前匹配或全部匹配；必须经 shouldChangeText 撤销协议路径，
/// 全部替换是一次完整文档替换（单次 Cmd+Z 回滚，KTD7）
private func performReplace(textView: NSTextView, tab: EditorTab, all: Bool) {
    guard let state = tab.findState, !state.query.isEmpty, !state.regexError else { return }
    // 组字期间视图含未上屏的 marked text，模型与匹配区间已过期，替换会改错范围；
    // 拒绝执行，等组字结束 textDidChange 重新同步与重算后再替换
    guard !textView.hasMarkedText() else {
        NSSound.beep()
        return
    }
    let text = textView.string

    if all {
        guard let newText = FindEngine.replacingAll(state, in: text), newText != text else { return }
        replaceRange(NSRange(location: 0, length: (text as NSString).length),
                     with: newText, textView: textView, tab: tab)
        return
    }

    guard state.matches.indices.contains(state.current) else { return }
    let range = state.matches[state.current]
    let newText = FindEngine.replacementString(state, matchRange: range, in: text)
    guard newText != (text as NSString).substring(with: range) else {
        // 替换结果与原文相同（如空模板）：仍推进到下一个匹配
        tab.navigateMatch(1)
        return
    }
    replaceRange(range, with: newText, textView: textView, tab: tab)
}

/// 单区间替换：shouldChangeText 注册撤销 → 存储层替换 → didChangeText 触发模型同步与匹配重算，
/// 最后定位到重算后的当前匹配
private func replaceRange(_ range: NSRange, with newText: String, textView: NSTextView, tab: EditorTab) {
    guard textView.shouldChangeText(in: range, replacementString: newText),
          let storage = textView.textStorage else { return }
    storage.replaceCharacters(in: range, with: NSAttributedString(string: newText))
    textView.didChangeText()
    if let state = tab.findState, state.matches.indices.contains(state.current) {
        tab.findNavigationHandler?(state.current)
    }
}

/// 重建查找高亮（layoutManager 临时背景属性，独立于语法高亮的存储属性层）：
/// 当前匹配深色，其余浅色。
/// 清除范围收敛为"旧 ∪ 新匹配区间"——背景临时属性只可能落在匹配区间上，与全文清除严格等价
private func applyFindHighlight(textView: NSTextView, oldState: FindState?, state: FindState?) {
    guard let layoutManager = textView.layoutManager else { return }
    let full = NSRange(location: 0, length: (textView.string as NSString).length)
    let staleRanges = ((oldState?.matches ?? []) + (state?.matches ?? []))
        .map { NSIntersectionRange($0, full) }
        .filter { $0.length > 0 }
    for range in staleRanges {
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }
    guard let state, !state.matches.isEmpty else { return }
    let dimmed = NSColor.controlAccentColor.withAlphaComponent(0.25)
    let active = NSColor.controlAccentColor.withAlphaComponent(0.45)
    for (index, range) in state.matches.enumerated() {
        layoutManager.setTemporaryAttributes(
            [.backgroundColor: index == state.current ? active : dimmed],
            forCharacterRange: range)
    }
}
