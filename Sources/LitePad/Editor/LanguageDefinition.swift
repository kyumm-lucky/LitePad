import Foundation

/// 骨架版语言定义：用正则规则描述注释 / 字符串 / 关键词等。
/// 后续如需更精准的解析，可整体替换为 tree-sitter grammar。
struct LanguageDefinition: Equatable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let extensions: [String]
    let keywords: [String]
    let keywordsIgnoreCase: Bool
    let lineComment: String?
    let blockCommentStart: String?
    let blockCommentEnd: String?
    /// 可见的块开头字符：回车时若光标前的最后一个非空白字符落在这一组里，新行再加一级缩进。
    /// 纯文本与未知扩展名（回落为纯文本）为空集，即只继承缩进、不加级
    let blockOpeners: [Character]
    let singleQuoteStrings: Bool
    let tripleQuoteStrings: Bool
    let highlightTags: Bool

    var isPlain: Bool { id == "plain" }

    static let plain = LanguageDefinition(
        id: "plain", displayName: "纯文本", extensions: ["txt", "text", "log"],
        keywords: [], keywordsIgnoreCase: false,
        lineComment: nil, blockCommentStart: nil, blockCommentEnd: nil,
        blockOpeners: [],
        singleQuoteStrings: false, tripleQuoteStrings: false, highlightTags: false
    )

    // 标记语言不给块开头字符：开标签与闭标签的收尾字符都是 `>`，而这几门语言的
    // 换行只有「加级」没有「减级」，按 `>` 加级会让每个闭标签行之后越缩越深
    static let html = LanguageDefinition(
        id: "html", displayName: "HTML", extensions: ["html", "htm"],
        keywords: [], keywordsIgnoreCase: true,
        lineComment: nil, blockCommentStart: "<!--", blockCommentEnd: "-->",
        blockOpeners: [],
        singleQuoteStrings: true, tripleQuoteStrings: false, highlightTags: true
    )

    static let xml = LanguageDefinition(
        id: "xml", displayName: "XML", extensions: ["xml", "plist"],
        keywords: [], keywordsIgnoreCase: true,
        lineComment: nil, blockCommentStart: "<!--", blockCommentEnd: "-->",
        blockOpeners: [],
        singleQuoteStrings: true, tripleQuoteStrings: false, highlightTags: true
    )

    static let sql = LanguageDefinition(
        id: "sql", displayName: "SQL", extensions: ["sql"],
        keywords: [
            "ADD", "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "COMMIT",
            "CONSTRAINT", "CREATE", "CROSS", "DEFAULT", "DELETE", "DESC", "DISTINCT",
            "DROP", "ELSE", "END", "EXISTS", "FOREIGN", "FROM", "FULL", "GROUP",
            "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "KEY",
            "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER",
            "OUTER", "PRIMARY", "REFERENCES", "RIGHT", "ROLLBACK", "SELECT", "SET",
            "TABLE", "THEN", "TRANSACTION", "TRIGGER", "UNION", "UPDATE", "VALUES",
            "VIEW", "WHEN", "WHERE"
        ],
        keywordsIgnoreCase: true,
        lineComment: "--", blockCommentStart: "/*", blockCommentEnd: "*/",
        blockOpeners: ["("],
        singleQuoteStrings: true, tripleQuoteStrings: false, highlightTags: false
    )

    static let java = LanguageDefinition(
        id: "java", displayName: "Java", extensions: ["java"],
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
            "class", "continue", "default", "do", "double", "else", "enum", "extends",
            "final", "finally", "float", "for", "if", "implements", "import",
            "instanceof", "int", "interface", "long", "native", "new", "package",
            "private", "protected", "public", "record", "return", "short", "static",
            "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
            "transient", "try", "var", "void", "volatile", "while",
            "true", "false", "null"
        ],
        keywordsIgnoreCase: false,
        lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
        blockOpeners: ["{", "(", "["],
        singleQuoteStrings: true, tripleQuoteStrings: false, highlightTags: false
    )

    static let python = LanguageDefinition(
        id: "python", displayName: "Python", extensions: ["py", "pyw"],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue",
            "def", "del", "elif", "else", "except", "False", "finally", "for", "from",
            "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
            "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
        ],
        keywordsIgnoreCase: false,
        lineComment: "#", blockCommentStart: nil, blockCommentEnd: nil,
        blockOpeners: [":", "{", "(", "["],
        singleQuoteStrings: true, tripleQuoteStrings: true, highlightTags: false
    )

    static let javascript = LanguageDefinition(
        id: "javascript", displayName: "JavaScript", extensions: ["js", "ts", "jsx", "tsx", "mjs"],
        keywords: [
            "async", "await", "break", "case", "catch", "class", "const", "continue",
            "default", "delete", "do", "else", "export", "extends", "false", "finally",
            "for", "function", "if", "import", "in", "instanceof", "let", "new", "null",
            "of", "return", "static", "super", "switch", "this", "throw", "true",
            "try", "typeof", "undefined", "var", "void", "while", "yield"
        ],
        keywordsIgnoreCase: false,
        lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
        blockOpeners: ["{", "(", "["],
        singleQuoteStrings: true, tripleQuoteStrings: false, highlightTags: false
    )

    static let json = LanguageDefinition(
        id: "json", displayName: "JSON", extensions: ["json"],
        keywords: ["true", "false", "null"],
        keywordsIgnoreCase: false,
        lineComment: nil, blockCommentStart: nil, blockCommentEnd: nil,
        blockOpeners: ["{", "["],
        singleQuoteStrings: false, tripleQuoteStrings: false, highlightTags: false
    )

    static let all: [LanguageDefinition] = [
        plain, html, xml, sql, java, python, javascript, json
    ]

    static func detect(from url: URL?) -> LanguageDefinition {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else { return .plain }
        return all.first { $0.extensions.contains(ext) } ?? .plain
    }
}

/// 缩进规则：回车继承与加级、Tab 插入内容、一级缩进的宽度口径都集中在这里的纯逻辑，
/// 按键处理只做取值与插入，装饰层按同一份宽度画缩进指示线（KTD10），两边不各写一份
enum IndentRules {
    /// 缩进宽度的可配置区间：小于 1 构不成一级缩进，大于 16 后一级缩进会超出常见页面宽度
    static let widthRange = 1...16

    /// 收敛缩进宽度到可配置区间（输入框可以填任意整数，取值一律过这里）
    static func clampedWidth(_ raw: Int) -> Int {
        min(widthRange.upperBound, max(widthRange.lowerBound, raw))
    }

    /// 一级缩进的字符串：插入空格时是缩进宽度个空格，否则是一个制表符
    /// （制表符的显示宽度由编辑器按同一缩进宽度设置的制表位保证，见 CodeTextView 的外观应用）
    static func unit(width: Int, insertSpaces: Bool) -> String {
        insertSpaces ? String(repeating: " ", count: clampedWidth(width)) : "\t"
    }

    /// 行首空白（空格与制表符）：行中回车也只继承这一段，不带入行内已有的空格
    static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// 光标前的行内文本是否以该语言的块开头字符结尾：只看最后一个非空白字符，
    /// 纯文本与未知扩展名的块开头字符集为空，判定恒为假（只继承、不加级）
    static func opensBlock(before linePrefix: String, language: LanguageDefinition) -> Bool {
        guard let last = linePrefix.trimmingCharacters(in: .whitespaces).last else { return false }
        return language.blockOpeners.contains(last)
    }

    /// 回车后新行的缩进：继承行首空白，块开头再加一级
    static func newLineIndent(leadingWhitespace: String, opensBlock: Bool,
                              width: Int, insertSpaces: Bool) -> String {
        opensBlock ? leadingWhitespace + unit(width: width, insertSpaces: insertSpaces) : leadingWhitespace
    }
}
