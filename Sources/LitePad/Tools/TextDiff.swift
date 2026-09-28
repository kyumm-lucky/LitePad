import Foundation

/// 对比结果中的行内片段：changed 为真的片段做高亮（行内差异）
struct DiffSegment: Equatable {
    var text: String
    var changed: Bool
}

/// 对比结果的一行：等同行两侧行号齐全，删除行只有左侧、新增行只有右侧
struct DiffRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case equal
        case removed
        case inserted
    }

    /// 视图标识：每次对比整体重建，索引即标识
    var id: Int = 0
    var kind: Kind
    var leftNumber: Int?
    var rightNumber: Int?
    var segments: [DiffSegment]
}

/// 对比结果：行列表 + 增删行数
struct DiffResult: Equatable {
    var rows: [DiffRow] = []
    var added = 0
    var removed = 0

    var isIdentical: Bool { added == 0 && removed == 0 }
    var isEmpty: Bool { rows.isEmpty }

    static let empty = DiffResult()
}

/// 字符串对比：行级差异（公共前后缀裁剪 + 最长公共子序列）叠加行内字符级差异
enum TextDiffEngine {
    /// 行内字符对比的字符数上限，超长行退化为整行高亮
    private static let maxInlineCharacters = 2000

    /// 对比两段文本；忽略选项只影响「是否算作同一行」，行内高亮始终按原始文本给出
    static func compare(_ left: String, _ right: String,
                        ignoreCase: Bool = false,
                        ignoreWhitespace: Bool = false) -> DiffResult {
        let leftLines = splitLines(left)
        let rightLines = splitLines(right)
        let leftKeys = leftLines.map { normalize($0, ignoreCase: ignoreCase, ignoreWhitespace: ignoreWhitespace) }
        let rightKeys = rightLines.map { normalize($0, ignoreCase: ignoreCase, ignoreWhitespace: ignoreWhitespace) }

        // 公共前后缀不参与差异计算：既省算力，也让结果只聚焦真正变化的中段
        var prefix = 0
        while prefix < leftLines.count, prefix < rightLines.count, leftKeys[prefix] == rightKeys[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < leftLines.count - prefix, suffix < rightLines.count - prefix,
              leftKeys[leftLines.count - 1 - suffix] == rightKeys[rightLines.count - 1 - suffix] {
            suffix += 1
        }

        let leftMiddle = Array(leftLines[prefix..<(leftLines.count - suffix)])
        let rightMiddle = Array(rightLines[prefix..<(rightLines.count - suffix)])
        let leftMiddleKeys = Array(leftKeys[prefix..<(leftKeys.count - suffix)])
        let rightMiddleKeys = Array(rightKeys[prefix..<(rightKeys.count - suffix)])
        let difference = rightMiddleKeys.difference(from: leftMiddleKeys)

        var result = DiffResult()
        var rows: [DiffRow] = []
        rows.reserveCapacity(max(leftLines.count, rightLines.count))
        var leftNumber = 1
        var rightNumber = 1

        for index in 0..<prefix {
            rows.append(DiffRow(kind: .equal, leftNumber: leftNumber, rightNumber: rightNumber,
                                segments: [DiffSegment(text: leftLines[index], changed: false)]))
            leftNumber += 1
            rightNumber += 1
        }

        let removedOffsets = offsets(of: difference.removals)
        let insertedOffsets = offsets(of: difference.insertions)
        var pendingRemoved: [String] = []
        var pendingInserted: [String] = []

        // 一段连续变更：删除行与新增行按位置配对做行内对比，多出的行单独成行
        func flushChangeBlock() {
            guard !pendingRemoved.isEmpty || !pendingInserted.isEmpty else { return }
            let pairs = min(pendingRemoved.count, pendingInserted.count)
            for index in 0..<pairs {
                let segments = inlineSegments(pendingRemoved[index], pendingInserted[index])
                rows.append(DiffRow(kind: .removed, leftNumber: leftNumber, rightNumber: nil,
                                    segments: segments.left))
                leftNumber += 1
                rows.append(DiffRow(kind: .inserted, leftNumber: nil, rightNumber: rightNumber,
                                    segments: segments.right))
                rightNumber += 1
            }
            for index in pairs..<pendingRemoved.count {
                rows.append(DiffRow(kind: .removed, leftNumber: leftNumber, rightNumber: nil,
                                    segments: [DiffSegment(text: pendingRemoved[index], changed: true)]))
                leftNumber += 1
            }
            for index in pairs..<pendingInserted.count {
                rows.append(DiffRow(kind: .inserted, leftNumber: nil, rightNumber: rightNumber,
                                    segments: [DiffSegment(text: pendingInserted[index], changed: true)]))
                rightNumber += 1
            }
            result.removed += pendingRemoved.count
            result.added += pendingInserted.count
            pendingRemoved.removeAll(keepingCapacity: true)
            pendingInserted.removeAll(keepingCapacity: true)
        }

        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < leftMiddle.count || rightIndex < rightMiddle.count {
            if leftIndex < leftMiddle.count, removedOffsets.contains(leftIndex) {
                pendingRemoved.append(leftMiddle[leftIndex])
                leftIndex += 1
                continue
            }
            if rightIndex < rightMiddle.count, insertedOffsets.contains(rightIndex) {
                pendingInserted.append(rightMiddle[rightIndex])
                rightIndex += 1
                continue
            }
            flushChangeBlock()
            if leftIndex < leftMiddle.count, rightIndex < rightMiddle.count {
                rows.append(DiffRow(kind: .equal, leftNumber: leftNumber, rightNumber: rightNumber,
                                    segments: [DiffSegment(text: leftMiddle[leftIndex], changed: false)]))
                leftIndex += 1
                rightIndex += 1
                leftNumber += 1
                rightNumber += 1
            } else if leftIndex < leftMiddle.count {
                // 兜底：差异脚本正常不会走到这里，仍按删除行处理，避免丢行
                pendingRemoved.append(leftMiddle[leftIndex])
                leftIndex += 1
            } else {
                pendingInserted.append(rightMiddle[rightIndex])
                rightIndex += 1
            }
        }
        flushChangeBlock()

        for index in (leftLines.count - suffix)..<leftLines.count {
            rows.append(DiffRow(kind: .equal, leftNumber: leftNumber, rightNumber: rightNumber,
                                segments: [DiffSegment(text: leftLines[index], changed: false)]))
            leftNumber += 1
            rightNumber += 1
        }

        for index in rows.indices {
            rows[index].id = index
        }
        result.rows = rows
        return result
    }

    /// 按行拆分：先把 CRLF / CR 归一为 LF，末尾换行不额外产生空行
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// 行内差异的原始步骤：共同字符，或一侧的变更字符（另一侧可为空）
    private enum InlineStep {
        case common(Character)
        case change(left: String, right: String)
    }

    /// 短于该长度的共同段在夹着变更时按变更处理（world / there 只偶然命中一个字符的场合）
    private static let minCommonRun = 3

    /// 行内字符级差异：按位置配对的行拆成「变化 / 未变化」片段，相邻同类片段合并
    private static func inlineSegments(_ left: String, _ right: String)
        -> (left: [DiffSegment], right: [DiffSegment]) {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        guard leftCharacters.count <= maxInlineCharacters, rightCharacters.count <= maxInlineCharacters else {
            return ([DiffSegment(text: left, changed: true)], [DiffSegment(text: right, changed: true)])
        }

        let difference = rightCharacters.difference(from: leftCharacters)
        let removedOffsets = offsets(of: difference.removals)
        let insertedOffsets = offsets(of: difference.insertions)
        // 先走成步骤序列，再统一吸收短共同段，保证左右两侧的高亮结构完全对称
        var steps: [InlineStep] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < leftCharacters.count || rightIndex < rightCharacters.count {
            if leftIndex < leftCharacters.count, removedOffsets.contains(leftIndex) {
                steps.append(.change(left: String(leftCharacters[leftIndex]), right: ""))
                leftIndex += 1
                continue
            }
            if rightIndex < rightCharacters.count, insertedOffsets.contains(rightIndex) {
                steps.append(.change(left: "", right: String(rightCharacters[rightIndex])))
                rightIndex += 1
                continue
            }
            if leftIndex < leftCharacters.count, rightIndex < rightCharacters.count {
                steps.append(.common(leftCharacters[leftIndex]))
                leftIndex += 1
                rightIndex += 1
            } else if leftIndex < leftCharacters.count {
                // 兜底：差异脚本正常不会走到这里，仍按变更处理，避免丢字符
                steps.append(.change(left: String(leftCharacters[leftIndex]), right: ""))
                leftIndex += 1
            } else {
                steps.append(.change(left: "", right: String(rightCharacters[rightIndex])))
                rightIndex += 1
            }
        }
        absorbShortCommonRuns(&steps)
        return (segments(from: steps, leftSide: true), segments(from: steps, leftSide: false))
    }

    /// 吸收夹在变更之间的短共同段：逐字符高亮否则会出现「整词只亮一半」的割裂显示
    private static func absorbShortCommonRuns(_ steps: inout [InlineStep]) {
        var index = 0
        while index < steps.count {
            guard case .common = steps[index] else {
                index += 1
                continue
            }
            var end = index
            while end < steps.count, case .common = steps[end] {
                end += 1
            }
            if end - index < minCommonRun, index > 0, end < steps.count {
                for position in index..<end {
                    guard case .common(let character) = steps[position] else { continue }
                    steps[position] = .change(left: String(character), right: String(character))
                }
            }
            index = end
        }
    }

    /// 把步骤序列合并为某一侧的分段；本侧无字符的变更不产生空片段
    private static func segments(from steps: [InlineStep], leftSide: Bool) -> [DiffSegment] {
        var result: [DiffSegment] = []
        for step in steps {
            switch step {
            case .common(let character):
                append(String(character), changed: false, to: &result)
            case .change(let leftText, let rightText):
                let text = leftSide ? leftText : rightText
                guard !text.isEmpty else { continue }
                append(text, changed: true, to: &result)
            }
        }
        return result
    }

    /// 追加片段：与上一段同类时合并，避免逐字符细碎片段
    private static func append(_ text: String, changed: Bool, to segments: inout [DiffSegment]) {
        if var last = segments.last, last.changed == changed {
            last.text += text
            segments[segments.count - 1] = last
        } else {
            segments.append(DiffSegment(text: text, changed: changed))
        }
    }

    /// 取差异变更的偏移量：removals 的偏移基于原集合，insertions 的偏移基于结果集合
    private static func offsets<Element>(of changes: [CollectionDifference<Element>.Change]) -> Set<Int> {
        Set(changes.map { change in
            switch change {
            case .remove(let offset, _, _): return offset
            case .insert(let offset, _, _): return offset
            }
        })
    }

    private static func normalize(_ line: String, ignoreCase: Bool, ignoreWhitespace: Bool) -> String {
        var key = line
        if ignoreWhitespace {
            key = key.trimmingCharacters(in: .whitespaces)
        }
        if ignoreCase {
            key = key.lowercased()
        }
        return key
    }
}
