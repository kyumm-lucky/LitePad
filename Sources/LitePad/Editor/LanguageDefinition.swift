import Foundation

/// 骨架版语言定义：用正则规则描述注释 / 字符串 / 关键词等。
/// 后续如需更精准的解析，可整体替换为 tree-sitter grammar。
struct LanguageDefinition: Equatable, Identifiable {
    let id: String
    let displayName: String
    let extensions: [String]
    let keywords: [String]
    let keywordsIgnoreCase: Bool
    let lineComment: String?
    let blockCommentStart: String?
    let blockCommentEnd: String?
    let singleQuoteStrings: Bool
    let tripleQuoteStrings: Bool
    let highlightTags: Bool

    var isPlain: Bool { id == "plain" }

    static let plain = LanguageDefinition(
        id: "plain", displayName: "纯文本", extensions: ["txt", "text", "log"],
        keywords: [], keywordsIgnoreCase: false,
        lineComment: nil, blockCommentStart: nil, blockCommentEnd: nil,
        singleQuoteStrings: false, tripleQuoteStrings: false, highlightTags: false
    )

    static let html = LanguageDefinition(
        id: "html", displayName: "HTML", extensions: ["html", "htm"],
        keywords: [], keywordsIgnoreCase: true,
        lineComment: nil, blockCommentStart: "<!--", blockCommentEnd: "-->",
        singleQuoteStrings: true, tripleQuoteStrings: false, highlightTags: true
    )

    static let xml = LanguageDefinition(
        id: "xml", displayName: "XML", extensions: ["xml", "plist"],
        keywords: [], keywordsIgnoreCase: true,
        lineComment: nil, blockCommentStart: "<!--", blockCommentEnd: "-->",
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
        singleQuoteStrings: true, tripleQuoteStrings: false, highlightTags: false
    )

    static let json = LanguageDefinition(
        id: "json", displayName: "JSON", extensions: ["json"],
        keywords: ["true", "false", "null"],
        keywordsIgnoreCase: false,
        lineComment: nil, blockCommentStart: nil, blockCommentEnd: nil,
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
