import Foundation

/// 自动闭合的判定上下文：光标前一 / 后一个字符，以及是否位于行首 / 行尾。
/// 边界用可选字符 + 布尔表达，不引入哨兵字符
struct AutoPairContext {
    let left: Character?
    let right: Character?
    let atLineStart: Bool
    let atLineEnd: Bool
}

/// 自动闭合括号与引号的判定规则（R4）：这里只做判断，
/// 写入由 `LiteTextView.handleAutoPair` 走 `insertText` 撤销协议完成
enum AutoPair {
    /// 开括号 → 闭括号；不是可配对的开括号时返回 nil
    static func closing(for opener: Character) -> Character? {
        switch opener {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        case "\"": return "\""
        case "'": return "'"
        default: return nil
        }
    }

    /// 是否是闭括号（用于跳过重复输入与 overtype 判定）
    static func isClosing(_ character: Character) -> Bool {
        character == ")" || character == "]" || character == "}"
            || character == "\"" || character == "'"
    }

    /// 开括号是否应自动补全，按 Notepad++ 手册的三类触发条件判定：
    /// ① 光标位于空配对之间（左侧是开括号、右侧正好是它的闭括号）；
    /// ② 光标两侧都是空白，或处在该行行首 / 行尾；
    /// ③ 左侧是空白且右侧是任意闭括号。其余情况（如 `don` 之后输入 `'`）不补全
    static func shouldAutoClose(opener: Character, context: AutoPairContext) -> Bool {
        guard closing(for: opener) != nil else { return false }
        // ① 空配对之间
        if let left = context.left, let right = context.right, closing(for: left) == right {
            return true
        }
        let leftFree = context.atLineStart || context.left == nil || context.left?.isWhitespace == true
        let rightFree = context.atLineEnd || context.right == nil || context.right?.isWhitespace == true
        // ② 两侧都是空白或行首 / 行尾
        if leftFree && rightFree {
            return true
        }
        // ③ 左侧是空白、右侧是闭括号
        if let left = context.left, left.isWhitespace,
           let right = context.right, isClosing(right) {
            return true
        }
        return false
    }
}
