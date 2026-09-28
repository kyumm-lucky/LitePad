import Foundation

/// 转换方向
enum ConvertDirection: String, CaseIterable, Identifiable {
    case encode
    case decode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .encode: return "编码"
        case .decode: return "解码"
        }
    }
}

/// 转换结果：成功取文本，失败取中文原因（此时文本为空）
enum ConvertOutcome {
    case success(String)
    case failure(String)

    var text: String {
        if case .success(let value) = self { return value }
        return ""
    }

    var errorMessage: String? {
        if case .failure(let message) = self { return message }
        return nil
    }
}

/// 码值基数（ASCII 码工具）
enum NumericBase: String, CaseIterable, Identifiable {
    case decimal
    case hexadecimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .decimal: return "十进制"
        case .hexadecimal: return "十六进制"
        }
    }

    var radix: UInt32 {
        switch self {
        case .decimal: return 10
        case .hexadecimal: return 16
        }
    }
}

/// Unicode 转义：非 ASCII 标量 ⇄ `\uXXXX`（非 BMP 字符输出 UTF-16 代理对）
enum UnicodeEscapeConverter {
    /// 编码：只转义非 ASCII；escapeASCII 为真时连 ASCII 一起转义，保证输出全为 ASCII 文本
    static func encode(_ text: String, escapeASCII: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count * 6)
        for scalar in text.unicodeScalars {
            if !escapeASCII, scalar.isASCII {
                result.unicodeScalars.append(scalar)
                continue
            }
            if scalar.value <= 0xFFFF {
                result += String(format: "\\u%04X", scalar.value)
            } else {
                let offset = scalar.value - 0x10000
                result += String(format: "\\u%04X\\u%04X",
                                 0xD800 + (offset >> 10),
                                 0xDC00 + (offset & 0x3FF))
            }
        }
        return result
    }

    /// 解码：识别 `\uXXXX`（含代理对合并）、`\u{XXXXX}`、`\xXX`、`\UXXXXXXXX`、`U+XXXX`；
    /// 无法识别的转义按原文保留，不吞字符
    static func decode(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            guard let escape = readEscape(scalars, at: index) else {
                result.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }
            // 高代理 + 低代理合并为一个非 BMP 标量
            if isHighSurrogate(escape.value),
               let low = readEscape(scalars, at: index + escape.length),
               isLowSurrogate(low.value),
               let scalar = Unicode.Scalar(0x10000
                   + ((escape.value - 0xD800) << 10)
                   + (low.value - 0xDC00)) {
                result.unicodeScalars.append(scalar)
                index += escape.length + low.length
                continue
            }
            if !isSurrogate(escape.value), let scalar = Unicode.Scalar(escape.value) {
                result.unicodeScalars.append(scalar)
                index += escape.length
                continue
            }
            // 孤立代理等非法码点：原样保留该段转义文本
            for position in index..<(index + escape.length) {
                result.unicodeScalars.append(scalars[position])
            }
            index += escape.length
        }
        return result
    }

    private static func isHighSurrogate(_ value: UInt32) -> Bool { (0xD800...0xDBFF).contains(value) }
    private static func isLowSurrogate(_ value: UInt32) -> Bool { (0xDC00...0xDFFF).contains(value) }
    private static func isSurrogate(_ value: UInt32) -> Bool { (0xD800...0xDFFF).contains(value) }

    /// 读取一处转义：返回码值与占用的标量个数
    private static func readEscape(_ scalars: [Unicode.Scalar], at index: Int)
        -> (value: UInt32, length: Int)? {
        let backslash: Unicode.Scalar = "\\"
        guard index < scalars.count else { return nil }

        if scalars[index] == backslash {
            guard index + 1 < scalars.count else { return nil }
            switch scalars[index + 1] {
            case "u":
                // \u{XXXXX}：花括号形式，1 - 6 位十六进制（长度补上 `\u{`）
                if index + 2 < scalars.count, scalars[index + 2] == "{" {
                    return readBracedHex(scalars, at: index + 3).map { ($0.value, $0.length + 3) }
                }
                // \uXXXX：固定 4 位
                guard let digits = readHex(scalars, at: index + 2, maxDigits: 4, exact: true) else { return nil }
                return (digits.value, digits.length + 2)
            case "U":
                // \UXXXXXXXX：Python 风格，1 - 8 位
                guard let digits = readHex(scalars, at: index + 2, maxDigits: 8, exact: false) else { return nil }
                return (digits.value, digits.length + 2)
            case "x":
                // \xXX：C 风格，1 - 2 位
                guard let digits = readHex(scalars, at: index + 2, maxDigits: 2, exact: false) else { return nil }
                return (digits.value, digits.length + 2)
            default:
                return nil
            }
        }

        // U+XXXX / u+XXXX：码点写法，1 - 6 位
        if scalars[index] == "U" || scalars[index] == "u" {
            guard index + 1 < scalars.count, scalars[index + 1] == "+",
                  let digits = readHex(scalars, at: index + 2, maxDigits: 6, exact: false) else { return nil }
            return (digits.value, digits.length + 2)
        }
        return nil
    }

    /// 读取 `{` 之后、`}` 之前的十六进制码点；返回长度为「十六进制位 + 结尾 `}`」，
    /// 前缀 `\u{` 的长度由调用方补足
    private static func readBracedHex(_ scalars: [Unicode.Scalar], at index: Int)
        -> (value: UInt32, length: Int)? {
        var value: UInt32 = 0
        var digits = 0
        var position = index
        while position < scalars.count, scalars[position] != "}", digits < 6 {
            guard let digit = hexDigit(scalars[position]) else { return nil }
            value = value << 4 | digit
            digits += 1
            position += 1
        }
        guard digits > 0, position < scalars.count, scalars[position] == "}" else { return nil }
        return (value, position - index + 1)
    }

    /// 连续读取十六进制数字；exact 为真时位数必须正好等于 maxDigits
    private static func readHex(_ scalars: [Unicode.Scalar], at index: Int,
                                maxDigits: Int, exact: Bool) -> (value: UInt32, length: Int)? {
        var value: UInt32 = 0
        var digits = 0
        var position = index
        while digits < maxDigits, position < scalars.count, let digit = hexDigit(scalars[position]) {
            value = value << 4 | digit
            digits += 1
            position += 1
        }
        guard digits > 0, !exact || digits == maxDigits else { return nil }
        return (value, digits)
    }

    private static func hexDigit(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - 0x30
        case "a"..."f": return scalar.value - 0x61 + 10
        case "A"..."F": return scalar.value - 0x41 + 10
        default: return nil
        }
    }
}

/// ASCII 码：字符 ⇄ 码值数字串（空格分隔，按 Unicode 码点，中文等非 ASCII 字符同样可往返）
enum ASCIICodeConverter {
    /// 编码：逐码点输出码值
    static func encode(_ text: String, base: NumericBase) -> String {
        text.unicodeScalars
            .map { format($0.value, base: base) }
            .joined(separator: " ")
    }

    /// 解码：按基数识别数字段转为码点；夹在数字段之间（或位于文首尾并紧邻数字段）的
    /// 分隔符（空白 / 逗号 / 分号）按分隔丢弃，其余字符原样保留；十六进制兼容 `0x` 前缀；
    /// 超出 Unicode 范围或落在代理区的数字段按原文保留
    static func decode(_ text: String, base: NumericBase) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var index = 0
        // 上一处输出是否为数字段：决定紧随其后的分隔符串算「分隔」还是「正文」
        var lastWasNumber = false
        while index < scalars.count {
            if let number = readNumber(scalars, at: index, base: base) {
                if let scalar = scalar(for: number.value) {
                    result.unicodeScalars.append(scalar)
                } else {
                    for kept in index..<number.end {
                        result.unicodeScalars.append(scalars[kept])
                    }
                }
                index = number.end
                lastWasNumber = true
                continue
            }
            if isSeparator(scalars[index]) {
                var end = index
                while end < scalars.count, isSeparator(scalars[end]) {
                    end += 1
                }
                if (lastWasNumber || index == 0), readNumber(scalars, at: end, base: base) != nil {
                    index = end
                    continue
                }
                for kept in index..<end {
                    result.unicodeScalars.append(scalars[kept])
                }
                index = end
                lastWasNumber = false
                continue
            }
            result.unicodeScalars.append(scalars[index])
            index += 1
            lastWasNumber = false
        }
        return result
    }

    /// 读取一处数字段：返回码值与结束位置；十六进制允许 `0x` / `0X` 前缀
    private static func readNumber(_ scalars: [Unicode.Scalar], at index: Int, base: NumericBase)
        -> (value: UInt64, end: Int)? {
        var position = index
        if base == .hexadecimal, index + 2 < scalars.count,
           scalars[index] == "0", scalars[index + 1] == "x" || scalars[index + 1] == "X",
           digitValue(scalars[index + 2], base: base) != nil {
            position = index + 2
        }
        var value: UInt64 = 0
        var digits = 0
        while position < scalars.count, let digit = digitValue(scalars[position], base: base) {
            value = min(value * UInt64(base.radix) + UInt64(digit), overlongValue)
            digits += 1
            position += 1
        }
        guard digits > 0 else { return nil }
        return (value, position)
    }

    /// 数值封顶值：超过码点上限即封顶，由 scalar(for:) 判定为非法并按原文保留
    private static let overlongValue: UInt64 = 0x110000

    private static func scalar(for value: UInt64) -> Unicode.Scalar? {
        guard value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { return nil }
        return Unicode.Scalar(UInt32(value))
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "," || scalar == ";" || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func format(_ value: UInt32, base: NumericBase) -> String {
        switch base {
        case .decimal: return String(value)
        case .hexadecimal: return String(value, radix: 16, uppercase: true)
        }
    }

    private static func digitValue(_ scalar: Unicode.Scalar, base: NumericBase) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - 0x30
        case "a"..."f" where base == .hexadecimal: return scalar.value - 0x61 + 10
        case "A"..."F" where base == .hexadecimal: return scalar.value - 0x41 + 10
        default: return nil
        }
    }
}

/// URL 百分号编码：UTF-8 字节 ⇄ `%XX`，未保留字符保持原样
enum URLPercentConverter {
    /// 编码：A-Z a-z 0-9 - . _ ~ 保持原样，其余按 UTF-8 字节转 %XX；
    /// spaceAsPlus 为真时空格输出 `+`（表单风格）
    static func encode(_ text: String, spaceAsPlus: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                result.unicodeScalars.append(Unicode.Scalar(byte))
            case 0x20 where spaceAsPlus:
                result.append("+")
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// 解码：`%XX` 还原为字节，其余字节原样保留，最后按 UTF-8 解释；
    /// `+` 不做空格还原（避免误改正文中的加号）
    static func decode(_ text: String) -> ConvertOutcome {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count,
               let high = hexDigit(bytes[index + 1]), let low = hexDigit(bytes[index + 2]) {
                result.append(high << 4 | low)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        guard let decoded = String(bytes: result, encoding: .utf8) else {
            return .failure("解码结果不是有效的 UTF-8 文本")
        }
        return .success(decoded)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x66: return byte - 0x61 + 10
        case 0x41...0x46: return byte - 0x41 + 10
        default: return nil
        }
    }
}

/// Base64：UTF-8 文本 ⇄ Base64 文本
enum Base64Converter {
    /// 编码：urlSafe 为真时用 `-` `_` 替换 `+` `/` 并去掉 `=`
    static func encode(_ text: String, urlSafe: Bool) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        guard urlSafe else { return encoded }
        return encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 解码：忽略空白与换行，兼容 URL 安全字符与缺失的 `=`；结果必须是 UTF-8 文本
    static func decode(_ text: String) -> ConvertOutcome {
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return .success("") }
        var normalized = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        // 长度 % 4 == 1 不是合法 Base64，补齐也无解
        guard remainder != 1 else { return .failure("不是有效的 Base64 文本") }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: normalized) else {
            return .failure("不是有效的 Base64 文本")
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            return .failure("解码结果不是有效的 UTF-8 文本")
        }
        return .success(decoded)
    }
}
