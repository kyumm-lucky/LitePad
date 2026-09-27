import Foundation

/// 状态栏可选的文件编码；切换后在保存时真实改变文件字节
enum TextEncoding: String, CaseIterable, Identifiable {
    case utf8
    case utf8BOM
    case utf16
    case utf16BE
    case utf16LE
    case utf32
    case utf32BE
    case utf32LE
    case gb18030

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8: return "Unicode (UTF-8)"
        case .utf8BOM: return "Unicode (UTF-8) with BOM"
        case .utf16: return "Unicode (UTF-16)"
        case .utf16BE: return "Unicode (UTF-16BE)"
        case .utf16LE: return "Unicode (UTF-16LE，无 BOM)"
        case .utf32: return "Unicode (UTF-32)"
        case .utf32BE: return "Unicode (UTF-32BE)"
        case .utf32LE: return "Unicode (UTF-32LE，无 BOM)"
        case .gb18030: return "简体中文 (GB18030)"
        }
    }

    /// GB18030 的 Foundation 编码常量
    static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// 对应的 Foundation 编码（供 IANA 名称反查与解码尝试复用）
    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16: return .utf16
        case .utf16BE: return .utf16BigEndian
        case .utf16LE: return .utf16LittleEndian
        case .utf32: return .utf32
        case .utf32BE: return .utf32BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .gb18030: return TextEncoding.gb18030Encoding
        }
    }

    /// 反查与指定 Foundation 编码对应的枚举项
    static func matching(_ encoding: String.Encoding) -> TextEncoding? {
        allCases.first { $0.stringEncoding == encoding }
    }

    /// 无 BOM 文本可参与优先级尝试的编码；BOM 变体由 BOM 探测固定处理
    private static let detectionCandidates: [TextEncoding] = [.utf8, .gb18030]
    /// 宽字符编码仅在字节确含 0x00 时才参与尝试（纯 ASCII 文本按宽字符解码只会得到乱码）
    private static let wideCandidates: [TextEncoding] = [.utf16LE, .utf16BE, .utf32LE, .utf32BE]

    /// 把文本编码为当前编码的字节。
    /// 「Unicode (UTF-16)/(UTF-32)」与 BE 变体带 BOM（BE 按惯例 BE 序 BOM），
    /// 保证 BOM 检测出的编码保存后字节往返一致；显式 LE 变体不带 BOM
    func encode(_ text: String) -> Data {
        switch self {
        case .utf8:
            return Data(text.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16:
            return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BE:
            return Data([0xFE, 0xFF]) + (text.data(using: .utf16BigEndian) ?? Data())
        case .utf16LE:
            return text.data(using: .utf16LittleEndian) ?? Data()
        case .utf32:
            return Data([0xFF, 0xFE, 0x00, 0x00]) + (text.data(using: .utf32LittleEndian) ?? Data())
        case .utf32BE:
            return Data([0x00, 0x00, 0xFE, 0xFF]) + (text.data(using: .utf32BigEndian) ?? Data())
        case .utf32LE:
            return text.data(using: .utf32LittleEndian) ?? Data()
        case .gb18030:
            return text.data(using: TextEncoding.gb18030Encoding) ?? Data()
        }
    }

    /// 解码文件数据并给出判定编码：优先按 BOM 识别（UTF-32LE 的 BOM 以 UTF-16LE 的 BOM 开头，须先判 UTF-32），
    /// BOM 检出映射到带 BOM 的编码变体以保证保存字节往返一致；无 BOM 时先做宽字符端序探测，
    /// 再按用户配置的优先级尝试解码（默认 UTF-8 → GB18030），最后按 UTF-8 容错解码。
    /// 「参考文稿中的编码声明」仅在常规探测全部失败后兜底使用，避免错误的声明污染可靠的探测结果
    static func decode(_ data: Data,
                       priority: [TextEncoding] = [.utf8, .gb18030],
                       respectCharsetDeclaration: Bool = false) -> (text: String, encoding: TextEncoding) {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return (decodeAfterBOM(data, bomLength: 4, encoding: .utf32BigEndian), .utf32BE)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return (decodeAfterBOM(data, bomLength: 4, encoding: .utf32LittleEndian), .utf32)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return (decodeAfterBOM(data, bomLength: 2, encoding: .utf16BigEndian), .utf16BE)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return (decodeAfterBOM(data, bomLength: 2, encoding: .utf16LittleEndian), .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (decodeAfterBOM(data, bomLength: 3, encoding: .utf8), .utf8BOM)
        }
        // 合法的普通 UTF-8 文本不含 0x00 字节；出现 0x00 时优先按无 BOM 的 UTF-16/32 探测
        if data.contains(0), let (text, encoding) = decodeEndianless(data) {
            return (text, encoding)
        }
        for candidate in priority {
            if TextEncoding.wideCandidates.contains(candidate) {
                guard data.contains(0) else { continue }
            } else if !TextEncoding.detectionCandidates.contains(candidate) {
                continue
            }
            if let text = String(data: data, encoding: candidate.stringEncoding), !text.contains("\u{0}") {
                return (text, candidate)
            }
        }
        if respectCharsetDeclaration, let declared = decodeWithDeclaredCharset(data) {
            return declared
        }
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    /// 从文稿头部的 HTML meta / CSS @charset 声明识别编码；仅采信应用内置编码表内的名称，
    /// 且解码结果不含 NUL 才可信。宽字符声明不参与：无 BOM 的 UTF-16 文件交由端序探测判定更可靠
    private static func decodeWithDeclaredCharset(_ data: Data) -> (text: String, encoding: TextEncoding)? {
        guard let regex = declarationRegex else { return nil }
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        let range = NSRange(head.startIndex..., in: head)
        guard let match = regex.firstMatch(in: head, options: [], range: range),
              let nameRange = Range(match.range(at: 1), in: head) else { return nil }
        let name = String(head[nameRange]).lowercased()
        // 常见中文声明别名归并到 GB18030（超集编码）
        let aliases = ["gb2312": TextEncoding.gb18030, "gbk": TextEncoding.gb18030]
        let declared = aliases[name]
            ?? ianaEncoding(name: name).flatMap { TextEncoding.matching($0) }
        guard let declared, !TextEncoding.wideCandidates.contains(declared), declared != .utf8BOM,
              let text = String(data: data, encoding: declared.stringEncoding),
              !text.contains("\u{0}") else { return nil }
        return (text, declared)
    }

    private static let declarationRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:@charset\s+"|charset\s*=\s*["']?)([\w\-]+)"#
    )

    /// IANA 编码名 → Foundation 编码
    private static func ianaEncoding(name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// 无 BOM 的 UTF-16/32 端序探测：按 0x00 字节在码元中的位置占多数的一侧判定端序，
    /// 且解码结果不含 NUL 字符才采信；纯 CJK 等无 0x00 特征的内容无法判定，交由后续分支兜底
    private static func decodeEndianless(_ data: Data) -> (text: String, encoding: TextEncoding)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        if bytes.count % 4 == 0 {
            let groups = bytes.count / 4
            // UTF-32LE 的 BMP 字符第 3、4 字节为 0x00；BE 则是第 1、2 字节
            let le32 = stride(from: 0, to: groups, by: 1).filter { bytes[$0 * 4 + 2] == 0 && bytes[$0 * 4 + 3] == 0 }.count
            let be32 = stride(from: 0, to: groups, by: 1).filter { bytes[$0 * 4] == 0 && bytes[$0 * 4 + 1] == 0 }.count
            if le32 > groups / 2, let text = String(data: data, encoding: .utf32LittleEndian), !text.contains("\u{0}") {
                return (text, .utf32LE)
            }
            if be32 > groups / 2, let text = String(data: data, encoding: .utf32BigEndian), !text.contains("\u{0}") {
                return (text, .utf32BE)
            }
        }

        guard bytes.count % 2 == 0 else { return nil }
        let pairs = bytes.count / 2
        // UTF-16LE 的 ASCII 区字符第 2 字节为 0x00；BE 则是第 1 字节
        let le16 = stride(from: 0, to: pairs, by: 1).filter { bytes[$0 * 2 + 1] == 0 }.count
        let be16 = stride(from: 0, to: pairs, by: 1).filter { bytes[$0 * 2] == 0 }.count
        if le16 > pairs / 2, let text = String(data: data, encoding: .utf16LittleEndian), !text.contains("\u{0}") {
            return (text, .utf16LE)
        }
        if be16 > pairs / 2, let text = String(data: data, encoding: .utf16BigEndian), !text.contains("\u{0}") {
            return (text, .utf16BE)
        }
        return nil
    }

    /// 去掉 BOM 字节后按指定编码解码；解码失败按 UTF-8 容错，保证文件总能打开
    private static func decodeAfterBOM(_ data: Data, bomLength: Int, encoding: String.Encoding) -> String {
        let payload = data.dropFirst(bomLength)
        return String(data: payload, encoding: encoding)
            ?? String(decoding: payload, as: UTF8.self)
    }
}

/// 状态栏可选的换行符
enum LineEnding: String, CaseIterable, Identifiable {
    case lf
    case crlf
    case cr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    var separator: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// 按主流换行符出现情况推断文档换行符
    static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") {
            return .crlf
        }
        if text.contains("\r") {
            return .cr
        }
        return .lf
    }

    /// 把文中所有换行（\r\n、\r、\n）统一替换为当前换行符
    func applying(to text: String) -> String {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard self != .lf else { return unified }
        return unified.replacingOccurrences(of: "\n", with: separator)
    }
}
