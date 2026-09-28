import Foundation
import Combine

/// 查找/替换面板状态；nil 表示面板关闭
struct FindState: Equatable {
    var query = ""
    var replacement = ""
    var useRegex = false
    var caseSensitive = false
    var wholeWord = false
    /// 正则非法时为 true（此时 matches 恒为空）
    var regexError = false
    var matches: [NSRange] = []
    /// 当前匹配索引（0 起）
    var current = 0
}

/// 查找选项 → 匹配计算；literal / 正则 / 全词 / 忽略大小写统一入口
enum FindEngine {
    /// 正则模式下的实际 pattern；全词在两侧加词边界
    private static func patternFor(_ state: FindState) -> String {
        state.wholeWord ? "\\b(?:" + state.query + ")\\b" : state.query
    }

    /// 按选项编译正则（含忽略大小写选项）；FindEngine 内唯一编译点，
    /// 保证查找、校验、替换三处的正则语义一致
    private static func compiledRegex(for state: FindState) -> NSRegularExpression? {
        var options = NSRegularExpression.Options()
        if !state.caseSensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: patternFor(state), options: options)
    }

    /// 正则是否可编译（literal 恒合法）
    static func isValid(_ state: FindState) -> Bool {
        guard state.useRegex, !state.query.isEmpty else { return true }
        return compiledRegex(for: state) != nil
    }

    /// 按选项计算全文匹配区间；空查找 / 非法正则返回空
    static func matches(for state: FindState, in text: String) -> [NSRange] {
        guard !state.query.isEmpty, isValid(state) else { return [] }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)

        if state.useRegex {
            guard let regex = compiledRegex(for: state) else { return [] }
            // 过滤零长度匹配（如 a*），避免定位与替换死循环
            return regex.matches(in: text, options: [], range: full).map(\.range).filter { $0.length > 0 }
        }

        var options: String.CompareOptions = []
        if !state.caseSensitive { options.insert(.caseInsensitive) }
        var ranges: [NSRange] = []
        var start = 0
        while start < nsText.length {
            let searchRange = NSRange(location: start, length: nsText.length - start)
            let found = nsText.range(of: state.query, options: options, range: searchRange, locale: nil)
            guard found.location != NSNotFound else { break }
            if !state.wholeWord || isWholeWord(found, in: nsText) {
                ranges.append(found)
            }
            start = found.location + max(found.length, 1)
        }
        return ranges
    }

    /// 全部替换后的新文本；非法正则返回 nil
    static func replacingAll(_ state: FindState, in text: String) -> String? {
        guard !state.regexError, isValid(state) else { return nil }
        // 两条路径都消费 state.matches（与面板计数同一份已过滤列表，零长匹配已剔除），
        // 保证"替换范围 = 显示计数"，杜绝计数 0/0 却仍替换的口径分裂
        let nsText = text as NSString
        var result = ""
        var cursor = 0

        if state.useRegex {
            guard let regex = compiledRegex(for: state) else { return nil }
            for range in state.matches {
                guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
                result += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result += regex.replacementString(for: match, in: text, offset: 0, template: state.replacement)
                cursor = range.location + range.length
            }
        } else {
            for range in state.matches {
                result += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result += state.replacement
                cursor = range.location + range.length
            }
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// 单个匹配的替换文本（正则模式支持 $1 捕获组回引）
    static func replacementString(_ state: FindState, matchRange: NSRange, in text: String) -> String {
        guard state.useRegex,
              let regex = compiledRegex(for: state),
              let match = regex.firstMatch(in: text, options: [], range: matchRange) else {
            return state.replacement
        }
        return regex.replacementString(for: match, in: text, offset: 0, template: state.replacement)
    }

    /// 全词判定：匹配两侧不能是词字符；CJK 逐字视为边界（与正则 \b 的 ICU 语义不混用）
    private static func isWholeWord(_ range: NSRange, in nsText: NSString) -> Bool {
        let end = range.location + range.length
        let beforeOK = range.location == 0 || !isWordChar(at: range.location - 1, in: nsText)
        let afterOK = end >= nsText.length || !isWordChar(at: end, in: nsText)
        return beforeOK && afterOK
    }

    private static func isWordChar(at index: Int, in nsText: NSString) -> Bool {
        // 按码点判定，避免 UTF-16 单元拆开代理对；孤立代理单元与 NUL 直接视为非词字符
        guard let scalar = Unicode.Scalar(nsText.character(at: index)) else { return false }
        return !DocumentStats.isCJKScalar(scalar) && CharacterSet.alphanumerics.contains(scalar)
    }
}

/// 单个标签页对应的文档状态
final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()

    @Published var text: String {
        didSet { refreshDirty() }
    }
    @Published private(set) var savedText: String
    @Published private(set) var fileURL: URL?
    @Published var language: LanguageDefinition
    @Published var encoding: TextEncoding {
        didSet { refreshDirty() }
    }
    @Published var lineEnding: LineEnding {
        didSet { refreshDirty() }
    }
    @Published private(set) var savedEncoding: TextEncoding
    @Published private(set) var savedLineEnding: LineEnding
    @Published private(set) var isDirty = false
    @Published private(set) var stats: DocumentStats = .empty
    /// 打开 / 最近一次保存时的文件修改时间，用于外部修改检测
    var fileModificationDate: Date?

    var displayName: String {
        fileURL?.lastPathComponent ?? "未命名"
    }

    /// 未指定编码 / 换行符时取全局设置的默认值；语法按扩展名检测，无文件时取默认语法设置
    init(fileURL: URL? = nil, text: String = "", savedText: String? = nil,
         encoding: TextEncoding? = nil, lineEnding: LineEnding? = nil) {
        let settings = AppSettings.shared
        let resolvedEncoding = encoding ?? settings.defaultEncoding
        let resolvedLineEnding = lineEnding ?? settings.defaultLineEnding
        self.fileURL = fileURL
        self.language = fileURL != nil
            ? LanguageDefinition.detect(from: fileURL)
            : settings.defaultLanguage
        self.text = text
        self.savedText = savedText ?? text
        self.encoding = resolvedEncoding
        self.lineEnding = resolvedLineEnding
        self.savedEncoding = resolvedEncoding
        self.savedLineEnding = resolvedLineEnding
        self.isDirty = false
        self.fileModificationDate = Self.fileDate(at: fileURL)
    }

    /// 读取文件当前修改时间
    static func fileDate(at url: URL?) -> Date? {
        guard let url else { return nil }
        return try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// 保存成功后调用：更新落盘基准与语言（扩展名可能变化）
    func markSaved(to url: URL?) {
        fileURL = url
        savedText = text
        savedEncoding = encoding
        savedLineEnding = lineEnding
        language = LanguageDefinition.detect(from: url)
        fileModificationDate = Self.fileDate(at: url)
        isDirty = false
    }

    /// 编辑器侧在文本 / 光标变化时刷新统计；值未变时不触发发布，避免多余刷新
    func updateStats(_ newStats: DocumentStats) {
        if newStats != stats {
            stats = newStats
        }
    }

    // MARK: - 查找/替换

    /// 修改查找条件（输入、开关变化），随后重算匹配
    func updateFind(_ mutate: (inout FindState) -> Void) {
        guard var state = findState else { return }
        mutate(&state)
        applyFindState(state)
    }

    /// 上一个/下一个匹配（循环滚动），并通知视图定位
    func navigateMatch(_ delta: Int) {
        guard var state = findState, !state.matches.isEmpty else { return }
        let count = state.matches.count
        state.current = ((state.current + delta) % count + count) % count
        findState = state
        findNavigationHandler?(state.current)
    }

    /// 文本变化后重算当前查找的匹配（保持条件不变）
    func refreshMatches() {
        guard let state = findState else { return }
        applyFindState(state)
    }

    /// 校验 + 重算匹配后发布；非法正则置 regexError 且匹配清空
    func applyFindState(_ state: FindState) {
        var newState = state
        newState.regexError = state.useRegex && !FindEngine.isValid(state)
        newState.matches = newState.regexError ? [] : FindEngine.matches(for: newState, in: text)
        if newState.current >= newState.matches.count {
            newState.current = 0
        }
        findState = newState
    }

    /// 跳转到行的视图层回调：由 CodeTextView 安装，会话层只发行号（非发布属性，不参与刷新）
    var goToLineHandler: ((Int) -> Void)?
    /// 查找定位回调：由 CodeTextView 安装，选中并滚动到第 index 个匹配
    var findNavigationHandler: ((Int) -> Void)?
    /// 替换回调：由 CodeTextView 安装（撤销协议路径必须在视图层执行）；参数 true = 全部替换
    var replaceHandler: ((Bool) -> Void)?
    /// 编辑器文本来源：由 CodeTextView 安装，返回当前选区文本（无选区时为空串）与全文，
    /// 供工具面板取文本
    var textSourceProvider: (() -> (selection: String, fullText: String))?
    /// 工具结果写回：由 CodeTextView 安装（撤销协议路径必须在视图层执行）；
    /// useSelection 为真替换当前选区（无选区则插入光标处），为假替换全文
    var writeBackHandler: ((String, Bool) -> Void)?
    /// 查找/替换面板状态；nil 表示面板关闭
    @Published var findState: FindState?

    private func refreshDirty() {
        isDirty = text != savedText
            || encoding != savedEncoding
            || lineEnding != savedLineEnding
    }
}
