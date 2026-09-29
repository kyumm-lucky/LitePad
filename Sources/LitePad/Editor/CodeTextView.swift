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
        tab.lineOperationHandler = { [weak textView, weak tab] kind in
            guard let textView else { return }
            applyLineOperation(kind, textView: textView, tab: tab)
        }
        tab.saveCleanupHandler = { [weak coordinator = context.coordinator, weak textView] in
            // 视图与协调器同生共死：两者任一已释放说明编辑视图已拆除，交给会话走模型侧清理
            guard let coordinator, let textView else { return .noEditor }
            return performSaveCleanup(textView: textView, tab: coordinator.tab)
        }
        // 组字状态只读查询：会话据此在组字期间拒绝重读这类整串改写
        tab.compositionStateProvider = { [weak textView] in
            textView?.hasMarkedText() ?? false
        }
        // 重读落点：整串替换必须在视图层走撤销协议（KTD14），会话只负责读盘与校验
        tab.reloadTextHandler = { [weak coordinator = context.coordinator] newText in
            guard let coordinator else { return false }
            return coordinator.reloadWholeText(newText)
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

        // 自动缩进的文档上下文：语言决定块开头判定、行尾符决定回车插入的换行，
        // 视图不持有标签，取值都经闭包回取（标签被拆除后回落为纯文本与 LF）
        textView.indentContextProvider = { [weak tab] in
            EditorIndentContext(language: tab?.language ?? .plain,
                                lineSeparator: tab?.lineEnding.separator ?? "\n")
        }

        textView.string = tab.text
        SyntaxHighlighter.highlight(textView: textView, language: tab.language)
        context.coordinator.highlightedLanguage = tab.language
        context.coordinator.publishStats(from: textView)
        context.coordinator.applyAppearanceIfNeeded(textView: textView)
        return scrollView
    }

    /// 视图被拆除（切换标签、窗口关闭）后清掉清理回调与重读落点：拆除后的视图没有撤销栈可走，
    /// 此后再保存该标签时由会话直接作用于模型文本，重读同样落到模型侧
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // 撤销管理器是窗口级的、所有标签共用：切走时清掉本标签登记的动作，
        // 否则在下一张标签里按撤销会落到已经拆除的视图上（KTD14 说的失效区间）
        (scrollView.documentView as? NSTextView)?.undoManager?.removeAllActions()
        coordinator.tab.saveCleanupHandler = nil
        coordinator.tab.compositionStateProvider = nil
        coordinator.tab.reloadTextHandler = nil
        coordinator.tab.lineOperationHandler = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 输入法组字期间（拼音预输入）视图里是 marked text，与模型必然不一致；
        // 此时回写 string / 选区会立刻中止组字，导致中文无法输入，必须整段跳过
        guard !textView.hasMarkedText() else { return }
        context.coordinator.applyAppearanceIfNeeded(textView: textView)
        let languageChanged = context.coordinator.highlightedLanguage != tab.language

        if textView.string != tab.text {
            // 整串赋值清不掉撤销管理器里已登记的动作，之后再按撤销会在失效区间上抛异常并终止进程（KTD14）；
            // 这条赋值是外部改动重载与模型侧改写的落点，赋值前先清空撤销栈是唯一可行的口径
            textView.undoManager?.removeAllActions()
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
            // 整串重写会清空 layoutManager 临时属性，重置高亮快照让下方按新状态重建
            context.coordinator.appliedHighlight = HighlightSnapshot()
        } else if languageChanged {
            context.coordinator.highlightedLanguage = tab.language
            SyntaxHighlighter.highlight(textView: textView, language: tab.language)
        }

        // 高亮（查找匹配 + 选中词出现）有变化时重建；选区/滚动只由 findNavigationHandler 驱动，
        // 避免用户输入时被抢走光标
        context.coordinator.applyHighlightsIfNeeded(textView: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let tab: EditorTab
        /// 自建 TextKit 栈的存储，强持有防止被释放
        var storage: NSTextStorage?
        weak var textView: NSTextView?
        var highlightedLanguage: LanguageDefinition?
        var boundsObserver: NSObjectProtocol?
        /// 已应用过的高亮快照（查找匹配 + 选中词出现），避免无变化时重复全文清设
        fileprivate var appliedHighlight = HighlightSnapshot()
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

            // 段落样式：行高倍数 / 自动换行缩进 / 书写方向 / 制表位
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = CGFloat(max(0.5, min(5, config.lineHeight)))
            paragraph.baseWritingDirection = config.writingDirection
            let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
            if config.wraps, config.wrapIndent > 0 {
                paragraph.headIndent = charWidth * CGFloat(min(32, config.wrapIndent))
            }
            // 制表位按缩进宽度换算：真实制表符的显示宽度与缩进指示线的一级宽度同源（KTD10）。
            // 基数取空格宽度——缩进指示线也是按空格宽度量的，两边同一把尺子才谈得上对齐；
            // tabStops 必须先清空：段落样式自带一组 28 点默认制表位，非空时 defaultTabInterval 不生效
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
            paragraph.tabStops = []
            paragraph.defaultTabInterval = spaceWidth * CGFloat(max(1, config.indentWidth))
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

            // 属性重设会重建字形，高亮需按当前状态重建
            rebuildHighlights(textView: textView)
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
            // 选中词高亮跟随选区；组字期间视图里是 marked text，等组字结束再重建
            if !textView.hasMarkedText() {
                applyHighlightsIfNeeded(textView: textView)
            }
        }

        /// 把光标、选区与文本统计发布到标签页模型，驱动状态栏刷新
        func publishStats(from textView: NSTextView) {
            let selection = textView.selectedRange()
            tab.updateStats(DocumentStats.compute(text: textView.string,
                                                  caretOffset: selection.location,
                                                  selectionRange: selection))
        }

        /// 按当前查找状态与选区重算高亮快照，有变化才重建；两者写同一层临时背景属性，
        /// 必须合成一次应用（各画各的会互相抹掉）
        func applyHighlightsIfNeeded(textView: NSTextView) {
            let snapshot = currentHighlightSnapshot(textView: textView)
            guard snapshot != appliedHighlight else { return }
            let old = appliedHighlight
            appliedHighlight = snapshot
            applyHighlights(textView: textView, old: old, new: snapshot)
        }

        /// 无条件重建：外观属性重设会重建字形、丢掉已画的高亮，此处按当前状态重画
        func rebuildHighlights(textView: NSTextView) {
            let old = appliedHighlight
            let snapshot = currentHighlightSnapshot(textView: textView)
            appliedHighlight = snapshot
            applyHighlights(textView: textView, old: old, new: snapshot)
        }

        /// 当前应有的高亮快照（查找匹配 + 选中词出现）
        private func currentHighlightSnapshot(textView: NSTextView) -> HighlightSnapshot {
            HighlightSnapshot(find: tab.findState,
                              selection: selectedWordHighlight(for: textView))
        }

        /// 重读落点：把按编码重读得到的整串正文换进编辑视图。整串替换前先清空撤销栈（KTD14）——
        /// 栈里旧动作记的区间在整串替换后失效，之后按撤销会在失效区间上抛异常；替换本身仍走
        /// shouldChangeText 撤销协议，替换后的 didChangeText 会把新正文同步回模型并重算查找匹配
        /// 区间（KTD15），选区按原位置收拢。返回是否完成替换（组字中或撤销协议拒绝时 false，会话据此中止重读）
        func reloadWholeText(_ newText: String) -> Bool {
            guard let textView else { return false }
            // 组字期间视图含未上屏的 marked text：替换会把它一并提交、模型与匹配区间也会错位；
            // 拒绝本次替换（会话在发起重读前已按同一口径拦过一次，这里只兜底）
            guard !textView.hasMarkedText() else {
                NSSound.beep()
                return false
            }
            guard newText != textView.string else { return true }

            let selection = textView.selectedRange()
            textView.undoManager?.removeAllActions()
            guard replaceRange(NSRange(location: 0, length: (textView.string as NSString).length),
                               with: newText, textView: textView, tab: tab) else { return false }
            let length = (newText as NSString).length
            let location = min(selection.location, length)
            textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            // 整串替换会清空 layoutManager 的临时属性（高亮画在那一层）：重置高亮快照，
            // 让 updateNSView 按新状态重建，与模型侧赋值那条路同一口径（KTD15）
            appliedHighlight = HighlightSnapshot()
            return true
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

/// 行操作（菜单入口）：目标范围是选区覆盖到的整行，无选区时是全文——这个范围既不是当前选区
/// 也不是全文，只有视图层算得出来。共用的纯逻辑算出该范围的新正文后整段替换，走
/// shouldChangeText 撤销协议路径（单次 Cmd+Z 回退整次操作）。有选区时替换后选中操作过的整段，
/// 便于确认范围；无选区（整篇）时不改选区，避免一次全选之后误删
private func applyLineOperation(_ kind: LineOperationKind, textView: NSTextView, tab: EditorTab?) {
    // 组字期间视图含未上屏的 marked text，模型与选区已过期，改写会错位；拒绝执行
    guard !textView.hasMarkedText() else {
        NSSound.beep()
        return
    }
    let text = textView.string
    let nsText = text as NSString
    let selection = NSIntersectionRange(textView.selectedRange(),
                                        NSRange(location: 0, length: nsText.length))
    let lineRange = LineOperations.lineRange(for: selection, in: text)
    let outcome = LineOperations.apply(kind, to: text, lineRange: lineRange,
                                       lineComment: tab?.language.lineComment)
    guard case .success(let replacement) = outcome else {
        // 注释类操作落在没有行注释符号的语言上：菜单项已按同一口径置灰，这里只兜底
        NSSound.beep()
        return
    }
    let target = lineRange ?? NSRange(location: 0, length: nsText.length)
    // 结果与原文一致时不写回：不留一条什么都没改的撤销记录
    guard nsText.substring(with: target) != replacement else { return }
    guard replaceRange(target, with: replacement, textView: textView, tab: tab) else { return }
    if lineRange != nil {
        let inserted = NSRange(location: target.location, length: (replacement as NSString).length)
        textView.selectedRange = inserted
        textView.scrollRangeToVisible(inserted)
    } else {
        // 整篇改写后光标按原偏移收拢到文末之内（整篇选中容易误删，这里不改成全选）；
        // 滚动跟着回来：replaceRange 可能已把视图滚到当前查找匹配处
        let caret = min(selection.location, (textView.string as NSString).length)
        textView.selectedRange = NSRange(location: caret, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange())
    }
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

/// 一次应用的全部高亮：查找匹配与选中词出现。
/// 两者写的是同一层临时背景属性（layoutManager 的临时属性表），各自独立清设会互相抹掉，
/// 因此合成一份快照一次应用
private struct HighlightSnapshot: Equatable {
    var find: FindState?
    var selection: SelectedWordHighlight?

    /// 快照覆盖的全部区间
    var ranges: [NSRange] {
        (find?.matches ?? []) + (selection?.ranges ?? [])
    }
}

/// 当前选区的选中词高亮：无选区或不在启用口径内时为 nil。
/// 走字面扫描而非查找引擎（KTD11）——查找已支持转义语法，选中文本里的字面反斜杠序列会被当成转义
private func selectedWordHighlight(for textView: NSTextView) -> SelectedWordHighlight? {
    let text = textView.string
    let nsText = text as NSString
    let range = NSIntersectionRange(textView.selectedRange(),
                                    NSRange(location: 0, length: nsText.length))
    guard range.length > 0 else { return nil }
    return SelectedWordHighlight.scan(selection: nsText.substring(with: range), in: text)
}

/// 重建高亮（layoutManager 临时背景属性，独立于语法高亮的存储属性层）：
/// 先按「旧 ∪ 新」的全部区间清除——背景临时属性只可能落在这些区间上，与全文清除严格等价；
/// 再先画选中词的出现（全部同色），后画查找匹配（当前匹配深色，其余浅色）——
/// 同一区间上两者重合时查找高亮在上，当前匹配的位置不会被选中词高亮盖掉
private func applyHighlights(textView: NSTextView, old: HighlightSnapshot, new: HighlightSnapshot) {
    guard let layoutManager = textView.layoutManager else { return }
    let full = NSRange(location: 0, length: (textView.string as NSString).length)
    let staleRanges = (old.ranges + new.ranges)
        .map { NSIntersectionRange($0, full) }
        .filter { $0.length > 0 }
    for range in staleRanges {
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    }
    if let selection = new.selection {
        // 与当前选区一起看：比查找高亮更淡，出现与选中词区分得开
        let color = NSColor.controlAccentColor.withAlphaComponent(0.22)
        for range in selection.ranges {
            layoutManager.setTemporaryAttributes([.backgroundColor: color], forCharacterRange: range)
        }
    }
    guard let state = new.find, !state.matches.isEmpty else { return }
    let dimmed = NSColor.controlAccentColor.withAlphaComponent(0.25)
    let active = NSColor.controlAccentColor.withAlphaComponent(0.45)
    for (index, range) in state.matches.enumerated() {
        layoutManager.setTemporaryAttributes(
            [.backgroundColor: index == state.current ? active : dimmed],
            forCharacterRange: range)
    }
}
