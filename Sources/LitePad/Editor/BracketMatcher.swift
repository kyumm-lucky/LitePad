import Foundation

/// 括号配对（R5）：纯函数，给定正文与光标位置算出要同时高亮的两个字符区间。
/// 不处理引号与转义（与现有正则高亮同一粗糙度）：字符串里的括号同样参与配对
enum BracketMatcher {
    /// 配对扫描的字符上限：超过即放弃扫描，只高亮光标处字符
    static let scanLimit = 200_000

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    /// 光标处或光标前一字符所在括号的配对区间。
    /// 光标不在括号上时返回空数组；在括号上但找不到配对时只返回该字符自身区间
    static func matches(in text: NSString, caret: Int) -> [NSRange] {
        guard text.length > 0, caret >= 0, caret <= text.length else { return [] }
        if let ranges = match(at: caret, in: text) { return ranges }
        if caret > 0, let ranges = match(at: caret - 1, in: text) { return ranges }
        return []
    }

    private static func match(at index: Int, in text: NSString) -> [NSRange]? {
        guard index >= 0, index < text.length,
              let scalar = Unicode.Scalar(text.character(at: index)) else { return nil }
        let character = Character(scalar)
        guard isBracket(character) else { return nil }
        let own = NSRange(location: index, length: 1)
        guard let partner = partnerIndex(of: character, at: index, in: text) else {
            return [own]
        }
        return [own, NSRange(location: partner, length: 1)]
    }

    /// 向一侧扫描找配对括号的位置；超出扫描上限或找不到时返回 nil
    private static func partnerIndex(of character: Character, at index: Int,
                                     in text: NSString) -> Int? {
        let isOpening = pairs[character] != nil
        let counterpart: Character
        if let closer = pairs[character] {
            counterpart = closer
        } else if let opener = pairs.first(where: { $0.value == character })?.key {
            counterpart = opener
        } else {
            return nil
        }
        var depth = 0
        var cursor = index
        var steps = 0
        while cursor >= 0, cursor < text.length, steps <= scanLimit {
            if let scalar = Unicode.Scalar(text.character(at: cursor)) {
                let current = Character(scalar)
                if current == character {
                    depth += 1
                } else if current == counterpart {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
            }
            cursor += isOpening ? 1 : -1
            steps += 1
        }
        return nil
    }

    private static func isBracket(_ character: Character) -> Bool {
        pairs[character] != nil || pairs.values.contains(character)
    }
}
