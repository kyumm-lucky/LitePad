import Foundation

/// 状态栏展示的文档统计与光标位置信息
struct DocumentStats: Equatable {
    /// 文档总行数（空文档按 0 行显示）
    var totalLines: Int
    /// 字符数（按字素计，emoji 算 1 个字符）
    var characterCount: Int
    /// 词数（连续的英文字母/数字计为 1 个词，中日韩文字逐字计词）
    var wordCount: Int
    /// 选区的字符数（按字素计，口径与 characterCount 一致）；无选区时为 0
    var selectionCharacterCount: Int
    /// 选区的词数（口径与 wordCount 一致）；无选区时为 0
    var selectionWordCount: Int
    /// 光标距文首的偏移（UTF-16 单位）
    var caretOffset: Int
    /// 光标所在行，从 1 起
    var caretLine: Int
    /// 光标所在列，从 0 起
    var caretColumn: Int

    static let empty = DocumentStats(
        totalLines: 0, characterCount: 0, wordCount: 0,
        selectionCharacterCount: 0, selectionWordCount: 0,
        caretOffset: 0, caretLine: 1, caretColumn: 0
    )

    /// 根据全文、光标偏移与选区（UTF-16 区间，长度 0 即无选区）计算统计信息
    static func compute(text: String, caretOffset: Int,
                        selectionRange: NSRange = NSRange(location: 0, length: 0)) -> DocumentStats {
        let nsText = text as NSString
        let length = nsText.length
        let offset = min(max(caretOffset, 0), length)

        // 光标行/列：基于光标前内容里的换行数；\r\n 视为一个换行
        let lineBreaksBefore = countLineBreaks(in: nsText.substring(to: offset))
        let lineRange = nsText.lineRange(for: NSRange(location: offset, length: 0))
        let caretColumn = offset - lineRange.location

        let selection = selectionText(in: nsText, range: selectionRange)

        return DocumentStats(
            totalLines: text.isEmpty ? 0 : countLineBreaks(in: text) + 1,
            characterCount: text.count,
            wordCount: countWords(in: text),
            selectionCharacterCount: selection.count,
            selectionWordCount: countWords(in: selection),
            caretOffset: offset,
            caretLine: lineBreaksBefore + 1,
            caretColumn: caretColumn
        )
    }

    /// 选区正文：区间先与全文求交（视图与模型可能瞬时不同步，越界区间不能直接取子串）
    private static func selectionText(in nsText: NSString, range: NSRange) -> String {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: nsText.length))
        return clamped.length > 0 ? nsText.substring(with: clamped) : ""
    }

    /// 换行数：\n 计 1，后跟 \n 的 \r 不计，孤立 \r 计 1
    private static func countLineBreaks(in text: String) -> Int {
        var count = 0
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                count += 1
                previousWasCR = false
            } else if scalar == "\r" {
                previousWasCR = true
            } else {
                if previousWasCR { count += 1 }
                previousWasCR = false
            }
        }
        if previousWasCR { count += 1 }
        return count
    }

    /// 词数：中文/日文汉字与假名逐字计 1 词，其余连续字母数字串计 1 词
    private static func countWords(in text: String) -> Int {
        var count = 0
        var insideWord = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                insideWord = false
            } else if isCJKCharacter(character) {
                count += 1
                insideWord = false
            } else if character.isLetter || character.isNumber {
                if !insideWord {
                    count += 1
                    insideWord = true
                }
            } else {
                insideWord = false
            }
        }
        return count
    }

    static func isCJKCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: isCJKScalar)
    }

    /// 码点级 CJK 判定（汉字/假名），供词边界等需要按码点判定的场景复用
    static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2A6DF: // 汉字
            return true
        case 0x3040...0x30FF, 0x31F0...0x31FF: // 假名
            return true
        default:
            return false
        }
    }
}

/// 选中词在全文中的全部出现（R16），供编辑区高亮
struct SelectedWordHighlight: Equatable {
    /// 选中词原文，字面匹配用
    let word: String
    /// 它在全文中的所有出现区间
    let ranges: [NSRange]

    /// 命中数上限：再高的频率下列出全部出现既没有阅读价值，也是上万条临时属性
    static let matchLimit = 1000

    /// 按选中词与全文算出出现区间；不在启用口径内时返回 nil。
    /// 用字面扫描而非复用查找引擎（KTD11）：查找支持转义语法，选中的字面反斜杠序列
    /// （如 `\n` 两个字符）会被当作换行去匹配，高亮出来的东西与选中词不是一回事
    static func scan(selection: String, in text: String) -> SelectedWordHighlight? {
        // 启用条件：选区非空、单行、非全空白
        guard !selection.isEmpty,
              !selection.contains(where: { $0.isNewline }),
              selection.contains(where: { !$0.isWhitespace }) else { return nil }
        let ranges = literalOccurrences(of: selection, in: text)
        guard !ranges.isEmpty, ranges.count <= matchLimit else { return nil }
        return SelectedWordHighlight(word: selection, ranges: ranges)
    }

    /// 字面逐处扫描（区分大小写：高亮的就是选中的那几个字符本身）；
    /// 命中数超过上限即提前收手，不必把上万处都算出来
    private static func literalOccurrences(of word: String, in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        while start < nsText.length {
            let searchRange = NSRange(location: start, length: nsText.length - start)
            let found = nsText.range(of: word, options: [], range: searchRange, locale: nil)
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            if ranges.count > matchLimit { break }
            start = found.location + found.length
        }
        return ranges
    }
}
