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
    /// 正则模式下的实际 pattern：查询串先做换行适配（`\n` 兼容 LF / CRLF / CR），全词在两侧加词边界
    private static func regexPattern(_ state: FindState) -> String {
        let body = FindSyntax.regexQuery(state.query)
        return state.wholeWord ? "\\b(?:" + body + ")\\b" : body
    }

    /// 正则模式编译入口；FindEngine 内唯一编译点，保证查找、校验、替换三处的正则语义一致
    private static func compiledRegex(for state: FindState) -> NSRegularExpression? {
        compiled(pattern: regexPattern(state), caseSensitive: state.caseSensitive)
    }

    private static func compiled(pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        var options = NSRegularExpression.Options()
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: options)
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

        // 含 `\n` 等转义的查询串走正则路径：\n 要能命中 LF / CRLF / CR 三种换行（见 FindSyntax）
        if FindSyntax.hasEscapes(state.query) {
            guard let regex = compiled(pattern: FindSyntax.literalPattern(state.query),
                                       caseSensitive: state.caseSensitive) else { return [] }
            let ranges = regex.matches(in: text, options: [], range: full).map(\.range).filter { $0.length > 0 }
            // 全词判定仍走 CJK 逐字视为边界的 isWholeWord，与 \b 的 ICU 语义不混用
            return state.wholeWord ? ranges.filter { isWholeWord($0, in: nsText) } : ranges
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

    /// 全部替换后的新文本；非法正则返回 nil。
    /// `lineBreak` 是替换里插入的换行（取标签页的 lineEnding：与状态栏显示、保存写入的换行一致，
    /// 不能从文本现推——文本若刚好没有换行会误判成 LF）
    static func replacingAll(_ state: FindState, in text: String, lineBreak: String) -> String? {
        guard !state.regexError, isValid(state) else { return nil }
        // 两条路径都消费 state.matches（与面板计数同一份已过滤列表，零长匹配已剔除），
        // 保证"替换范围 = 显示计数"，杜绝计数 0/0 却仍替换的口径分裂
        let nsText = text as NSString
        var result = ""
        var cursor = 0

        if state.useRegex {
            guard let regex = compiledRegex(for: state) else { return nil }
            // ICU 模板不认 \n 等转义，先展开成真实字符（含文档换行符）再交给 ICU 处理 $1 之类的回引
            let template = FindSyntax.regexTemplate(state.replacement, lineBreak: lineBreak)
            for range in state.matches {
                guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
                result += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result += regex.replacementString(for: match, in: text, offset: 0, template: template)
                cursor = range.location + range.length
            }
        } else {
            let replacement = FindSyntax.literalReplacement(state.replacement, lineBreak: lineBreak)
            for range in state.matches {
                result += nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result += replacement
                cursor = range.location + range.length
            }
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// 单个匹配的替换文本（正则模式支持 $1 捕获组回引、`\n` 等转义插入文档换行符）
    static func replacementString(_ state: FindState, matchRange: NSRange, in text: String,
                                 lineBreak: String) -> String {
        guard state.useRegex,
              let regex = compiledRegex(for: state),
              let match = regex.firstMatch(in: text, options: [], range: matchRange) else {
            return FindSyntax.literalReplacement(state.replacement, lineBreak: lineBreak)
        }
        return regex.replacementString(for: match, in: text, offset: 0,
                                       template: FindSyntax.regexTemplate(state.replacement,
                                                                          lineBreak: lineBreak))
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

/// 未标题标签的标题编号（R8 / KD4）：「新文件1」「新文件2」……
/// 序号取当前已打开标签中出现过的最大序号 + 1，因此同一会话内不会出现两张同名标签；
/// 不承诺跨会话的全局递增 —— 恢复出来的标签沿用存下来的标题，也从它们继续往下算
enum UntitledTitle {
    static let prefix = "新文件"

    /// 下一个标题：`titles` 是当前所有标签的未标题标题（已绑定文件的标签也要传进来，
    /// 它的标题在关闭前一直占位，否则序号会被下一个新标签复用）
    static func next(after titles: [String]) -> String {
        "\(prefix)\(maxSequence(in: titles) + 1)"
    }

    /// 一份标题里出现过的最大序号；一个都取不到时按 0（下一个即「新文件1」）
    static func maxSequence(in titles: [String]) -> Int {
        titles.compactMap(sequence(in:)).max() ?? 0
    }

    /// 从「新文件N」式标题里取序号；不是这个形状的（含已按扩展名保存的文件名）返回 nil
    private static func sequence(in title: String) -> Int? {
        guard title.hasPrefix(prefix) else { return nil }
        return Int(title.dropFirst(prefix.count))
    }
}

/// 保存前清理的执行结果（会话 ⇄ 编辑视图的桥接口径）
enum SaveCleanupOutcome {
    /// 已清理或无需清理
    case done
    /// 该标签当前没有可用的编辑视图：没有撤销栈可走，由会话改用模型侧清理
    case noEditor
    /// 编辑视图拒绝了这次改动，附带中止原因；会话据此中止本次保存并报错
    case rejected(reason: String)
}

/// 单个标签页对应的文档状态
final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()
    /// 未标题标签的稳定标题（R8 / KD4）：「新文件1」式，由会话在建立标签时分配，
    /// 标签存活期间不变（不随活动标签或编辑内容变化）。绑定文件后展示名改用文件名，
    /// 这个标题只用来定位恢复区条目；打开文件建出的标签为 nil
    let untitledTitle: String?

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
        fileURL?.lastPathComponent ?? untitledTitle ?? "未命名"
    }

    /// 未指定编码 / 换行符时取全局设置的默认值；语法按扩展名检测，无文件时取默认语法设置。
    /// `untitledTitle` 由会话分配（恢复出来的标签传入存下来的标题）；`savedText` 是落盘基准，
    /// 不传即「刚建出的干净标签」，恢复出来的内容则要显式传空串让它带脏标记
    init(fileURL: URL? = nil, text: String = "", savedText: String? = nil,
         encoding: TextEncoding? = nil, lineEnding: LineEnding? = nil,
         untitledTitle: String? = nil) {
        let settings = AppSettings.shared
        let resolvedEncoding = encoding ?? settings.defaultEncoding
        let resolvedLineEnding = lineEnding ?? settings.defaultLineEnding
        self.fileURL = fileURL
        self.untitledTitle = untitledTitle
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
        // 基准与正文不一致的初始态（恢复出来的标签把基准传成空串）要在建出来的那一刻就是脏的：
        // init 期间 didSet 不会触发，脏标记必须在这里对齐一次
        refreshDirty()
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
    /// 行操作回调：由 CodeTextView 安装（撤销协议路径必须在视图层执行）、视图拆除时清回 nil。
    /// 目标范围是选区覆盖到的整行（无选区时是全文），这个范围既不是当前选区也不是全文，
    /// 只有视图层算得出来；视图算出范围后调共用的纯逻辑，再整段替换（一次可撤销的动作）
    var lineOperationHandler: ((LineOperationKind) -> Void)?
    /// 保存前清理回调：由 CodeTextView 安装（撤销协议路径必须在视图层执行），
    /// 视图拆除时清回 nil。显式保存前调用：清理必须是一次可整体撤销的编辑动作，
    /// 不得改模型文本再推给视图——那会给撤销栈埋下失效区间（KTD5、KTD14）
    var saveCleanupHandler: (() -> SaveCleanupOutcome)?
    /// 编辑器是否处于输入法组字（marked text）状态：由 CodeTextView 安装，只读查询；
    /// 视图不存在（已拆除或尚未建立）时为 nil，按「不在组字」处理。
    /// 重读这类整串改写必须在组字期间拒绝——组字结束时视图会把自身内容推回模型，
    /// 刚重读的正确正文会被组字前的旧内容覆盖，并在一秒后被自动写盘写回文件
    var compositionStateProvider: (() -> Bool)?
    /// 整串正文重读的落点：由 CodeTextView 安装（整串替换必须在视图层走撤销协议，KTD14），
    /// 返回是否完成替换。视图不存在时为 nil，会话改走模型侧赋值——那时没有撤销栈要清
    var reloadTextHandler: ((String) -> Bool)?
    /// 本标签的写盘失败是否已提示过：写盘成功时复位，保证自动写盘的连续失败只打扰一次，
    /// 也避免与状态栏的「未保存」混同
    var writeFailureReported = false
    /// 查找/替换面板状态；nil 表示面板关闭
    @Published var findState: FindState?

    private func refreshDirty() {
        isDirty = text != savedText
            || encoding != savedEncoding
            || lineEnding != savedLineEnding
    }
}
