import AppKit

/// 骨架版语法高亮：每次全文重刷，规则按调用顺序形成优先级
/// （注释 > 字符串 > 数字 > 关键词 > 标签），已被着色的区段不会被低优先级规则覆盖。
/// 已知限制：大文件逐键全量重刷性能一般，后续可替换为 tree-sitter 增量解析。
enum SyntaxHighlighter {
    private static let baseColor = NSColor.textColor
    private static let commentColor = NSColor.systemGray
    private static let stringColor = NSColor.systemRed
    private static let numberColor = NSColor.systemBlue
    private static let keywordColor = NSColor.systemPurple
    private static let tagColor = NSColor.systemTeal

    static func highlight(textView: NSTextView, language: LanguageDefinition?) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        defer { storage.endEditing() }

        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

        guard let language, !language.isPlain else { return }
        let source = storage.string as NSString

        if let (start, end) = blockComment(of: language) {
            apply(to: storage, source: source,
                  pattern: "\(escape(start))[\\s\\S]*?\(escape(end))",
                  options: [], color: commentColor)
        }
        if let lineComment = language.lineComment {
            apply(to: storage, source: source,
                  pattern: "\(escape(lineComment))[^\\n]*",
                  options: [], color: commentColor)
        }
        if language.tripleQuoteStrings {
            apply(to: storage, source: source, pattern: "\"\"\"[\\s\\S]*?\"\"\"", options: [], color: stringColor)
            apply(to: storage, source: source, pattern: "'''[\\s\\S]*?'''", options: [], color: stringColor)
        }
        apply(to: storage, source: source,
              pattern: "\"(?:[^\"\\\\\\n]|\\\\.)*\"",
              options: [], color: stringColor)
        if language.singleQuoteStrings {
            apply(to: storage, source: source,
                  pattern: "'(?:[^'\\\\\\n]|\\\\.)*'",
                  options: [], color: stringColor)
        }
        apply(to: storage, source: source,
              pattern: "\\b\\d+(?:\\.\\d+)?\\b",
              options: [], color: numberColor)
        if !language.keywords.isEmpty {
            let alternation = language.keywords.map(escape).joined(separator: "|")
            let options: NSRegularExpression.Options = language.keywordsIgnoreCase ? [.caseInsensitive] : []
            apply(to: storage, source: source,
                  pattern: "\\b(?:\(alternation))\\b",
                  options: options, color: keywordColor)
        }
        if language.highlightTags {
            apply(to: storage, source: source,
                  pattern: "</?[A-Za-z][A-Za-z0-9:.-]*",
                  options: [], color: tagColor)
            apply(to: storage, source: source,
                  pattern: "<![^>]*",
                  options: [.caseInsensitive], color: tagColor)
        }
    }

    // MARK: - Private

    private static func blockComment(of language: LanguageDefinition) -> (String, String)? {
        guard let start = language.blockCommentStart, let end = language.blockCommentEnd else { return nil }
        return (start, end)
    }

    private static func escape(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: text)
    }

    private static func apply(to storage: NSTextStorage,
                              source: NSString,
                              pattern: String,
                              options: NSRegularExpression.Options,
                              color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let fullRange = NSRange(location: 0, length: source.length)
        regex.enumerateMatches(in: source as String, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  match.range.location != NSNotFound,
                  match.range.length > 0 else { return }
            if let existing = storage.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor,
               !existing.isEqual(baseColor) {
                return
            }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
