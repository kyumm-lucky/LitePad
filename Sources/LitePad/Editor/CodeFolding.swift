import Foundation

/// 代码折叠的区间计算：以「行」为单位，折叠当前行的下级块（缩进更深的连续行）。
/// 只计算字符区间，隐藏由排版管理器把区间内的字形标记为 null 完成，正文本身不动
enum CodeFolding {
    /// 当前行可折叠的区间：从当前行行尾（换行之后）到下一个同级 / 更浅缩进的非空行行首。
    /// 没有下级行时返回 nil。折叠区间包含被隐藏行的换行，折叠后下一行紧接当前行
    static func foldRange(atCharacter location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        let caret = min(max(location, 0), nsText.length)

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: caret, length: 0))
        let currentLine = nsText.substring(with: NSRange(location: lineStart,
                                                         length: contentsEnd - lineStart))
        let currentIndent = indentWidth(of: currentLine, tabWidth: 4)

        var scan = lineEnd
        var hideEnd: Int?
        while scan < nsText.length {
            var start = 0
            var end = 0
            var lineContentsEnd = 0
            nsText.getLineStart(&start, end: &end, contentsEnd: &lineContentsEnd,
                                for: NSRange(location: scan, length: 0))
            let line = nsText.substring(with: NSRange(location: start,
                                                      length: lineContentsEnd - start))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 先遇到更浅或同级的非空行：折叠到此为止，这一行留作可见的下一行
            if !trimmed.isEmpty, indentWidth(of: line, tabWidth: 4) <= currentIndent {
                hideEnd = start
                break
            }
            scan = end
            hideEnd = end
        }

        guard let hideEnd, hideEnd > lineEnd else { return nil }
        return NSRange(location: lineEnd, length: hideEnd - lineEnd)
    }

    /// 字符所在的 1 起行号（行号栏同一口径，只按 \n 计行）
    static func lineNumber(atCharacter location: Int, in text: String) -> Int {
        let nsText = text as NSString
        let clamped = min(max(location, 0), nsText.length)
        var start = 0
        nsText.getLineStart(&start, end: nil, contentsEnd: nil,
                            for: NSRange(location: clamped, length: 0))
        return nsText.substring(to: start).components(separatedBy: "\n").count
    }

    /// 折叠区间的「所有者」行号：折叠起点前一字符所在行，行号栏据此画折叠标记
    static func ownerLineNumbers(for ranges: [NSRange], in text: String) -> Set<Int> {
        guard !ranges.isEmpty else { return [] }
        return Set(ranges.map { lineNumber(atCharacter: $0.location - 1, in: text) })
    }

    private static func indentWidth(of line: String, tabWidth: Int) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 }
            else if character == "\t" { width += tabWidth }
            else { break }
        }
        return width
    }
}
