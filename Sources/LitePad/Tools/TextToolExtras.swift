import Foundation

/// 正则测试器：被测文本取自输入区，模式与忽略大小写取自工具选项。
/// 结果列出每个匹配的区间、命中文本与捕获组，便于写正则时逐步核对
enum RegexTester {
    static func test(pattern: String, text: String, ignoreCase: Bool) -> ConvertOutcome {
        guard !pattern.isEmpty else { return .success("") }
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return .failure(L10n.t("正则表达式无效：请检查括号、量词与转义"))
        }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return .success(L10n.t("没有匹配")) }

        var lines: [String] = [L10n.format("共 %d 个匹配", matches.count)]
        for (index, match) in matches.enumerated() {
            let hit = match.range.location == NSNotFound ? "" : nsText.substring(with: match.range)
            lines.append("\(index + 1). [\(match.range.location), \(match.range.length)] \(hit)")
            for group in 1..<match.numberOfRanges {
                let range = match.range(at: group)
                let value = range.location == NSNotFound ? L10n.t("<未参与匹配>") : nsText.substring(with: range)
                lines.append("   $\(group): \(value)")
            }
        }
        return .success(lines.joined(separator: "\n"))
    }
}

/// 列编号：按行加序号前缀，保留各行原有行尾；可选补零与从 0 开始
enum ColumnNumberer {
    static func apply(to text: String, startAtZero: Bool, padZeros: Bool) -> ConvertOutcome {
        guard !text.isEmpty else { return .success("") }
        let lines = splitPreservingLineEndings(text)
        guard !lines.isEmpty else { return .success("") }
        let start = startAtZero ? 0 : 1
        let last = start + lines.count - 1
        let width = String(last).count
        var result = ""
        for (offset, line) in lines.enumerated() {
            let number = start + offset
            let label = padZeros ? String(format: "%0\(width)d", number) : String(number)
            result += label + "  " + line + "\n"
        }
        // 最后一行原本没有换行时，去掉补出来的那一个
        if !text.hasSuffix("\n"), !text.hasSuffix("\r") {
            result.removeLast()
        }
        return .success(result)
    }

    /// 每行连同行尾一起切分：不统一行尾，避免把 LF / CRLF 混用文档改成另一种
    private static func splitPreservingLineEndings(_ text: String) -> [String] {
        var lines: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex { $0 == "\n" || $0 == "\r" } ?? text.endIndex
            var next = lineEnd
            if lineEnd < text.endIndex {
                if text[lineEnd] == "\r", text.index(after: lineEnd) < text.endIndex,
                   text[text.index(after: lineEnd)] == "\n" {
                    next = text.index(lineEnd, offsetBy: 2)
                } else {
                    next = text.index(after: lineEnd)
                }
            }
            lines.append(String(text[cursor..<next]))
            cursor = next
        }
        return lines
    }
}

/// XML 格式化 / 压缩：走系统 XMLDocument，保留结构与属性，不引入第三方依赖
enum XMLFormatter {
    static func pretty(_ text: String) -> ConvertOutcome {
        convert(text, options: [.nodePrettyPrint])
    }

    static func compact(_ text: String) -> ConvertOutcome {
        convert(text, options: [])
    }

    private static func convert(_ text: String, options: XMLNode.Options) -> ConvertOutcome {
        guard !text.isEmpty else { return .success("") }
        guard let data = text.data(using: .utf8) else {
            return .failure(L10n.t("正文无法按 UTF-8 编码为字节"))
        }
        do {
            let document = try XMLDocument(data: data,
                                           options: [.nodeLoadExternalEntitiesNever])
            let output = document.xmlData(options: options)
            guard let string = String(data: output, encoding: .utf8) else {
                return .failure(L10n.t("格式化结果无法按 UTF-8 读出"))
            }
            return .success(string)
        } catch {
            return .failure(L10n.format("XML 解析失败：%@", error.localizedDescription))
        }
    }
}

/// SQL 格式化：只做保守的排版——引号与注释内部原样保留，
/// 关键词改大写，主要子句前换行；不改变标识符大小写、不重排条件顺序
enum SQLFormatter {
    private static let keywords: Set<String> = [
        "select", "from", "where", "group", "order", "by", "having", "limit",
        "offset", "union", "all", "insert", "into", "values", "update", "set",
        "delete", "join", "left", "right", "inner", "outer", "on", "and", "or",
        "not", "as", "distinct", "case", "when", "then", "else", "end", "asc",
        "desc", "create", "table", "alter", "drop", "index", "primary", "key",
        "foreign", "references", "default", "null", "is", "in", "like", "between",
        "exists", "count", "sum", "avg", "min", "max"
    ]

    private static let lineBreaking: Set<String> = [
        "select", "from", "where", "group", "order", "having", "limit", "offset",
        "union", "insert", "update", "delete", "values", "set", "join", "left",
        "right", "inner", "outer", "on", "create", "alter", "drop"
    ]

    static func pretty(_ text: String) -> ConvertOutcome {
        guard !text.isEmpty else { return .success("") }
        var output = ""
        var word = ""
        var quote: Character?
        var inLineComment = false
        var inBlockComment = false
        var pendingSpace = false
        let characters = Array(text)
        var index = 0

        func appendWord() {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            if pendingSpace, !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix(" ") {
                output += " "
            }
            pendingSpace = false
            if keywords.contains(lower) {
                if lineBreaking.contains(lower), !output.isEmpty, !output.hasSuffix("\n") {
                    output += "\n"
                }
                output += word.uppercased()
            } else {
                output += word
            }
            word = ""
        }

        while index < characters.count {
            let character = characters[index]
            if inLineComment {
                output.append(character)
                if character == "\n" { inLineComment = false }
                index += 1
                continue
            }
            if inBlockComment {
                output.append(character)
                if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    output.append("/")
                    inBlockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if let currentQuote = quote {
                output.append(character)
                if character == currentQuote {
                    if index + 1 < characters.count, characters[index + 1] == currentQuote {
                        output.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    quote = nil
                }
                index += 1
                continue
            }
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                appendWord()
                output += "--"
                inLineComment = true
                index += 2
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                appendWord()
                output += "/*"
                inBlockComment = true
                index += 2
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
                appendWord()
                quote = character
                output.append(character)
                index += 1
                continue
            }
            if character.isLetter || character.isNumber || character == "_" || character == "." {
                word.append(character)
                index += 1
                continue
            }
            appendWord()
            switch character {
            case " ", "\t", "\r", "\n":
                pendingSpace = true
            case ",":
                output += ","
                pendingSpace = true
            case ";":
                output += ";"
                if !output.hasSuffix("\n") { output += "\n" }
                pendingSpace = false
            default:
                if pendingSpace, !output.isEmpty, !output.hasSuffix("\n") { output += " " }
                pendingSpace = false
                output.append(character)
            }
            index += 1
        }
        appendWord()
        // 收尾只留一个换行，避免多次格式化不断增多空行
        while output.hasSuffix(" ") || output.hasSuffix("\n") || output.hasSuffix("\t") {
            output.removeLast()
        }
        return .success(output)
    }

    static func compact(_ text: String) -> ConvertOutcome {
        guard !text.isEmpty else { return .success("") }
        var output = ""
        var quote: Character?
        var pendingSpace = false
        var inLineComment = false
        var inBlockComment = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inLineComment {
                if character == "\n" { inLineComment = false; pendingSpace = true }
                index += 1
                continue
            }
            if inBlockComment {
                if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    inBlockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if let currentQuote = quote {
                output.append(character)
                if character == currentQuote {
                    if index + 1 < characters.count, characters[index + 1] == currentQuote {
                        output.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    quote = nil
                }
                index += 1
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
                quote = character
                output.append(character)
                pendingSpace = false
                index += 1
                continue
            }
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                inLineComment = true
                index += 2
                pendingSpace = true
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                inBlockComment = true
                index += 2
                continue
            }
            if character.isWhitespace {
                pendingSpace = true
                index += 1
                continue
            }
            if pendingSpace, !output.isEmpty { output.append(" ") }
            pendingSpace = false
            output.append(character)
            index += 1
        }
        return .success(output)
    }
}
