import Foundation

/// 文档内词补全（R6）：收集全文里以光标处前缀开头的词，按出现次数降序取前 `limit` 个。
/// 词边界统一走 `FindEngine.isWordChar`（与查找、取词同一口径：非 CJK 标量且属于
/// `CharacterSet.alphanumerics`，不含下划线；CJK 逐字为边界，因此中文不会成为补全候选的一部分）
enum BufferCompletion {
    /// 候选词的长度上限：过长的词没有补全价值，也避免把整段无分隔文本当成一个词
    static let wordLimit = 64

    /// 候选词：长度 ≥ 2、以 `prefix` 开头且不等于 `prefix`，按出现次数降序（同频按字典序）取前 limit 个
    static func candidates(in text: String, prefix: String, limit: Int = 200) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let nsText = text as NSString
        var counts: [String: Int] = [:]
        var wordStart: Int?

        func flush(endingAt end: Int) {
            defer { wordStart = nil }
            guard let start = wordStart else { return }
            let word = nsText.substring(with: NSRange(location: start, length: end - start))
            guard word.count >= 2,
                  word.count <= wordLimit,
                  word != prefix,
                  word.hasPrefix(prefix) else { return }
            counts[word, default: 0] += 1
        }

        // 按 UTF-16 单元扫描：词字符判定与非词分隔都复用 FindEngine 的同一口径
        var index = 0
        while index < nsText.length {
            if FindEngine.isWordChar(at: index, in: nsText) {
                if wordStart == nil { wordStart = index }
            } else {
                flush(endingAt: index)
            }
            index += 1
        }
        flush(endingAt: nsText.length)

        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map { $0.key }
    }
}
