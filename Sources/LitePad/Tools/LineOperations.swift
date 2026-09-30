import Foundation

/// 行操作种类（R17）：升序 / 降序排序、去重、删除行尾空白、合并行、大小写转换与注释开关。
/// 大小写与注释各拆成独立两项——菜单里可以直接点中要的那一项，抽屉里也是一项一个按钮，
/// 不必先在一组方向档位里切方向
enum LineOperationKind: String, CaseIterable, Identifiable {
    case sortAscending
    case sortDescending
    case deduplicate
    case trimTrailingWhitespace
    case joinLines
    case uppercase
    case lowercase
    case comment
    case uncomment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sortAscending: return "升序排序"
        case .sortDescending: return "降序排序"
        case .deduplicate: return "去重"
        case .trimTrailingWhitespace: return "删除行尾空白"
        case .joinLines: return "合并行"
        case .uppercase: return "转为大写"
        case .lowercase: return "转为小写"
        case .comment: return "添加行注释"
        case .uncomment: return "取消行注释"
        }
    }

    /// 注释类操作依赖语言的行注释符号：纯文本、HTML、XML、JSON 这类没有行注释符号的语言下
    /// 不可用（菜单置灰、抽屉里的按钮不可选）
    var requiresLineComment: Bool {
        self == .comment || self == .uncomment
    }
}

/// 行操作纯逻辑（R17 / KD5）：菜单与工具抽屉共用同一份实现。
///
/// 输入正文与目标范围、返回该范围的新正文。行按各自原有的行尾（`\n` / `\r\n` / `\r`）拆开并
/// 原样保留，不统一行尾：排序与改写只动行的正文，行尾按位置沿用区域里原有的那一串；
/// 行数变少时（去重、合并行）末尾的行尾始终保留，区域「是否以换行结尾」不因操作而改变。
///
/// 「目标范围」由调用方给出：菜单取选区覆盖到的整行（无选区时是全文），抽屉取输入文本的全部行
enum LineOperations {

    /// 选区覆盖到的整行范围（UTF-16 区间）：从选区起点所在行的行首到选区终点所在行的行尾。
    /// 选区为空（长度 0）时返回 nil，表示作用于全文。
    /// 范围不含最后一行的行尾——行尾留在范围之外，操作只替换行正文，区域末尾的换行原样不动；
    /// 终点落在行首时（选区把上一行的换行也框了进去）末行取终点前一个字符所在的行，
    /// 也就是「只选到某行加它的换行」不会被当成也选中了下一行
    static func lineRange(for selection: NSRange, in text: String) -> NSRange? {
        let nsText = text as NSString
        let clamped = NSIntersectionRange(selection, NSRange(location: 0, length: nsText.length))
        guard clamped.length > 0 else { return nil }

        let firstLine = nsText.lineRange(for: NSRange(location: clamped.location, length: 0))
        var contentsEnd = 0
        nsText.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                            for: NSRange(location: clamped.location + clamped.length - 1, length: 0))
        let end = max(firstLine.location, contentsEnd)
        return NSRange(location: firstLine.location, length: end - firstLine.location)
    }

    /// 执行行操作：返回目标范围的新正文（范围传 nil 时目标范围即全文，结果整篇返回）。
    /// 失败给中文原因——目前只有一种：注释类操作落在没有行注释符号的语言上
    /// （此时调用方应已按同一口径置灰入口，这里是兜底）
    static func apply(_ kind: LineOperationKind, to text: String, lineRange: NSRange?,
                      lineComment: String?) -> ConvertOutcome {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let range = NSIntersectionRange(lineRange ?? full, full)
        guard range.length > 0 else { return .success("") }

        let region = split(nsText.substring(with: range))
        var contents = region.contents

        switch kind {
        case .sortAscending:
            contents.sort()
        case .sortDescending:
            contents.sort(by: >)
        case .deduplicate:
            // 保留每个行正文的首次出现，比较按行正文原样（区分大小写、不忽略空白）
            var seen = Set<String>()
            contents = contents.filter { seen.insert($0).inserted }
        case .trimTrailingWhitespace:
            contents = contents.map(trimTrailingWhitespace)
        case .joinLines:
            // 合并成一行：行间以单个空格相连，行的正文原样（不额外去掉首尾空白）
            contents = [contents.joined(separator: " ")]
        case .uppercase:
            contents = contents.map { $0.uppercased() }
        case .lowercase:
            contents = contents.map { $0.lowercased() }
        case .comment:
            guard let marker = lineComment else { return .failure(commentUnavailable) }
            contents = contents.map { addingComment(to: $0, marker: marker) }
        case .uncomment:
            guard let marker = lineComment else { return .failure(commentUnavailable) }
            contents = contents.map { removingComment(from: $0, marker: marker) }
        }
        return .success(reassemble(contents, endings: region.endings))
    }

    /// 没有行注释符号的语言（纯文本、HTML、XML、JSON）上注释类操作的原因
    static let commentUnavailable = "当前语法没有行注释符号"

    // MARK: - 拆行与拼回

    /// 拆开的区域：每行的正文，以及与之一一对应的行尾。
    /// `endings[i]` 是第 i 行之后的行尾，最后一项就是区域末尾的那个换行（区域不以换行结尾时为空串）
    private struct SplitRegion {
        var contents: [String]
        var endings: [String]
    }

    /// 按原有行尾拆行：`\n`、`\r\n`、`\r` 三种都认，且原样记在行尾里
    private static func split(_ region: String) -> SplitRegion {
        let scalars = Array(region.unicodeScalars)
        var entries: [(content: String, ending: String)] = []
        var content = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\n" || scalar == "\r" else {
                content.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            var ending = String(scalar)
            if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
                ending += "\n"
                index += 1
            }
            entries.append((content, ending))
            content = ""
            index += 1
        }
        entries.append((content, ""))

        // 区域以换行结尾时，最后一项是那个换行留下的空尾行：它的行尾就是区域末尾的换行，
        // 直接丢掉这一项，末尾的换行就不会被当成一个空行去参与排序 / 去重
        if entries.count > 1, entries[entries.count - 1].content.isEmpty {
            entries.removeLast()
        }
        return SplitRegion(contents: entries.map(\.content), endings: entries.map(\.ending))
    }

    /// 按位置拼回：除最后一行取区域末尾的行尾外，各行取自己位置上的行尾。
    /// 行数变少时（去重、合并行）末尾的行尾仍落在新的最后一行上，区域末尾的换行不丢
    private static func reassemble(_ contents: [String], endings: [String]) -> String {
        let closing = endings.last ?? ""
        var result = ""
        for (index, content) in contents.enumerated() {
            result += content
            result += index == contents.count - 1 ? closing : (endings.indices.contains(index) ? endings[index] : closing)
        }
        return result
    }

    /// 去掉行尾空白（空格与制表符；换行已在拆行时单独拆走，不在这里处理）。
    /// 口径与保存时清理同一份（`SaveCleanup.isTrailingWhitespace`），不删不换行空格 / 全角空格
    private static func trimTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex, SaveCleanup.isTrailingWhitespace(line[line.index(before: end)]) {
            end = line.index(before: end)
        }
        return String(line[line.startIndex..<end])
    }

    /// 加行注释：插在行首缩进之后（没有缩进就插在行首），行正文非空时注释符后补一个空格，
    /// 空行只留注释符——空行不留行尾空白，也让「加一次再取消一次」回到原样
    private static func addingComment(to line: String, marker: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(indent.count)
        return String(indent) + marker + (body.isEmpty ? "" : " " + body)
    }

    /// 去行注释：只认行首缩进之后紧跟注释符的行，去掉注释符与其后的一个空格，其余行原样保留。
    /// 与 addingComment 严格互补，加一次再取消一次回到原样
    private static func removingComment(from line: String, marker: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        var body = line.dropFirst(indent.count)
        guard body.hasPrefix(marker) else { return line }
        body = body.dropFirst(marker.count)
        if body.first == " " {
            body = body.dropFirst()
        }
        return String(indent) + body
    }
}
