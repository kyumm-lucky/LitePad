import AppKit

/// 语法配色主题：内置固定几套，不做主题编辑器与外部主题文件（KD6）。
/// 每套都给出浅色与深色两组取值：浅色外观取浅色组、深色外观取深色组，
/// 因此选定主题的名称不随系统深浅变化，变的只是按外观解析出的颜色
enum SyntaxTheme: String, CaseIterable, Identifiable {
    case system
    case classic
    case highContrast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .classic: return "经典"
        case .highContrast: return "高对比"
        }
    }
}

/// 一套编辑器配色：语法高亮的六个语义角色（基色、注释、字符串、数字、关键词、标签）
/// 与装饰层、行号栏用色，取色已含透明度。编辑器底色与查找高亮不在这里——
/// 底色跟随系统语义色，查找高亮用强调色区分命中与当前命中，两者都与语法主题无关
struct EditorPalette: Equatable {
    var base: NSColor
    var comment: NSColor
    var string: NSColor
    var number: NSColor
    var keyword: NSColor
    var tag: NSColor
    var currentLine: NSColor
    var indentGuide: NSColor
    var pageGuide: NSColor
    var invisibles: NSColor
    var gutterLabel: NSColor
    var gutterSeparator: NSColor

    /// 按外观解析主题取色：系统语义色落成当前外观下的具体色值，固定取值的主题在浅色 / 深色两组之间取一侧。
    /// 解析出的是具体色值，写进文本存储后不会随外观自己变，外观变化必须重跑一次高亮（KTD6）。
    /// 解析开销按每套十二个颜色计在微秒量级，绘制期直接调用即可
    static func resolve(_ theme: SyntaxTheme, for appearance: NSAppearance) -> EditorPalette {
        switch theme {
        case .system: return system(for: appearance)
        case .classic: return classic(isDark: isDark(appearance))
        case .highContrast: return highContrast(isDark: isDark(appearance))
        }
    }

    // MARK: - 内置主题

    /// 跟随系统：六个角色取系统语义色，随外观与「增强对比度」等辅助功能设置走（默认）
    private static func system(for appearance: NSAppearance) -> EditorPalette {
        func c(_ color: NSColor) -> NSColor { resolved(color, for: appearance) }
        return EditorPalette(
            base: c(.textColor),
            comment: c(.systemGray),
            string: c(.systemRed),
            number: c(.systemBlue),
            keyword: c(.systemPurple),
            tag: c(.systemTeal),
            currentLine: c(.controlAccentColor).withAlphaComponent(0.08),
            indentGuide: c(.separatorColor).withAlphaComponent(0.35),
            pageGuide: c(.separatorColor).withAlphaComponent(0.6),
            invisibles: c(.tertiaryLabelColor),
            gutterLabel: c(.secondaryLabelColor),
            gutterSeparator: c(.separatorColor)
        )
    }

    /// 经典：低饱和的一组固定取值，深色一侧是同色系的提亮版本
    private static func classic(isDark: Bool) -> EditorPalette {
        isDark
            ? EditorPalette(
                base: rgb(0xD4D4D4),
                comment: rgb(0x7F8C98),
                string: rgb(0xFC6A5D),
                number: rgb(0xD0BF69),
                keyword: rgb(0xFF7AB2),
                tag: rgb(0x6BDFFF),
                currentLine: white(0.06),
                indentGuide: white(0.16),
                pageGuide: white(0.26),
                invisibles: white(0.32),
                gutterLabel: white(0.5),
                gutterSeparator: white(0.14))
            : EditorPalette(
                base: rgb(0x24292F),
                comment: rgb(0x6A737D),
                string: rgb(0xB31D28),
                number: rgb(0x005CC5),
                keyword: rgb(0x6F42C1),
                tag: rgb(0x22863A),
                currentLine: black(0.06),
                indentGuide: black(0.14),
                pageGuide: black(0.22),
                invisibles: black(0.28),
                gutterLabel: black(0.45),
                gutterSeparator: black(0.12))
    }

    /// 高对比：基色与编辑器底色拉开到一头一尾，装饰元素同时加深
    private static func highContrast(isDark: Bool) -> EditorPalette {
        isDark
            ? EditorPalette(
                base: rgb(0xFFFFFF),
                comment: rgb(0xB8B8B8),
                string: rgb(0xFF8A8A),
                number: rgb(0x79D0FF),
                keyword: rgb(0xE8A9FF),
                tag: rgb(0x6BE7E7),
                currentLine: white(0.12),
                indentGuide: white(0.4),
                pageGuide: white(0.6),
                invisibles: white(0.6),
                gutterLabel: white(0.85),
                gutterSeparator: white(0.4))
            : EditorPalette(
                base: rgb(0x000000),
                comment: rgb(0x505050),
                string: rgb(0xA50021),
                number: rgb(0x0033CC),
                keyword: rgb(0x6B0090),
                tag: rgb(0x005A5A),
                currentLine: black(0.1),
                indentGuide: black(0.35),
                pageGuide: black(0.5),
                invisibles: black(0.5),
                gutterLabel: black(0.75),
                gutterSeparator: black(0.35))
    }
}

/// 骨架版语法高亮：每次全文重刷，规则按调用顺序形成优先级
/// （注释 > 字符串 > 数字 > 关键词 > 标签），已被着色的区段不会被低优先级规则覆盖。
/// 已知限制：大文件逐键全量重刷性能一般，后续可替换为 tree-sitter 增量解析。
enum SyntaxHighlighter {
    /// 按当前设置的主题与视图外观取一份配色后全文重刷
    static func highlight(textView: NSTextView, language: LanguageDefinition?) {
        highlight(textView: textView, language: language,
                  palette: EditorPalette.resolve(AppSettings.shared.syntaxTheme,
                                                 for: textView.effectiveAppearance))
    }

    static func highlight(textView: NSTextView, language: LanguageDefinition?, palette: EditorPalette) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        defer { storage.endEditing() }

        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: palette.base, range: fullRange)

        guard let language, !language.isPlain else { return }
        let source = storage.string as NSString

        if let (start, end) = blockComment(of: language) {
            apply(to: storage, source: source,
                  pattern: "\(escape(start))[\\s\\S]*?\(escape(end))",
                  options: [], color: palette.comment, base: palette.base)
        }
        if let lineComment = language.lineComment {
            apply(to: storage, source: source,
                  pattern: "\(escape(lineComment))[^\\n]*",
                  options: [], color: palette.comment, base: palette.base)
        }
        if language.tripleQuoteStrings {
            apply(to: storage, source: source, pattern: "\"\"\"[\\s\\S]*?\"\"\"",
                  options: [], color: palette.string, base: palette.base)
            apply(to: storage, source: source, pattern: "'''[\\s\\S]*?'''",
                  options: [], color: palette.string, base: palette.base)
        }
        apply(to: storage, source: source,
              pattern: "\"(?:[^\"\\\\\\n]|\\\\.)*\"",
              options: [], color: palette.string, base: palette.base)
        if language.singleQuoteStrings {
            apply(to: storage, source: source,
                  pattern: "'(?:[^'\\\\\\n]|\\\\.)*'",
                  options: [], color: palette.string, base: palette.base)
        }
        apply(to: storage, source: source,
              pattern: "\\b\\d+(?:\\.\\d+)?\\b",
              options: [], color: palette.number, base: palette.base)
        if !language.keywords.isEmpty {
            let alternation = language.keywords.map(escape).joined(separator: "|")
            let options: NSRegularExpression.Options = language.keywordsIgnoreCase ? [.caseInsensitive] : []
            apply(to: storage, source: source,
                  pattern: "\\b(?:\(alternation))\\b",
                  options: options, color: palette.keyword, base: palette.base)
        }
        if language.highlightTags {
            apply(to: storage, source: source,
                  pattern: "</?[A-Za-z][A-Za-z0-9:.-]*",
                  options: [], color: palette.tag, base: palette.base)
            apply(to: storage, source: source,
                  pattern: "<![^>]*",
                  options: [.caseInsensitive], color: palette.tag, base: palette.base)
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

    /// 着色前先看该位置是否已有前景色：已着色的区段不再被低优先级规则覆盖。
    /// 这个「已着色」判定必须拿同一份主题基色来比——写进存储的是主题解析后的具体色值，
    /// 拿别的基色比会把全部区段都当成已着色，规则优先级随之失效（KTD6）
    private static func apply(to storage: NSTextStorage,
                              source: NSString,
                              pattern: String,
                              options: NSRegularExpression.Options,
                              color: NSColor,
                              base: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let fullRange = NSRange(location: 0, length: source.length)
        regex.enumerateMatches(in: source as String, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  match.range.location != NSNotFound,
                  match.range.length > 0 else { return }
            if let existing = storage.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor,
               !existing.isEqual(base) {
                return
            }
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

// MARK: - 取色

/// 外观是否按深色一侧取色：内置固定取值的主题按它选浅色组还是深色组
private func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

/// 把系统语义色落成给定外观下的具体色值：动态色不落值就写不出「随外观重取」的行为
private func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
    var out = color
    appearance.performAsCurrentDrawingAppearance {
        out = color.usingColorSpace(.sRGB) ?? color
    }
    return out
}

/// 十六进制取色（0xRRGGBB），内置主题的固定取值按这一种写法给出
private func rgb(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
}

/// 装饰层的中性色：浅色一侧用黑、深色一侧用白，只调透明度
private func black(_ alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
}

private func white(_ alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
}
