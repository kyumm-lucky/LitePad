import SwiftUI

/// 查找/替换面板：编辑区右上悬浮，承载查找条件、匹配计数与替换操作；
/// 查找/替换的具体计算与执行在模型层（FindEngine）与编辑器桥接层（CodeTextView）
struct FindPanelView: View {
    @ObservedObject var tab: EditorTab
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // 转义说明放在下方提示行（那儿有完整 tooltip）；输入框本身不加 help——
                // AppKit 会把 help 当可访问性标签，顶掉输入框自己的「查找」名字
                TextField("查找", text: queryBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 150)
                    .focused($queryFocused)
                    .onSubmit { tab.navigateMatch(1) }
                panelButton("chevron.up", "上一个匹配") { tab.navigateMatch(-1) }
                panelButton("chevron.down", "下一个匹配") { tab.navigateMatch(1) }
                Text(countText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tab.findState?.regexError == true ? Color.red : Color.secondary)
                    .help(tab.findState?.regexError == true ? "正则表达式无效" : "")
                Spacer(minLength: 0)
                panelButton("xmark", "关闭（Esc）") { tab.findState = nil }
            }
            HStack(spacing: 6) {
                TextField("替换为", text: replacementBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 150)
                    // 与查找框同口径：回车继续跳到下一个匹配，不用先点回查找框
                    .onSubmit { tab.navigateMatch(1) }
                panelButton("arrow.uturn.backward", "替换当前匹配") { tab.replaceHandler?(false) }
                panelButton("arrow.2.squarepath", "全部替换") { tab.replaceHandler?(true) }
            }
            HStack(spacing: 12) {
                LitePadToggle(title: "正则", isOn: optionBinding(\.useRegex))
                LitePadToggle(title: "大小写", isOn: optionBinding(\.caseSensitive))
                LitePadToggle(title: "全词", isOn: optionBinding(\.wholeWord))
                Spacer(minLength: 0)
                // 单行输入框输不进真实换行，转义是这里唯一的表达方式，直接写在面板上而不是只藏在悬停提示里
                Text("\\n 换行 · \\t 制表符")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(escapesHelp)
            }
        }
        .padding(8)
        .frame(width: 380, alignment: .leading)
        .background(FrostedSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        // 整块参与命中测试：行距、内边距等空白处不再漏到下方编辑器（点击与光标都留在面板上）
        .contentShape(Rectangle())
        .onExitCommand { tab.findState = nil }
        .onAppear {
            // 面板带滑入过渡，出现当帧就设焦点会被过渡吞掉：SwiftUI 侧焦点状态已置真、
            // AppKit 侧第一响应者却还在编辑器上，于是输入与回车都落进编辑器（回车不换搜索结果）。
            // 推迟一帧再设，等第一响应者真正切到输入框
            DispatchQueue.main.async { queryFocused = true }
        }
    }

    private var countText: String {
        guard let state = tab.findState, !state.query.isEmpty else { return "" }
        if state.regexError { return "正则无效" }
        if state.matches.isEmpty { return "0/0" }
        return "\(state.current + 1)/\(state.matches.count)"
    }

    private var queryBinding: Binding<String> {
        Binding(get: { tab.findState?.query ?? "" },
                set: { rawValue in
                    let newValue = FindSyntax.escapingRealNewlines(rawValue)
                    // 回车提交时 SwiftUI 会把同一段文字原样回写一次；若照此重置 current，
                    // 每次回车都会跳回第一个匹配，"下一个"就永远停在 2/N
                    guard newValue != tab.findState?.query else { return }
                    tab.updateFind {
                        $0.query = newValue
                        $0.current = 0
                    }
                })
    }

    private var replacementBinding: Binding<String> {
        Binding(get: { tab.findState?.replacement ?? "" },
                set: { rawValue in
                    let newValue = FindSyntax.escapingRealNewlines(rawValue)
                    // 同上：无变化的回写不再触发整篇重算匹配
                    guard newValue != tab.findState?.replacement else { return }
                    tab.updateFind { $0.replacement = newValue }
                })
    }

    /// 两个输入框共用的转义说明：面板是单行输入框，换行只能这样输
    private var escapesHelp: String {
        "转义：\\n 换行（LF / CRLF 文档都匹配）· \\r 回车 · \\t 制表符 · \\\\ 反斜杠"
    }

    private func optionBinding(_ keyPath: WritableKeyPath<FindState, Bool>) -> Binding<Bool> {
        Binding(get: { tab.findState?[keyPath: keyPath] ?? false },
                set: { newValue in
                    tab.updateFind {
                        $0[keyPath: keyPath] = newValue
                        $0.current = 0
                    }
                })
    }

    private func panelButton(_ symbol: String, _ help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// 面板挂载点：观察 tab 才能感知 findState 开关（ContentView 不观察 EditorTab）
struct FindPanelHost: View {
    @ObservedObject var tab: EditorTab

    var body: some View {
        if tab.findState != nil {
            FindPanelView(tab: tab)
                .padding(.top, 6)
                .padding(.trailing, 10)
                .transition(Motion.slideTransition(from: .top))
                .animation(Motion.panel, value: tab.findState != nil)
        }
    }
}
