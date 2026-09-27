import SwiftUI

/// 查找/替换面板：编辑区右上悬浮，承载查找条件、匹配计数与替换操作；
/// 查找/替换的具体计算与执行在模型层（FindEngine）与编辑器桥接层（CodeTextView）
struct FindPanelView: View {
    @ObservedObject var tab: EditorTab
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
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
                panelButton("arrow.uturn.backward", "替换当前匹配") { tab.replaceHandler?(false) }
                panelButton("arrow.2.squarepath", "全部替换") { tab.replaceHandler?(true) }
            }
            HStack(spacing: 12) {
                Toggle("正则", isOn: optionBinding(\.useRegex))
                Toggle("大小写", isOn: optionBinding(\.caseSensitive))
                Toggle("全词", isOn: optionBinding(\.wholeWord))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(8)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .onExitCommand { tab.findState = nil }
        .onAppear { queryFocused = true }
    }

    private var countText: String {
        guard let state = tab.findState, !state.query.isEmpty else { return "" }
        if state.regexError { return "正则无效" }
        if state.matches.isEmpty { return "0/0" }
        return "\(state.current + 1)/\(state.matches.count)"
    }

    private var queryBinding: Binding<String> {
        Binding(get: { tab.findState?.query ?? "" },
                set: { newValue in
                    tab.updateFind {
                        $0.query = newValue
                        $0.current = 0
                    }
                })
    }

    private var replacementBinding: Binding<String> {
        Binding(get: { tab.findState?.replacement ?? "" },
                set: { newValue in
                    tab.updateFind { $0.replacement = newValue }
                })
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
        }
    }
}
