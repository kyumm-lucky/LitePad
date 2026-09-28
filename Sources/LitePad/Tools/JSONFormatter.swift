import Foundation

/// JSON 缩进档位（JSON 格式化工具）
enum JSONIndent: String, CaseIterable, Identifiable {
    case twoSpaces
    case fourSpaces

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoSpaces: return "2 空格"
        case .fourSpaces: return "4 空格"
        }
    }

    /// 每层缩进写入的空白
    var unit: String {
        switch self {
        case .twoSpaces: return "  "
        case .fourSpaces: return "    "
        }
    }
}

/// JSON 格式化 / 压缩：按记号重排原文，不改写字符串内容、数字写法与转义原文，
/// 因此键顺序、`1.0`、`1e5`、超出双精度的大整数都原样保留（交给 JSONSerialization
/// 会丢键顺序并把这些写法归一化）；语法错误按「第 N 行第 M 列」给出中文原因
enum JSONFormatter {
    /// 格式化：按缩进档位换行对齐；空对象 / 空数组仍写作 `{}` / `[]`
    static func pretty(_ text: String, indent: JSONIndent) -> ConvertOutcome {
        var rewriter = JSONRewriter(text: text, indentUnit: indent.unit)
        return rewriter.run()
    }

    /// 压缩：去掉结构之间的空白，其余原样
    static func minify(_ text: String) -> ConvertOutcome {
        var rewriter = JSONRewriter(text: text, indentUnit: nil)
        return rewriter.run()
    }
}

/// JSON 用到的 ASCII 记号，避免在扫描逻辑里散布裸字节
private enum JSONMark {
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/")
    static let comma = UInt8(ascii: ",")
    static let colon = UInt8(ascii: ":")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let minus = UInt8(ascii: "-")
    static let plus = UInt8(ascii: "+")
    static let dot = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let singleQuote = UInt8(ascii: "'")
    static let lowerE = UInt8(ascii: "e")
    static let upperE = UInt8(ascii: "E")
    static let lowerU = UInt8(ascii: "u")
    static let lowerB = UInt8(ascii: "b")
    static let lowerF = UInt8(ascii: "f")
    static let lowerN = UInt8(ascii: "n")
    static let lowerR = UInt8(ascii: "r")
    static let lowerT = UInt8(ascii: "t")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
}

/// 逐字节扫描 JSON 并重排输出：同一遍扫描同时完成语法校验，出错即停并给出位置。
/// 结构字符都是 ASCII，多字节字符只出现在字符串里且原样搬运，因此按字节扫描是安全的
private struct JSONRewriter {
    private let bytes: [UInt8]
    /// 缩进单元；nil 表示压缩（结构之间不插入空白）
    private let indentUnit: [UInt8]?

    private var index = 0
    private var line = 1
    private var column = 1
    private var output: [UInt8] = []

    init(text: String, indentUnit: String?) {
        bytes = Array(text.utf8)
        self.indentUnit = indentUnit.map { Array($0.utf8) }
    }

    /// 待收尾的容器：记住起点（报「没有闭合」时指回起点）与是否已有元素（空容器不换行）
    private struct Frame {
        let isObject: Bool
        let openLine: Int
        let openColumn: Int
        var hasElement = false
    }

    /// 当前位置期望的记号
    private enum Expect {
        case key        // 对象里：键，或空对象的 `}`
        case colon      // 键之后
        case value      // 值：根值、数组元素或对象成员的值
        case separator  // 值之后：逗号或闭合符
    }

    private struct SyntaxError: Error {
        let message: String
        /// 报错位置；缺省用当前位置（字符串未闭合、容器未收尾时报起点位置）
        var line: Int?
        var column: Int?
    }

    mutating func run() -> ConvertOutcome {
        do {
            try rewrite()
        } catch let error as SyntaxError {
            let atLine = error.line ?? line
            let atColumn = error.column ?? column
            return .failure("第 \(atLine) 行第 \(atColumn) 列：\(error.message)")
        } catch {
            return .failure("JSON 处理失败")
        }
        return .success(String(decoding: output, as: UTF8.self))
    }

    private mutating func rewrite() throws {
        skipWhitespace()
        // 空输入或只有空白：没有内容可处理，也不该报语法错
        guard index < bytes.count else { return }
        output.reserveCapacity(bytes.count)

        var frames: [Frame] = []
        var expect: Expect = .value
        /// 上一个记号是否为逗号：区分「刚开容器」与「逗号之后」，尾随逗号只可能出现在后者
        var afterComma = false

        while true {
            skipWhitespace()
            guard index < bytes.count else { break }
            let byte = bytes[index]

            if byte == JSONMark.slash {
                throw SyntaxError(message: "JSON 不支持注释")
            }

            switch expect {
            case .separator:
                guard !frames.isEmpty else {
                    throw SyntaxError(message: "JSON 值之后还有多余内容，实际是\(quote(byte))")
                }
                if byte == JSONMark.comma {
                    advance()
                    expect = frames[frames.count - 1].isObject ? .key : .value
                    afterComma = true
                    continue
                }
                guard isCloser(byte) else {
                    throw SyntaxError(message: "值之后需要逗号或闭合符，实际是\(quote(byte))")
                }
                try readCloser(byte, frames: &frames, expect: &expect, afterComma: afterComma)

            case .key:
                if isCloser(byte) {
                    try readCloser(byte, frames: &frames, expect: &expect, afterComma: afterComma)
                    continue
                }
                guard byte == JSONMark.quote else {
                    throw SyntaxError(message: "对象的键必须是双引号字符串，实际是\(quote(byte))")
                }
                beginElement(in: &frames)
                output.append(contentsOf: try readString())
                expect = .colon
                afterComma = false

            case .colon:
                guard byte == JSONMark.colon else {
                    throw SyntaxError(message: "键与值之间需要冒号，实际是\(quote(byte))")
                }
                advance()
                output.append(JSONMark.colon)
                if indentUnit != nil {
                    output.append(JSONMark.space)
                }
                expect = .value
                afterComma = false

            case .value:
                // 数组元素位（含刚开的数组）：闭合符只在空数组时合法
                if isCloser(byte), frames.last?.isObject == false {
                    try readCloser(byte, frames: &frames, expect: &expect, afterComma: afterComma)
                    continue
                }
                // 对象成员的值紧跟在键后面同行写出，不另起一个元素
                if frames.last?.isObject != true {
                    beginElement(in: &frames)
                }
                expect = try readValue(into: &frames)
                afterComma = false
            }
        }

        if let frame = frames.last {
            let kind = frame.isObject ? "对象" : "数组"
            let closer = frame.isObject ? "}" : "]"
            throw SyntaxError(message: "\(kind)没有闭合，缺少 \(closer)",
                              line: frame.openLine, column: frame.openColumn)
        }
    }

    // MARK: - 记号

    /// 读一处值并写出，返回该值之后期望的记号：标量之后等逗号 / 闭合符，
    /// 容器压栈后继续填内容（对象等键，数组等元素）
    private mutating func readValue(into frames: inout [Frame]) throws -> Expect {
        let byte = bytes[index]
        switch byte {
        case JSONMark.quote:
            output.append(contentsOf: try readString())
            return .separator
        case JSONMark.openBrace, JSONMark.openBracket:
            let openLine = line
            let openColumn = column
            output.append(byte)
            advance()
            frames.append(Frame(isObject: byte == JSONMark.openBrace,
                                openLine: openLine, openColumn: openColumn))
            return byte == JSONMark.openBrace ? .key : .value
        case JSONMark.minus, JSONMark.zero...JSONMark.nine:
            output.append(contentsOf: try readNumber())
            return .separator
        case JSONMark.singleQuote:
            throw SyntaxError(message: "JSON 的字符串必须用双引号，不能用单引号")
        case let other where isLetter(other):
            try readLiteral()
            return .separator
        default:
            throw SyntaxError(message: "需要一个 JSON 值，实际是\(quote(byte))")
        }
    }

    /// 读一处文字量：只接受 true / false / null
    private mutating func readLiteral() throws {
        for literal in ["true", "false", "null"] {
            let token = Array(literal.utf8)
            guard bytes[index...].starts(with: token) else { continue }
            output.append(contentsOf: token)
            for _ in token { advance() }
            return
        }
        throw SyntaxError(message: "JSON 只接受 true / false / null，实际是“\(readWord())”")
    }

    /// 读一处双引号字符串（含转义），原样返回
    private mutating func readString() throws -> ArraySlice<UInt8> {
        let start = index
        let startLine = line
        let startColumn = column
        advance()  // 开引号
        while true {
            guard index < bytes.count else {
                throw SyntaxError(message: "字符串没有闭合", line: startLine, column: startColumn)
            }
            let byte = bytes[index]
            if byte == JSONMark.quote {
                advance()
                return bytes[start..<index]
            }
            if byte == JSONMark.backslash {
                advance()
                try readEscape(startLine: startLine, startColumn: startColumn)
                continue
            }
            // JSON 规定字符串里的控制字符（raw 换行、制表符等）必须转义
            if byte < 0x20 {
                throw SyntaxError(message: "字符串里不能直接出现控制字符，请写成 \\n \\t \\uXXXX 等转义")
            }
            advance()
        }
    }

    /// 读一处转义（反斜杠已消费）
    private mutating func readEscape(startLine: Int, startColumn: Int) throws {
        guard index < bytes.count else {
            throw SyntaxError(message: "字符串没有闭合", line: startLine, column: startColumn)
        }
        switch bytes[index] {
        case JSONMark.quote, JSONMark.backslash, JSONMark.slash,
             JSONMark.lowerB, JSONMark.lowerF, JSONMark.lowerN, JSONMark.lowerR, JSONMark.lowerT:
            advance()
        case JSONMark.lowerU:
            advance()
            for _ in 0..<4 {
                guard index < bytes.count, isHexDigit(bytes[index]) else {
                    throw SyntaxError(message: "\\u 转义需要 4 位十六进制数字")
                }
                advance()
            }
        default:
            throw SyntaxError(message: "无法识别的转义：\\\(describe(bytes[index]))")
        }
    }

    /// 读一处数字：严格按规范（不接受前导零、`+`、`.5`、`1.`、`1e` 等写法），原文原样写出
    private mutating func readNumber() throws -> ArraySlice<UInt8> {
        let start = index
        let startLine = line
        let startColumn = column

        if bytes[index] == JSONMark.minus {
            advance()
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw SyntaxError(message: "负号之后需要数字", line: startLine, column: startColumn)
            }
        }
        if bytes[index] == JSONMark.zero {
            advance()
            guard index >= bytes.count || !isDigit(bytes[index]) else {
                throw SyntaxError(message: "数字不能有前导零", line: startLine, column: startColumn)
            }
        } else {
            while index < bytes.count, isDigit(bytes[index]) { advance() }
        }

        if index < bytes.count, bytes[index] == JSONMark.dot {
            advance()
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw SyntaxError(message: "小数点后需要数字", line: startLine, column: startColumn)
            }
            while index < bytes.count, isDigit(bytes[index]) { advance() }
        }

        if index < bytes.count, bytes[index] == JSONMark.lowerE || bytes[index] == JSONMark.upperE {
            advance()
            if index < bytes.count, bytes[index] == JSONMark.plus || bytes[index] == JSONMark.minus {
                advance()
            }
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw SyntaxError(message: "指数部分需要数字", line: startLine, column: startColumn)
            }
            while index < bytes.count, isDigit(bytes[index]) { advance() }
        }

        // 数字后面紧跟字母或小数点（`1a`、`1e5.5`）当场报错，不留到「值之后」才报
        if index < bytes.count, isLetter(bytes[index]) || bytes[index] == JSONMark.dot {
            throw SyntaxError(message: "数字后面不能紧跟\(quote(bytes[index]))",
                              line: startLine, column: startColumn)
        }
        return bytes[start..<index]
    }

    /// 收一处闭合符：类型要对得上，且不能出现在逗号之后
    private mutating func readCloser(_ byte: UInt8,
                                     frames: inout [Frame],
                                     expect: inout Expect,
                                     afterComma: Bool) throws {
        guard let frame = frames.last else {
            throw SyntaxError(message: "意外出现\(quote(byte))，前面没有可闭合的容器")
        }
        guard byte == (frame.isObject ? JSONMark.closeBrace : JSONMark.closeBracket) else {
            let kind = frame.isObject ? "对象" : "数组"
            let closer = frame.isObject ? "}" : "]"
            throw SyntaxError(message: "这里是\(kind)，需要用 \(closer) 收尾，实际是\(quote(byte))")
        }
        guard !afterComma else {
            throw SyntaxError(message: "末尾多了一个逗号，JSON 不允许尾随逗号")
        }
        frames.removeLast()
        // 非空容器先换行缩回父层；空容器（`{}` / `[]`）就地收尾
        if let indentUnit, frame.hasElement {
            output.append(JSONMark.newline)
            for _ in 0..<frames.count {
                output.append(contentsOf: indentUnit)
            }
        }
        output.append(byte)
        advance()
        expect = .separator
    }

    /// 开始一个元素：压缩模式只补逗号，格式化模式再换行缩进到当前层
    private mutating func beginElement(in frames: inout [Frame]) {
        guard let last = frames.indices.last else { return }
        if frames[last].hasElement {
            output.append(JSONMark.comma)
        }
        if let indentUnit {
            output.append(JSONMark.newline)
            for _ in 0..<frames.count {
                output.append(contentsOf: indentUnit)
            }
        }
        frames[last].hasElement = true
    }

    // MARK: - 扫描位置

    /// 跳过结构之间的空白；UTF-8 BOM 只在文首出现，一并跳过（不计入列号）
    private mutating func skipWhitespace() {
        if index == 0, bytes.starts(with: JSONMark.bom) {
            index = JSONMark.bom.count
        }
        while index < bytes.count, isWhitespace(bytes[index]) {
            advance()
        }
    }

    /// 前进一个字节并维护行列；多字节字符的后续字节不单独占一列，列号按字符计
    private mutating func advance() {
        let byte = bytes[index]
        index += 1
        if byte == JSONMark.newline {
            line += 1
            column = 1
        } else if byte & 0xC0 != 0x80 {
            column += 1
        }
    }

    /// 把出错处的字符描述成可读文本：换行 / 控制字符给名称，其余给字符本身
    private func describe(_ byte: UInt8) -> String {
        switch byte {
        case JSONMark.newline: return "换行"
        case JSONMark.carriageReturn: return "回车"
        case 0x00...0x1F, 0x7F: return "控制字符"
        case 0x20...0x7E: return String(UnicodeScalar(byte))
        default:
            // 多字节字符：从当前字节起取足够长度解码，只留第一个字符
            let text = String(decoding: bytes[index...].prefix(4), as: UTF8.self)
            return String(text.prefix(1))
        }
    }

    private func quote(_ byte: UInt8) -> String { "“\(describe(byte))”" }

    /// 读取当前位置起的一段字母数字，用于回显 `NaN`、`undefined` 这类非法文字量
    private func readWord() -> String {
        var end = index
        while end < bytes.count, isLetter(bytes[end]) || isDigit(bytes[end]) { end += 1 }
        return String(decoding: bytes[index..<end], as: UTF8.self)
    }

    private func isCloser(_ byte: UInt8) -> Bool {
        byte == JSONMark.closeBrace || byte == JSONMark.closeBracket
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == JSONMark.space || byte == JSONMark.tab
            || byte == JSONMark.newline || byte == JSONMark.carriageReturn
    }

    private func isDigit(_ byte: UInt8) -> Bool { (JSONMark.zero...JSONMark.nine).contains(byte) }

    private func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
