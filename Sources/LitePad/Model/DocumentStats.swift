import Foundation

/// 状态栏展示的文档统计与光标位置信息
struct DocumentStats: Equatable {
    /// 文档总行数（空文档按 0 行显示）
    var totalLines: Int
    /// 字符数（按字素计，emoji 算 1 个字符）
    var characterCount: Int
    /// 词数（连续的英文字母/数字计为 1 个词，中日韩文字逐字计词）
    var wordCount: Int
    /// 光标距文首的偏移（UTF-16 单位）
    var caretOffset: Int
    /// 光标所在行，从 1 起
    var caretLine: Int
    /// 光标所在列，从 0 起
    var caretColumn: Int

    static let empty = DocumentStats(
        totalLines: 0, characterCount: 0, wordCount: 0,
        caretOffset: 0, caretLine: 1, caretColumn: 0
    )

    /// 根据全文与光标偏移（UTF-16 单位）计算统计信息
    static func compute(text: String, caretOffset: Int) -> DocumentStats {
        let nsText = text as NSString
        let length = nsText.length
        let offset = min(max(caretOffset, 0), length)

        // 光标行/列：基于光标前内容里的换行数；\r\n 视为一个换行
        let lineBreaksBefore = countLineBreaks(in: nsText.substring(to: offset))
        let lineRange = nsText.lineRange(for: NSRange(location: offset, length: 0))
        let caretColumn = offset - lineRange.location

        return DocumentStats(
            totalLines: text.isEmpty ? 0 : countLineBreaks(in: text) + 1,
            characterCount: text.count,
            wordCount: countWords(in: text),
            caretOffset: offset,
            caretLine: lineBreaksBefore + 1,
            caretColumn: caretColumn
        )
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
