import SwiftUI
import AppKit

/// NSTextView 的 SwiftUI 封装：等宽字体、软换行、系统撤销/重做、行号栏、外观设置。
/// 文本编辑经由 delegate 回写模型；模型侧变化仅在内容确实不同时才回写视图，
/// 避免逐键输入时丢失光标位置。
struct CodeTextView: NSViewRepresentable {
    @ObservedObject var tab: EditorTab
    /// 文件投放要交给会话的统一打开入口；拖动回调是单向的，不需要观察它
    let session: EditorSession
    /// 观察全局设置：设置变化驱动 updateNSView 重应用外观
    @ObservedObject private var settings = AppSettings.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 自建 TextKit 1 栈：装饰（不可见元素 / 缩进指示 / 页面指示 / 当前行）在排版管理器里绘制
        let storage = NSTextStorage()
        let layoutManager = DecorationsLayoutManager()
        storage.addLayoutManager(layoutManager)
        // 非零初始 frame：SwiftUI 稍后才给 scrollView 实际尺寸，
        // 零尺寸 frame 会让 [.width] 自适应算出多余宽度，导致文字被行号栏遮住
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = LiteTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                    textContainer: container)
        context.coordinator.storage = storage
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // 不显式放大 maxSize 时，AppKit 会把它定为当前视口尺寸，文本视图到此为止不再长高，
        // 超出视口的行既画不出也滚不到（大文档滚不到末尾）；必须放到极大值
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                 height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = AppSettings.shared.editorFont
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
        tab.textSourceProvider = { [weak textView, weak tab] in
            guard let textView else { return (selection: "", fullText: tab?.text ?? "") }
            let nsText = textView.string as NSString
            let range = NSIntersectionRange(textView.selectedRange(),
                                            NSRange(location: 0, length: nsText.length))
            return (selection: range.length > 0 ? nsText.substring(with: range) : "",
                    fullText: textView.string)
        }
        tab.writeBackHandler = { [weak textView, weak tab] replacement, useSelection in
            guard let textView else { return }
            writeBack(replacement, useSelection: useSelection, textView: textView, tab: tab)
        }
        tab.saveCleanupHandler = { [weak coordinator = context.coordinator, weak textView] in
            // 视图与协调器同生共死：两者任一已释放说明编辑视图已拆除，交给会话走模型侧清理
            guard let coordinator, let textView else { return .noEditor }
            return performSaveCleanup(textView: textView, tab: coordinator.tab)
        }

        // 文件拖放：编辑区由文本视图在 AppKit 层接管（SwiftUI 的投放目标收不到这里的投放），
        // 拖入 / 离开驱动接收提示，投放把地址交给会话的统一打开入口
        textView.registerForDraggedTypes([.fileURL])
        textView.onFileDragActive = { [weak session] active in
            session?.isFileDropTargeted = active
        }
        textView.onFileDrop = { [weak session] urls in
            session?.openDroppedFiles(urls)
        }

        textView.string = tab.text
        SyntaxHighlighter.highlight(textView: textView, language: tab.language)
        context.coordinator.highlightedLanguage = tab.language
        context.coordinator.publishStats(from: textView)
        context.coordinator.applyAppearanceIfNeeded(textView: textView)
        return scrollView
    }

    /// 视图被拆除（切换标签、窗口关闭）后清掉清理回调：拆除后的视图没有撤销栈可走，
    /// 此后再保存该标签时由会话直接作用于模型文本
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tab.saveCleanupHandler = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 输入法组字期间（拼音预输入）视图里是 marked text，与模型必然不一致；
        // 此时回写 string / 选区会立刻中止组字，导致中文无法输入，必须整段跳过
        guard !textView.hasMarkedText() else { return }
        context.coordinator.applyAppearanceIfNeeded(textView: textView)
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
        /// 自建 TextKit 栈的存储，强持有防止被释放
        var storage: NSTextStorage?
        weak var textView: NSTextView?
        var highlightedLanguage: LanguageDefinition?
        var boundsObserver: NSObjectProtocol?
        /// 已应用过查找高亮的面板状态，避免无变化时重复全文清设
        var appliedFindState: FindState?
        /// 已应用到文本视图的外观配置；变化时才重设整篇属性
        var appliedAppearance: EditorAppearanceConfig?

        init(tab: EditorTab) {
            self.tab = tab
            super.init()
        }

        deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// 设置变化时才整体重应用（全篇属性设置代价高，不能逐键执行）
        func applyAppearanceIfNeeded(textView: NSTextView) {
            let config = EditorAppearanceConfig.from(AppSettings.shared)
            guard config != appliedAppearance else { return }
            appliedAppearance = config
            apply(config: config, textView: textView)
        }

        private func apply(config: EditorAppearanceConfig, textView: NSTextView) {
            let settings = AppSettings.shared
            let scrollView = textView.enclosingScrollView
            let font = settings.editorFont

            // 字体：后续输入与已有文本一并更新
            if textView.font !== font {
                textView.font = font
                if let storage {
                    storage.addAttribute(.font, value: font,
                                         range: NSRange(location: 0, length: storage.length))
                }
            }

            // 段落样式：行高倍数 / 自动换行缩进 / 书写方向
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = CGFloat(max(0.5, min(5, config.lineHeight)))
            paragraph.baseWritingDirection = config.writingDirection
            if config.wraps, config.wrapIndent > 0 {
                let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
                paragraph.headIndent = charWidth * CGFloat(min(32, config.wrapIndent))
            }
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes[.font] = font
            textView.typingAttributes[.paragraphStyle] = paragraph
            textView.typingAttributes[.ligature] = config.ligatures ? 1 : 0
            if let storage {
                let full = NSRange(location: 0, length: storage.length)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
                storage.addAttribute(.ligature, value: config.ligatures ? 1 : 0, range: full)
            }

            // 软换行 / 不换行（水平滚动）
            if config.wraps {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                textView.textContainer?.widthTracksTextView = true
                scrollView?.hasHorizontalScroller = false
            } else {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = []
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.size.width = 1_000_000
                scrollView?.hasHorizontalScroller = true
            }

            // 行号栏显隐
            scrollView?.rulersVisible = config.lineNumbers

            // 装饰层配置（不可见元素 / 缩进指示 / 页面指示 / 当前行）
            if let decorations = textView.layoutManager as? DecorationsLayoutManager {
                decorations.appearance = config
                decorations.updateCurrentLine(for: textView)
            }

            // 额外滚动
            if let liteTextView = textView as? LiteTextView {
                liteTextView.extraScrollFraction = CGFloat(max(0, min(1, config.extraScroll / 100)))
                liteTextView.sizeToFit()
            }

            // 编辑器透明度：不透明时走原生背景；半透明时关闭视图层背景，
            // 让带透明的窗口背景透出（三层同色叠加会加深透明度）
            let opacity = max(0.1, min(1, config.opacity / 100))
            if opacity >= 0.999 {
                textView.drawsBackground = true
                scrollView?.drawsBackground = true
                if let window = textView.window {
                    window.isOpaque = true
                    window.backgroundColor = .windowBackgroundColor
                }
            } else {
                textView.drawsBackground = false
                scrollView?.drawsBackground = false
                if let window = textView.window {
                    window.isOpaque = false
                    window.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(opacity)
                }
            }

            // 属性重设会重建字形，查找高亮需按当前状态重建
            appliedFindState = nil
            applyFindHighlight(textView: textView, oldState: nil, state: tab.findState)
            textView.needsDisplay = true
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
                if let decorations = textView.layoutManager as? DecorationsLayoutManager {
                    decorations.updateCurrentLine(for: textView)
                }
                tab.refreshMatches()
            }
            publishStats(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publishStats(from: textView)
            if let decorations = textView.layoutManager as? DecorationsLayoutManager {
                decorations.updateCurrentLine(for: textView)
            }
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
    // 替换里 `\n` 插入的换行取标签页的行尾：与状态栏显示、保存写盘的口径一致
    let lineBreak = tab.lineEnding.separator

    if all {
        guard let newText = FindEngine.replacingAll(state, in: text, lineBreak: lineBreak),
              newText != text else { return }
        replaceRange(NSRange(location: 0, length: (text as NSString).length),
                     with: newText, textView: textView, tab: tab)
        return
    }

    guard state.matches.indices.contains(state.current) else { return }
    let range = state.matches[state.current]
    let newText = FindEngine.replacementString(state, matchRange: range, in: text, lineBreak: lineBreak)
    guard newText != (text as NSString).substring(with: range) else {
        // 替换结果与原文相同（如空模板）：仍推进到下一个匹配
        tab.navigateMatch(1)
        return
    }
    replaceRange(range, with: newText, textView: textView, tab: tab)
}

/// 单区间替换：shouldChangeText 注册撤销 → 存储层替换 → didChangeText 触发模型同步与匹配重算，
/// 最后定位到重算后的当前匹配；返回是否真正替换（撤销协议拒绝时不改文本）
@discardableResult
private func replaceRange(_ range: NSRange, with newText: String, textView: NSTextView,
                          tab: EditorTab? = nil) -> Bool {
    guard textView.shouldChangeText(in: range, replacementString: newText),
          let storage = textView.textStorage else { return false }
    storage.replaceCharacters(in: range, with: NSAttributedString(string: newText))
    textView.didChangeText()
    if let tab, let state = tab.findState, state.matches.indices.contains(state.current) {
        tab.findNavigationHandler?(state.current)
    }
    return true
}

/// 工具面板结果写回：替换选区（选区为空则插入光标处）或替换全文，
/// 走 shouldChangeText 撤销协议路径（单次 Cmd+Z 回滚），并选中写入的内容便于确认
private func writeBack(_ replacement: String, useSelection: Bool, textView: NSTextView, tab: EditorTab?) {
    // 组字期间视图含未上屏的 marked text，模型与选区已过期，写回会错位；拒绝执行
    guard !textView.hasMarkedText() else {
        NSSound.beep()
        return
    }
    let nsText = textView.string as NSString
    let range = useSelection
        ? NSIntersectionRange(textView.selectedRange(), NSRange(location: 0, length: nsText.length))
        : NSRange(location: 0, length: nsText.length)
    guard nsText.substring(with: range) != replacement else { return }
    // 未真正替换时不改选区：否则选区可能落到文本末尾之外
    guard replaceRange(range, with: replacement, textView: textView, tab: tab) else { return }
    let inserted = NSRange(location: range.location, length: (replacement as NSString).length)
    textView.selectedRange = inserted
    textView.scrollRangeToVisible(inserted)
}

/// 保存前按设置就地清理正文（删除行尾空白 / 补齐末尾换行）：整篇作为一次替换走
/// shouldChangeText 撤销协议，单次 Cmd+Z 可整体回退到清理前，清理结果经 didChangeText
/// 即时回写模型，写出的字节与模型文本始终一致。是否适用（设置开关、语法排除）
/// 由会话统一判定，这里只负责执行
private func performSaveCleanup(textView: NSTextView, tab: EditorTab) -> SaveCleanupOutcome {
    let settings = AppSettings.shared
    // 组字期间视图含未上屏的 marked text：就地改写会把它一并提交、模型与匹配区间也会错位；
    // 拒绝这次清理，由会话中止本次保存并报错（不默默跳过设置项）
    guard !textView.hasMarkedText() else {
        return .rejected(reason: "编辑器正在输入法组字，请先结束组字再保存。")
    }

    let current = textView.string
    let cleaned = SaveCleanup.applying(to: current,
                                       trimTrailingWhitespace: settings.trimTrailingWhitespaceOnSave,
                                       ensureFinalNewline: settings.ensureFinalNewlineOnSave,
                                       lineEnding: tab.lineEnding)
    guard cleaned != current else { return .done }

    let selection = textView.selectedRange()
    // 整篇替换是一条撤销记录；replaceRange 内的 didChangeText 会把新文本同步回模型
    guard replaceRange(NSRange(location: 0, length: (current as NSString).length),
                       with: cleaned, textView: textView) else {
        return .rejected(reason: "编辑器的撤销协议拒绝了这次正文清理。")
    }
    // 清理只删行尾空白或在末尾追加换行，选区按原位置收拢即可，不必跳到哪里
    let length = (cleaned as NSString).length
    let location = min(selection.location, length)
    textView.selectedRange = NSRange(location: location,
                                     length: min(selection.length, length - location))
    return .done
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
