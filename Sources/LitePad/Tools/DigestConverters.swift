import Foundation
import CryptoKit

/// 哈希算法档位（哈希计算工具，R23）
enum HashAlgorithm: String, CaseIterable, Identifiable {
    case md5
    case sha1
    case sha256
    case sha512

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        }
    }
}

/// 哈希摘要：按正文的 UTF-8 字节计算，输出十六进制。
/// 用系统框架（CryptoKit）计算，不引第三方依赖（SC4）
enum HashDigest {
    /// 计算摘要：默认小写，与 `md5` / `shasum` / `openssl dgst` 的输出口径一致
    static func hex(_ text: String, algorithm: HashAlgorithm, uppercase: Bool) -> String {
        let digest = digestBytes(Data(text.utf8), algorithm: algorithm)
        // 逐字节查表拼十六进制：摘要长度固定，逐字节 String(format:) 会为 SHA-512 造 64 个临时字符串
        var hex = ""
        hex.reserveCapacity(digest.count * 2)
        for byte in digest {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return uppercase ? hex.uppercased() : hex
    }

    private static let hexDigits = Array("0123456789abcdef")

    private static func digestBytes(_ data: Data, algorithm: HashAlgorithm) -> [UInt8] {
        switch algorithm {
        case .md5: return Array(Insecure.MD5.hash(data: data))
        case .sha1: return Array(Insecure.SHA1.hash(data: data))
        case .sha256: return Array(SHA256.hash(data: data))
        case .sha512: return Array(SHA512.hash(data: data))
        }
    }
}

/// UUID 生成（R24）：用 Foundation 的标识类型，输出 8-4-4-4-12 的标准写法
enum UUIDGenerator {
    /// 排版输出：默认小写（代码与 URL 里的常见写法），大写便于贴进 SQL 一类场景
    static func format(_ value: UUID, uppercase: Bool) -> String {
        uppercase ? value.uuidString : value.uuidString.lowercased()
    }
}

/// 时间戳单位档位（时间戳互转工具，R25）
enum TimestampUnit: String, CaseIterable, Identifiable {
    case seconds
    case milliseconds

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .seconds: return "Unix 秒"
        case .milliseconds: return "Unix 毫秒"
        }
    }
}

/// 时间戳互转（R25）：Unix 秒 / 毫秒 ⇄ 本地时间字符串。
///
/// 时间戳 → 时间：输出本地时区的 `yyyy-MM-dd HH:mm:ss`，毫秒位非零时补 `.SSS`，
/// 因此秒与毫秒两档都能原样往返（秒档的输出里不出现小数位）。
///
/// 时间 → 时间戳：识别本地时区的 `yyyy-MM-dd HH:mm:ss[.SSS]`、`yyyy/MM/dd HH:mm:ss`、
/// 不带时区标记的 `yyyy-MM-ddTHH:mm:ss[.SSS]`（按本地时间解释），
/// 以及带时区标记的 ISO 8601（`2024-01-02T03:04:05Z`、`+08:00` 这类）。
/// 整串必须被完整识别，长文本里只认出开头一段时按解析失败处理（不静默丢掉后半段）
enum TimestampConverter {

    /// 时间戳 → 本地时间字符串
    static func toLocalTime(_ text: String, unit: TimestampUnit) -> ConvertOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("请输入 Unix 时间戳（如 \(sample(unit))）")
        }
        // 小数点与逗号都接受（部分地区用逗号分隔小数）；十六进制、科学计数法这类写法不接受
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard isTimestampText(normalized), let value = Double(normalized) else {
            return .failure("不是有效的时间戳：请输入数字（如 \(sample(unit))）")
        }
        let milliseconds = unit == .seconds ? (value * 1000).rounded() : value.rounded()
        guard milliseconds >= minMilliseconds, milliseconds < maxMilliseconds,
              let whole = Int64(exactly: milliseconds) else {
            return .failure("时间戳超出可表示的日期范围（0001 - 9999 年）")
        }
        return .success(string(fromMilliseconds: whole))
    }

    /// 本地时间字符串 → 时间戳
    static func toTimestamp(_ text: String, unit: TimestampUnit) -> ConvertOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("请输入本地时间（如 \(sampleLocalTime)）")
        }
        guard let date = date(from: trimmed) else {
            return .failure("不是有效的本地时间：可用 \(sampleLocalTime)、2024/01/02 03:04:05 或 2024-01-02T03:04:05Z 这类写法")
        }
        // 与反向路径同一口径的护栏：极端日期换算成毫秒后可能超出 Int64 的可表示范围，
        // 直接构造会 trap（整个进程崩掉）；这里按「超出可表示的日期范围」拒绝
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard milliseconds >= minMilliseconds, milliseconds < maxMilliseconds,
              let whole = Int64(exactly: milliseconds) else {
            return .failure("时间超出可表示的日期范围（0001 - 9999 年）")
        }
        return .success(timestampText(milliseconds: whole, unit: unit))
    }

    /// 「现在」：asTimestamp 为真时给时间戳（按档位），为假时给本地时间字符串。
    /// 取整秒——毫秒位对一次转换没有意义，输入栏也保持干净
    static func now(unit: TimestampUnit, asTimestamp: Bool) -> String {
        let milliseconds = Int64(Date().timeIntervalSince1970) * 1000
        return asTimestamp
            ? timestampText(milliseconds: milliseconds, unit: unit)
            : string(fromMilliseconds: milliseconds)
    }

    /// 输入示例，写进失败原因里便于照着填
    static func sample(_ unit: TimestampUnit) -> String {
        unit == .seconds ? "1700000000" : "1700000000000"
    }

    static let sampleLocalTime = "2024-01-02 03:04:05"

    // MARK: - 时间戳 → 文本

    /// 时间戳写法：可选正负号 + 数字，最多一个小数点。只认这一种形状，
    /// 不让 `0x10`、`1e5` 这类写法混进来（Double 的宽松解析会收下它们）
    private static func isTimestampText(_ text: String) -> Bool {
        var digits = 0
        var dots = 0
        for (index, scalar) in text.unicodeScalars.enumerated() {
            switch scalar {
            case "0"..."9":
                digits += 1
            case ".", ",":
                dots += 1
                guard dots == 1, digits > 0 else { return false }
            case "+", "-":
                guard index == 0 else { return false }
            default:
                return false
            }
        }
        return digits > 0
    }

    /// 毫秒值 → 本地时间字符串：毫秒位为零时不写小数，保证秒档输入输出能原样往返
    private static func string(fromMilliseconds milliseconds: Int64) -> String {
        let seconds = secondsPart(of: milliseconds)
        let text = formatter(for: localPattern).string(from: Date(timeIntervalSince1970: Double(seconds)))
        let fraction = milliseconds - seconds * 1000
        guard fraction != 0 else { return text }
        return text + String(format: ".%03lld", fraction)
    }

    /// 按档位把毫秒值写成时间戳文本
    private static func timestampText(milliseconds: Int64, unit: TimestampUnit) -> String {
        unit == .seconds ? String(secondsPart(of: milliseconds)) : String(milliseconds)
    }

    /// 毫秒值取整秒：向负无穷取整，与毫秒位的取值口径一致（负时间戳也不会出现 0.999 秒的错位）
    private static func secondsPart(of milliseconds: Int64) -> Int64 {
        let remainder = milliseconds % 1000
        return remainder < 0 ? (milliseconds - remainder) / 1000 - 1 : milliseconds / 1000
    }

    // MARK: - 文本 → 时间戳

    /// 解析本地时间：先按带时区标记的 ISO 8601，再按本地时区格式；
    /// 两条路径都要求整串被完整吃掉，否则算失败——长文本里只有开头一段像时间时不能当成功
    private static func date(from text: String) -> Date? {
        // ISO 8601：先用形状整串匹配，再交给 ISO 格式化器解析。它不报「还剩多少没解析」，
        // 回写又按自己的时区输出（输入带 +08:00 时回写会变成 Z），不能拿回写串做比较
        if let isoRegex {
            let range = NSRange(location: 0, length: (text as NSString).length)
            if isoRegex.firstMatch(in: text, range: range)?.range == range, let date = isoDate(from: text) {
                return date
            }
        }
        // 本地时区格式：解析后再按同一格式回写，长度一致才算整串吃下
        //（没补零的写法与带尾巴的串都会在这里被挡掉）
        for pattern in localPatterns {
            let formatter = formatter(for: pattern)
            if let date = formatter.date(from: text), formatter.string(from: date).count == text.count {
                return date
            }
        }
        return nil
    }

    private static func isoDate(from text: String) -> Date? {
        for isoFormatter in isoFormatters {
            if let date = isoFormatter.date(from: text) { return date }
        }
        return nil
    }

    /// ISO 8601 的形状（整串匹配）：`2024-01-02T03:04:05[.123][Z|±HH:MM]`。
    /// 不带时区标记的写法不在这里（按本地时间解释，见 localPatterns）
    private static let isoRegex = try? NSRegularExpression(
        pattern: "^\\d{4}-\\d{2}-\\d{2}[Tt]\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,9})?([Zz]|[+-]\\d{2}:\\d{2})$")

    /// 输出格式（本地时区，秒级；毫秒位另补）
    private static let localPattern = "yyyy-MM-dd HH:mm:ss"

    /// 解析用的本地时区格式：带毫秒的写在前面（否则小数位会被当成尾巴丢掉）
    private static let localPatterns = [
        localPattern + ".SSS",
        localPattern,
        "yyyy/MM/dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
    ]

    /// 可表示的日期范围（对应本地时间 0001-01-01 到 9999-12-31），单位毫秒
    private static let minMilliseconds: Double = -62_135_596_800_000
    private static let maxMilliseconds: Double = 253_402_300_800_000

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    /// 复用同一个格式化器，但每次取用前同步时区：应用运行期间系统时区被改过时，结果不留旧时区
    private static let sharedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        return formatter
    }()

    private static func formatter(for pattern: String) -> DateFormatter {
        sharedFormatter.timeZone = .current
        sharedFormatter.dateFormat = pattern
        return sharedFormatter
    }
}

/// HTML 实体编解码（R26）
enum HTMLEntityCodec {
    /// 默认转义的字符：HTML 里有特殊含义的五个，外加不换行空格
    /// （不换行空格与普通空格肉眼无差，不转义的话来回一趟就找不回来了）
    private static let specialCharacters: [Character: String] = [
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        "\"": "&quot;",
        "'": "&#39;",
        "\u{00A0}": "&nbsp;",
    ]

    /// 编码：把有特殊含义的字符换成实体引用；escapeNonASCII 为真时连非 ASCII 字符
    /// 一起转成 `&#xXXXX;`，输出全为 ASCII 文本（默认中文等非 ASCII 字符原样保留）
    static func encode(_ text: String, escapeNonASCII: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if let entity = specialCharacters[Character(scalar)] {
                result += entity
            } else if escapeNonASCII, !scalar.isASCII {
                result += String(format: "&#x%X;", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// 解码：识别命名实体（表内的常见项）与 `&#123;` / `&#x1F600;` 数字实体；
    /// 认不出的（名字不在表内、缺分号、非法码点）整段按原文保留，不吞字符也不报错
    static func decode(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&", let entity = readEntity(scalars, at: index) else {
                result.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }
            result += entity.text
            index = entity.end
        }
        return result
    }

    /// 读取一处实体：返回替换文本与结束位置
    private static func readEntity(_ scalars: [Unicode.Scalar], at index: Int)
        -> (text: String, end: Int)? {
        // 数字实体：&#DDDD; / &#xHHHH;（十六进制大小写都认）
        if index + 3 < scalars.count, scalars[index + 1] == "#" {
            var position = index + 2
            var radix: UInt32 = 10
            if scalars[position] == "x" || scalars[position] == "X" {
                radix = 16
                position += 1
            }
            var value: UInt32 = 0
            var digits = 0
            // 最多收 7 位：超过码点上限的写法一律按无效处理（不会溢出）
            while position < scalars.count, digits < 7, let digit = digitValue(scalars[position], radix: radix) {
                value = value * radix + digit
                digits += 1
                position += 1
            }
            guard digits > 0, position < scalars.count, scalars[position] == ";",
                  let scalar = Unicode.Scalar(value) else { return nil }
            return (String(scalar), position + 1)
        }
        // 命名实体：&name;（区分大小写，与 HTML 一致）
        var position = index + 1
        var name = ""
        var length = 0
        while position < scalars.count, length < maxEntityNameLength, isNameScalar(scalars[position]) {
            name.unicodeScalars.append(scalars[position])
            length += 1
            position += 1
        }
        guard !name.isEmpty, position < scalars.count, scalars[position] == ";",
              let replacement = namedEntities[name] else { return nil }
        return (replacement, position + 1)
    }

    /// 命名实体的名字只由 ASCII 字母与数字组成，长度上限防住超长串的扫描
    private static let maxEntityNameLength = 32

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": return true
        default: return false
        }
    }

    private static func digitValue(_ scalar: Unicode.Scalar, radix: UInt32) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - 0x30
        case "a"..."f" where radix == 16: return scalar.value - 0x61 + 10
        case "A"..."F" where radix == 16: return scalar.value - 0x41 + 10
        default: return nil
        }
    }

    /// 表内收录的常见命名实体：符号 / 排版标点 / 箭头 / 数学运算符 / 希腊字母 / 常见重音拉丁字母。
    /// 未收录的名字按原文保留，不做部分替换
    private static let namedEntities: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}",
        "shy": "\u{00AD}",
        "iexcl": "\u{00A1}",
        "cent": "\u{00A2}",
        "pound": "\u{00A3}",
        "curren": "\u{00A4}",
        "yen": "\u{00A5}",
        "sect": "\u{00A7}",
        "copy": "\u{00A9}",
        "ordf": "\u{00AA}",
        "laquo": "\u{00AB}",
        "reg": "\u{00AE}",
        "deg": "\u{00B0}",
        "plusmn": "\u{00B1}",
        "sup2": "\u{00B2}",
        "sup3": "\u{00B3}",
        "micro": "\u{00B5}",
        "para": "\u{00B6}",
        "middot": "\u{00B7}",
        "ordm": "\u{00BA}",
        "raquo": "\u{00BB}",
        "frac14": "\u{00BC}",
        "frac12": "\u{00BD}",
        "frac34": "\u{00BE}",
        "iquest": "\u{00BF}",
        "times": "\u{00D7}",
        "divide": "\u{00F7}",
        "ndash": "\u{2013}",
        "mdash": "\u{2014}",
        "lsquo": "\u{2018}",
        "rsquo": "\u{2019}",
        "sbquo": "\u{201A}",
        "ldquo": "\u{201C}",
        "rdquo": "\u{201D}",
        "bdquo": "\u{201E}",
        "dagger": "\u{2020}",
        "Dagger": "\u{2021}",
        "bull": "\u{2022}",
        "hellip": "\u{2026}",
        "permil": "\u{2030}",
        "prime": "\u{2032}",
        "Prime": "\u{2033}",
        "euro": "\u{20AC}",
        "trade": "\u{2122}",
        "larr": "\u{2190}",
        "uarr": "\u{2191}",
        "rarr": "\u{2192}",
        "darr": "\u{2193}",
        "harr": "\u{2194}",
        "minus": "\u{2212}",
        "infin": "\u{221E}",
        "radic": "\u{221A}",
        "prod": "\u{220F}",
        "sum": "\u{2211}",
        "asymp": "\u{2248}",
        "ne": "\u{2260}",
        "le": "\u{2264}",
        "ge": "\u{2265}",
        "alpha": "\u{03B1}",
        "beta": "\u{03B2}",
        "gamma": "\u{03B3}",
        "delta": "\u{03B4}",
        "epsilon": "\u{03B5}",
        "zeta": "\u{03B6}",
        "eta": "\u{03B7}",
        "theta": "\u{03B8}",
        "lambda": "\u{03BB}",
        "mu": "\u{03BC}",
        "nu": "\u{03BD}",
        "xi": "\u{03BE}",
        "pi": "\u{03C0}",
        "rho": "\u{03C1}",
        "sigma": "\u{03C3}",
        "tau": "\u{03C4}",
        "phi": "\u{03C6}",
        "chi": "\u{03C7}",
        "psi": "\u{03C8}",
        "omega": "\u{03C9}",
        "Delta": "\u{0394}",
        "Sigma": "\u{03A3}",
        "Pi": "\u{03A0}",
        "Omega": "\u{03A9}",
        "agrave": "\u{00E0}",
        "aacute": "\u{00E1}",
        "auml": "\u{00E4}",
        "aring": "\u{00E5}",
        "ccedil": "\u{00E7}",
        "egrave": "\u{00E8}",
        "eacute": "\u{00E9}",
        "euml": "\u{00EB}",
        "iacute": "\u{00ED}",
        "ntilde": "\u{00F1}",
        "oacute": "\u{00F3}",
        "ouml": "\u{00F6}",
        "oslash": "\u{00F8}",
        "uacute": "\u{00FA}",
        "uuml": "\u{00FC}",
        "szlig": "\u{00DF}",
    ]
}
