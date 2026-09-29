import Foundation
import Combine

/// 工具种类：标题栏「工具」下拉的条目，同时也是工具面板内的切换项
enum TextToolKind: String, CaseIterable, Identifiable {
    case unicode
    case ascii
    case url
    case base64
    case json
    case diff
    case lines

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unicode: return "Unicode 转义"
        case .ascii: return "ASCII 码"
        case .url: return "URL 编码"
        case .base64: return "Base64"
        case .json: return "JSON 格式化"
        case .diff: return "字符串对比"
        case .lines: return "行操作"
        }
    }

    var symbolName: String {
        switch self {
        case .unicode: return "character"
        case .ascii: return "number"
        case .url: return "link"
        case .base64: return "arrow.left.arrow.right"
        case .json: return "curlybraces"
        case .diff: return "rectangle.split.2x1"
        case .lines: return "arrow.up.arrow.down"
        }
    }

    /// 两档方向的名称，顺序与 ConvertDirection.allCases 一致：
    /// JSON 工具的两档是「格式化（.encode）/ 压缩（.decode）」，其余是「编码 / 解码」。
    /// 行操作不设方向档（一项操作一个按钮），永不渲染这个分段控件
    var directionLabels: [String] {
        self == .json ? ["格式化", "压缩"] : ConvertDirection.allCases.map(\.displayName)
    }

    /// 对比工具用 A/B 两栏，其余工具用「输入 → 结果」
    var isConverter: Bool { self != .diff }
}

/// 工具面板状态：输入与选项任一变化即重算结果。
/// 会话级持有（跨标签保留选项与文本），编辑器选区只在打开面板或点「取编辑器」时取用
@MainActor
final class TextToolsState: ObservableObject {
    @Published var kind: TextToolKind = .unicode

    // MARK: - 编码转换

    @Published var input = ""
    @Published var direction: ConvertDirection = .encode
    /// Unicode：连 ASCII 一起转义
    @Published var unicodeEscapesASCII = false
    /// ASCII 码：码值基数
    @Published var numericBase: NumericBase = .decimal
    /// URL：空格编码为 `+`
    @Published var urlSpaceAsPlus = false
    /// Base64：URL 安全字符
    @Published var base64URLSafe = false
    /// JSON：格式化时的缩进档位
    @Published var jsonIndent: JSONIndent = .twoSpaces

    /// 工具切换方向：新工具在列表里更靠后时为真，面板据此决定内容换场的推进方向。
    /// 与 kind 在同一次赋值中发出，视图在同一帧里同时看到新工具与方向
    @Published private(set) var toolSwitchesForward = true
    @Published private(set) var output = ""
    @Published private(set) var errorMessage: String?

    // MARK: - 字符串对比

    @Published var diffLeft = ""
    @Published var diffRight = ""
    @Published var diffIgnoreCase = false
    @Published var diffIgnoreWhitespace = false
    @Published private(set) var diff = DiffResult.empty

    // MARK: - 行操作

    /// 最近选用的行操作（nil = 还没选过）：抽屉里的行操作是一排按钮，选中一项才算一次结果
    @Published private(set) var lineOperation: LineOperationKind?
    /// 当前标签语法的行注释符号：注释类操作要用它，nil 表示该语言没有行注释符号。
    /// 由抽屉按标签语言同步（见 updateLineComment），保存在这里是为了让输入变化后的重算不用再问环境
    private var lineComment: String?

    // MARK: - 变更入口

    /// 切换工具：结果留待重算，输入与选项保留
    func select(kind: TextToolKind) {
        guard kind != self.kind else { return }
        let order = TextToolKind.allCases
        if let previous = order.firstIndex(of: self.kind), let next = order.firstIndex(of: kind) {
            toolSwitchesForward = next > previous
        }
        self.kind = kind
        recompute()
    }

    /// 从编辑器取文本：对比工具填入左栏（右栏保留，便于与标签页或手工输入比对），
    /// 其余工具填入输入栏
    func seed(from text: String) {
        switch kind {
        case .diff:
            diffLeft = text
        default:
            input = text
        }
        recompute()
    }

    /// 填入对比右栏（「从标签页取文本」）
    func fillDiffRight(from text: String) {
        diffRight = text
        recompute()
    }

    /// 写入输入栏（面板内直接编辑）
    func updateInput(_ text: String) {
        input = text
        recompute()
    }

    func updateDiffLeft(_ text: String) {
        diffLeft = text
        recompute()
    }

    func updateDiffRight(_ text: String) {
        diffRight = text
        recompute()
    }

    // MARK: - 行操作入口

    /// 选用一项行操作并按当前输入算出结果；lineComment 是当前标签语法的行注释符号
    /// （没有行注释符号的语言上注释类操作会失败，按钮侧已按同一口径置灰，这里是兜底）
    func applyLineOperation(_ kind: LineOperationKind, lineComment: String?) {
        self.lineComment = lineComment
        lineOperation = kind
        recompute()
    }

    /// 同步当前标签语法的行注释符号：切换标签或改语言后，注释类操作的结果与可用性跟着变
    func updateLineComment(_ symbol: String?) {
        guard symbol != lineComment else { return }
        lineComment = symbol
        guard kind == .lines, lineOperation != nil else { return }
        recompute()
    }

    /// 任一输入或选项变化后重算：只算当前工具用得到的那一份
    func recompute() {
        guard kind.isConverter else {
            diff = TextDiffEngine.compare(diffLeft, diffRight,
                                          ignoreCase: diffIgnoreCase,
                                          ignoreWhitespace: diffIgnoreWhitespace)
            return
        }
        let outcome: ConvertOutcome
        switch kind {
        case .unicode:
            outcome = direction == .encode
                ? .success(UnicodeEscapeConverter.encode(input, escapeASCII: unicodeEscapesASCII))
                : .success(UnicodeEscapeConverter.decode(input))
        case .ascii:
            outcome = direction == .encode
                ? .success(ASCIICodeConverter.encode(input, base: numericBase))
                : .success(ASCIICodeConverter.decode(input, base: numericBase))
        case .url:
            outcome = direction == .encode
                ? .success(URLPercentConverter.encode(input, spaceAsPlus: urlSpaceAsPlus))
                : URLPercentConverter.decode(input)
        case .base64:
            outcome = direction == .encode
                ? .success(Base64Converter.encode(input, urlSafe: base64URLSafe))
                : Base64Converter.decode(input)
        case .json:
            outcome = direction == .encode
                ? JSONFormatter.pretty(input, indent: jsonIndent)
                : JSONFormatter.minify(input)
        case .lines:
            // 抽屉里的行操作作用于输入文本的全部行；还没选操作时结果区空着
            guard let operation = lineOperation else {
                output = ""
                errorMessage = nil
                return
            }
            outcome = LineOperations.apply(operation, to: input, lineRange: nil,
                                           lineComment: lineComment)
        case .diff:
            return
        }
        output = outcome.text
        errorMessage = outcome.errorMessage
    }
}
