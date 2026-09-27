import SwiftUI
import AppKit

/// 设置窗口：通用 / 外观 / 窗口 / 格式 四个标签页（工具栏式标签由 Settings 场景自动呈现）
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AppearanceSettingsPane()
                .tabItem { Label("外观", systemImage: "eyeglasses") }
            WindowSettingsPane()
                .tabItem { Label("窗口", systemImage: "macwindow") }
            FormatSettingsPane()
                .tabItem { Label("格式", systemImage: "doc.plaintext") }
        }
        .frame(width: 680)
        .onChange(of: settings.appearanceMode) { _ in settings.applyAppearance() }
    }
}

/// 本机 CommandLineTools 工具链缺少 SwiftUI 宏插件（@State 不可用），
/// 弹层等临时 UI 状态用 @StateObject 承载
private final class SheetToggle: ObservableObject {
    @Published var isPresented = false
}

// MARK: - 通用

private struct GeneralSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("启动时：") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("重新打开最后关闭的窗口", isOn: $settings.restoreSessionOnLaunch)
                        .toggleStyle(.checkbox)
                    HStack(spacing: 8) {
                        Text("当无项目可以打开时：")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $settings.launchAction) {
                            ForEach(LaunchAction.allCases) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                        .disabled(!settings.restoreSessionOnLaunch)
                    }
                    .padding(.leading, 18)
                    .opacity(settings.restoreSessionOnLaunch ? 1 : 0.5)
                }
            }
            SettingsDivider()
            SettingsRow("文稿保存：") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("开启自动保存", isOn: $settings.autosaveEnabled)
                        .toggleStyle(.checkbox)
                    Text("编辑已保存的文件时自动写盘；未标题的文稿仍需手动保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsDivider()
            SettingsRow("当文稿被其他应用更改时：") {
                Picker("", selection: $settings.externalChangeAction) {
                    ForEach(ExternalChangeAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .padding(24)
    }
}

// MARK: - 外观

private struct AppearanceSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("等宽字体：") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(settings.editorFontDisplayName)  \(Int(settings.editorFontSize))")
                            .font(.system(size: 13))
                            .frame(maxWidth: 220)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color(nsColor: .separatorColor))
                            )
                        FontSizeStepper()
                        Button("选择…") { chooseFont() }
                    }
                    Toggle("连字", isOn: $settings.ligaturesEnabled)
                        .toggleStyle(.checkbox)
                }
            }
            SettingsRow("行高：") {
                HStack(spacing: 6) {
                    TextField("", value: $settings.lineHeightMultiple,
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Stepper {
                        EmptyView()
                    } onIncrement: { bumpLineHeight(0.1) } onDecrement: { bumpLineHeight(-0.1) }
                    Text("倍")
                }
            }
            SettingsRow("外观：") {
                RadioRow(options: AppearanceMode.allCases, selection: $settings.appearanceMode,
                         label: \.displayName)
            }
            SettingsRow("状态栏：") {
                RadioRow(options: StatusBarBackgroundStyle.allCases, selection: $settings.statusBarStyle,
                         label: \.displayName)
            }
            SettingsRow("编辑器透明度：") {
                HStack(spacing: 8) {
                    Slider(value: $settings.editorOpacity, in: 10...100, step: 5)
                        .frame(width: 280)
                    Text("\(Int(settings.editorOpacity))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding(24)
    }

    private func bumpLineHeight(_ delta: Double) {
        settings.lineHeightMultiple = min(5, max(0.5, settings.lineHeightMultiple + delta))
    }

    private func chooseFont() {
        let manager = NSFontManager.shared
        manager.setSelectedFont(settings.editorFont, isMultiple: false)
        manager.target = FontPanelTarget.shared
        manager.orderFrontFontPanel(self)
    }
}

/// 字体面板回调：把面板选中的字体写入设置
private final class FontPanelTarget: NSObject {
    static let shared = FontPanelTarget()

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        AppSettings.shared.editorFont = sender.convert(AppSettings.shared.editorFont)
    }
}

/// 字号微调按钮（上下箭头）
private struct FontSizeStepper: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 1) {
            stepperButton("chevron.up") {
                settings.editorFontSize = min(96, settings.editorFontSize + 1)
            }
            stepperButton("chevron.down") {
                settings.editorFontSize = max(6, settings.editorFontSize - 1)
            }
        }
    }

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 16, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 窗口

private struct WindowSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("窗口大小：") {
                HStack(alignment: .top, spacing: 10) {
                    sizeField("自动", binding: widthBinding, caption: "宽度")
                    Text("像素").font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                    sizeField("自动", binding: heightBinding, caption: "高度")
                }
            }
            SettingsDivider()
            SettingsRow("显示：") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("行号", isOn: $settings.showLineNumbers)
                        .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("不可见元素", isOn: $settings.showInvisibles)
                            .toggleStyle(.checkbox)
                        if settings.showInvisibles {
                            HStack(spacing: 14) {
                                Toggle("行尾", isOn: $settings.invisibles.lineEndings)
                                Toggle("制表符", isOn: $settings.invisibles.tabs)
                                Toggle("空格", isOn: $settings.invisibles.spaces)
                            }
                            .toggleStyle(.checkbox)
                            .padding(.leading, 18)
                            HStack(spacing: 14) {
                                Toggle("其他空白字符", isOn: $settings.invisibles.otherWhitespace)
                                Toggle("其他控制字符", isOn: $settings.invisibles.otherControl)
                            }
                            .toggleStyle(.checkbox)
                            .padding(.leading, 18)
                        }
                    }
                    Toggle("缩进指示", isOn: $settings.showIndentGuides)
                        .toggleStyle(.checkbox)
                    HStack(spacing: 6) {
                        Toggle("列位置页面指示：", isOn: $settings.pageGuideEnabled)
                            .toggleStyle(.checkbox)
                        TextField("", value: $settings.pageGuideColumn, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .disabled(!settings.pageGuideEnabled)
                    }
                    .padding(.leading, 18)
                }
            }
            SettingsRow("当前行：") {
                Toggle("改变背景颜色", isOn: $settings.highlightCurrentLine)
                    .toggleStyle(.checkbox)
            }
            SettingsDivider()
            SettingsRow("换行：") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("换行以适合编辑器宽度", isOn: $settings.wrapLines)
                        .toggleStyle(.checkbox)
                    HStack(spacing: 6) {
                        Toggle("自动换行缩进字符数：", isOn: $settings.wrapIndentEnabled)
                            .toggleStyle(.checkbox)
                            .disabled(!settings.wrapLines)
                        TextField("", value: $settings.wrapIndentChars, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                            .disabled(!settings.wrapLines || !settings.wrapIndentEnabled)
                        Text("个空格").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 18)
                }
            }
            SettingsRow("书写方向：") {
                RadioRow(options: WritingDirectionOption.allCases, selection: $settings.writingDirection,
                         label: \.displayName)
            }
            SettingsRow("额外滚动：") {
                HStack(spacing: 6) {
                    TextField("", value: $settings.extraScrollPercent,
                              format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Stepper {
                        EmptyView()
                    } onIncrement: { bumpExtraScroll(5) } onDecrement: { bumpExtraScroll(-5) }
                    Text("%").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsDivider()
            SettingsRow("状态栏显示：") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        Toggle("行数", isOn: $settings.statusBarLineCount)
                        Toggle("位置", isOn: $settings.statusBarCaretOffset)
                    }
                    HStack(spacing: 16) {
                        Toggle("字符数", isOn: $settings.statusBarCharCount)
                        Toggle("当前行", isOn: $settings.statusBarCaretLine)
                    }
                    HStack(spacing: 16) {
                        Toggle("字数", isOn: $settings.statusBarWordCount)
                        Toggle("当前列", isOn: $settings.statusBarCaretColumn)
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(24)
    }

    private func sizeField(_ placeholder: String, binding: Binding<String>, caption: String) -> some View {
        VStack(spacing: 2) {
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.center)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Int? 与输入框字符串的双向绑定；空串清空（自动），非法输入忽略
    private var widthBinding: Binding<String> {
        optionalIntBinding(get: { settings.windowWidth }, set: { settings.windowWidth = $0 })
    }

    private var heightBinding: Binding<String> {
        optionalIntBinding(get: { settings.windowHeight }, set: { settings.windowHeight = $0 })
    }

    private func optionalIntBinding(get: @escaping () -> Int?,
                                    set: @escaping (Int?) -> Void) -> Binding<String> {
        Binding<String>(
            get: { get().map(String.init) ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                set(trimmed.isEmpty ? nil : Int(trimmed))
            }
        )
    }

    private func bumpExtraScroll(_ delta: Double) {
        settings.extraScrollPercent = min(100, max(0, settings.extraScrollPercent + delta))
    }
}

// MARK: - 格式

private struct FormatSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    /// 本机 CommandLineTools 工具链缺少 SwiftUI 宏插件（@State 不可用），临时 UI 状态用 @StateObject 承载
    @StateObject private var sheet = SheetToggle()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("默认行尾：") {
                Picker("", selection: $settings.defaultLineEnding) {
                    ForEach(LineEnding.allCases) { ending in
                        Text(lineEndingName(ending)).tag(ending)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 240)
            }
            SettingsDivider()
            SettingsRow("默认文本编码：") {
                Picker("", selection: $settings.defaultEncoding) {
                    ForEach(TextEncoding.allCases) { encoding in
                        Text(encoding.displayName).tag(encoding)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 380)
            }
            SettingsRow("编码优先级：") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("编辑列表…") { sheet.isPresented = true }
                    Toggle("参考文稿中的编码声明", isOn: $settings.respectCharsetDeclaration)
                        .toggleStyle(.checkbox)
                }
            }
            SettingsDivider()
            SettingsRow("默认语法：") {
                Picker("", selection: Binding<LanguageDefinition>(
                    get: { settings.defaultLanguage },
                    set: { settings.setDefaultLanguage($0) }
                )) {
                    ForEach(LanguageDefinition.all) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 380)
            }
            SettingsRow("可用的语法：") {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(LanguageDefinition.all) { language in
                            Text(language.displayName)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .frame(width: 380, height: 180, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
        .padding(24)
        .sheet(isPresented: $sheet.isPresented) {
            EncodingPrioritySheet(onClose: { sheet.isPresented = false })
        }
    }

    private func lineEndingName(_ ending: LineEnding) -> String {
        switch ending {
        case .lf: return "macOS / Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr: return "经典 Mac (CR)"
        }
    }
}

/// 编码优先级编辑表：无 BOM 文件按列表顺序依次尝试解码
private struct EncodingPrioritySheet: View {
    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    /// 本机工具链 @State 不可用，临时选中状态用 @StateObject 承载
    @StateObject private var state = SelectionState()

    private final class SelectionState: ObservableObject {
        @Published var selection: TextEncoding?
        @Published var toAdd: TextEncoding = .utf8
    }

    /// 可参与自动检测的编码；BOM 变体与宽字符端序由固定探测处理
    private let candidates: [TextEncoding] = [.utf8, .gb18030, .utf16LE, .utf16BE, .utf32LE, .utf32BE]

    var body: some View {
        VStack(spacing: 14) {
            Text("无 BOM 的文件按以下顺序依次尝试解码，顺序即优先级。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                List(settings.encodingPriority, id: \.self, selection: $state.selection) { encoding in
                    Text(encoding.displayName).font(.system(size: 13))
                }
                .frame(width: 300, height: 190)
                VStack(spacing: 8) {
                    listButton("上移", "chevron.up") { move(-1) }
                    listButton("下移", "chevron.down") { move(1) }
                    listButton("移除", "minus") { remove() }
                }
                .padding(.top, 4)
            }
            HStack {
                Picker("添加：", selection: addBinding) {
                    ForEach(remainingCandidates) { encoding in
                        Text(encoding.displayName).tag(encoding)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 320)
                Button("添加") {
                    settings.updateEncodingPriority(settings.encodingPriority + [addBinding.wrappedValue])
                }
                .disabled(remainingCandidates.isEmpty)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var remainingCandidates: [TextEncoding] {
        candidates.filter { !settings.encodingPriority.contains($0) }
    }

    /// 待添加项始终指向剩余候选之一，避免悬空选中值
    private var addBinding: Binding<TextEncoding> {
        Binding<TextEncoding>(
            get: { remainingCandidates.contains(state.toAdd) ? state.toAdd : (remainingCandidates.first ?? .utf8) },
            set: { state.toAdd = $0 }
        )
    }

    private func listButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: symbol)
                .frame(width: 76)
        }
    }

    private func move(_ delta: Int) {
        guard let selection = state.selection,
              let index = settings.encodingPriority.firstIndex(of: selection) else { return }
        let target = index + delta
        guard settings.encodingPriority.indices.contains(target) else { return }
        var list = settings.encodingPriority
        list.swapAt(index, target)
        settings.updateEncodingPriority(list)
    }

    private func remove() {
        guard let selection = state.selection else { return }
        settings.updateEncodingPriority(settings.encodingPriority.filter { $0 != selection })
        state.selection = nil
    }
}

// MARK: - 共用行组件

/// 设置行：右对齐标签 + 内容
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(minWidth: 168, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 4)
    }
}

/// 水平排列的单选组（系统 radioGroup 样式只支持纵向，这里自绘圆点）
private struct RadioRow<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 16) {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: selection == option ? "circle.inset.filled" : "circle")
                            .font(.system(size: 12))
                        Text(label(option))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
