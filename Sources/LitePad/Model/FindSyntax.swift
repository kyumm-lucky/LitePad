import Foundation

/// 查找 / 替换面板的转义语法。
///
/// 面板是单行输入框，输不进真实换行，回车换行只能用转义表达（与主流编辑器查找框一致）：
/// - `\n`、`\r\n` → 换行；`\r` → 回车；`\t` → 制表符；`\\` → 反斜杠
/// - 其余 `\x` 原样保留（连同反斜杠），`C:\Users` 这类路径不受影响
/// - 查找侧的换行按「任意换行」匹配，LF / CRLF / CR 文档都能命中；
///   替换侧插入的是文档自身的换行符（`LineEnding.detect`），不制造混合行尾
enum FindSyntax {
    /// 任意换行：CRLF 在前，避免把一个 CRLF 拆成两次匹配
    static let anyLineBreakPattern = "(?:\\r\\n|\\r|\\n)"

    /// 是否含会被展开的转义。不含时字面量查找仍走原生字面匹配，
    /// 既有查找的语义与性能都不受影响
    static func hasEscapes(_ text: String) -> Bool {
        for token in tokenize(text) {
            if case .text = token { continue }
            return true
        }
        return false
    }

    /// 字面量查询 → 正则 pattern：普通字符按字面量转义，换行转义展开为任意换行。
    /// 转义查询走正则路径是为了让 `\n` 同时命中 LF / CRLF / CR 三种换行
    static func literalPattern(_ query: String) -> String {
        tokenize(query).map { token in
            switch token {
            case .text(let value): return NSRegularExpression.escapedPattern(for: value)
            case .lineBreak: return anyLineBreakPattern
            case .carriageReturn: return "\\r"
            case .tab: return "\\t"
            case .backslash: return "\\\\"
            }
        }.joined()
    }

    /// 正则查询 → ICU pattern：把字符类外的 `\n` 展开为任意换行。
    /// ICU 的 `\n` 只认 LF，CRLF 文档里 `l\n` 会漏掉行尾；`\\`、字符类内容与其它转义原样保留
    static func regexQuery(_ pattern: String) -> String {
        guard pattern.contains("\\n") else { return pattern }

        var result = ""
        var inClass = false
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "\\" {
                let next = pattern.index(after: index)
                guard next < pattern.endIndex else {
                    result.append(character)   // 末尾孤立反斜杠：交给 ICU 报错
                    break
                }
                if pattern[next] == "n", !inClass {
                    result += anyLineBreakPattern
                } else {
                    result.append(character)
                    result.append(pattern[next])
                }
                index = pattern.index(after: next)
                continue
            }
            if character == "[", !inClass {
                inClass = true
            } else if character == "]", inClass {
                inClass = false
            }
            result.append(character)
            index = pattern.index(after: index)
        }

        // 极端写法（如字符类里的半个方括号）改写后可能不合法：能编译的原文优先，避免本改写把可用正则变成「正则无效」
        if (try? NSRegularExpression(pattern: result)) == nil,
           (try? NSRegularExpression(pattern: pattern)) != nil {
            return pattern
        }
        return result
    }

    /// 字面量替换文本：`\n`、`\r\n` → 文档换行符；`\r` → 回车；`\t` → 制表符；
    /// `\\` → 反斜杠；其余 `\x` 原样保留
    static func literalReplacement(_ raw: String, lineBreak: String) -> String {
        tokenize(raw).map { token in
            switch token {
            case .text(let value): return value
            case .lineBreak: return lineBreak
            case .carriageReturn: return "\r"
            case .tab: return "\t"
            case .backslash: return "\\"
            }
        }.joined()
    }

    /// 正则替换模板：`\n`、`\r\n` → 文档换行符；`\r` → 回车；`\t` → 制表符。
    /// ICU 模板不认这些转义（`\n` 会退化成字母 n），必须在这里先展开；
    /// `\\`、`$1` 等仍按 ICU 模板语义交给 ICU
    static func regexTemplate(_ raw: String, lineBreak: String) -> String {
        tokenize(raw).map { token in
            switch token {
            case .text(let value): return value
            case .backslash: return "\\\\"
            case .lineBreak: return lineBreak
            case .carriageReturn: return "\r"
            case .tab: return "\t"
            }
        }.joined()
    }

    /// 单行输入框收到的真实换行（粘贴多行文本、Unicode 行分隔符）转成 `\n` 转义：
    /// 输入框里显示不出换行，转换后语义不变而内容可见，且与手输 `\n` 完全等价
    static func escapingRealNewlines(_ value: String) -> String {
        guard value.contains(where: \.isNewline) else { return value }
        var result = ""
        for character in value {
            if character.isNewline {
                result += "\\n"
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// 转义扫描：把输入切成「转义」与「原样文本」两类片段，三种消费方
    /// （字面量 pattern / 字面量替换文本 / 正则替换模板）各取所需，转义语义只有这一处定义
    private enum Token {
        /// 原样文本段，含未识别的 `\x`
        case text(String)
        /// `\n` 或 `\r\n`
        case lineBreak
        /// `\r`（后面不是 `\n`）
        case carriageReturn
        /// `\t`
        case tab
        /// `\\`
        case backslash
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var pending = ""
        func flushPending() {
            guard !pending.isEmpty else { return }
            tokens.append(.text(pending))
            pending = ""
        }

        let characters = Array(input)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count else {
                pending.append(characters[index])
                index += 1
                continue
            }
            switch characters[index + 1] {
            case "n":
                flushPending()
                tokens.append(.lineBreak)
                index += 2
            case "r":
                flushPending()
                // `\r\n`（两个转义连写）表示换行，和 `\n` 同义；单独的 `\r` 才是回车符
                if index + 3 < characters.count,
                   characters[index + 2] == "\\", characters[index + 3] == "n" {
                    tokens.append(.lineBreak)
                    index += 4
                } else {
                    tokens.append(.carriageReturn)
                    index += 2
                }
            case "t":
                flushPending()
                tokens.append(.tab)
                index += 2
            case "\\":
                flushPending()
                tokens.append(.backslash)
                index += 2
            default:
                pending.append("\\")
                pending.append(characters[index + 1])
                index += 2
            }
        }
        flushPending()
        return tokens
    }
}
