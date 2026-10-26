import SwiftUI
import AppKit

// MARK: - 分组与行

/// 设置分组：组标题在卡片外，卡片只承担一层容器。
/// 组标题→卡片 8pt、组与组 22pt 由调用方的 VStack 间距给出，脚注最多 400 宽
struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String,
         footnote: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupTitleGap) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsStyle.text)
                .padding(.leading, SettingsMetrics.rowPaddingH)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .fill(SettingsStyle.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .strokeBorder(SettingsStyle.cardLine, lineWidth: 0.5)
            )

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsStyle.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400, alignment: .leading)
                    .padding(.leading, 4)
            }
        }
    }
}

/// 行与行之间的发丝线：左起 16、右到卡片边，0.5pt
private struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(SettingsStyle.separator)
            .frame(height: 0.5)
            .padding(.leading, SettingsMetrics.rowPaddingH)
    }
}

/// 设置行：标题与说明左对齐，控件贴着行右缘；
/// 说明文字 11pt 跟在标题下第二行，最多 300 宽自动换行
struct SettingsRow<Content: View>: View {
    let title: String
    var note: String?
    var showsDivider: Bool
    /// 依赖父开关的子项行：左缩进 32、上下留白更紧
    var isSubrow: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String,
         note: String? = nil,
         showsDivider: Bool = true,
         isSubrow: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.showsDivider = showsDivider
        self.isSubrow = isSubrow
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                SettingsHairline()
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsStyle.text)
                    if let note {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsStyle.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 300, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                content()
            }
            .padding(.leading, isSubrow ? SettingsMetrics.subrowIndent : SettingsMetrics.rowPaddingH)
            .padding(.trailing, SettingsMetrics.rowPaddingH)
            .padding(.top, isSubrow ? 4 : SettingsMetrics.rowPaddingV)
            .padding(.bottom, SettingsMetrics.rowPaddingV)
            .frame(minHeight: isSubrow ? 0 : SettingsMetrics.rowMinHeight)
        }
    }
}

/// 整行内容行：给不需要「左标题 + 右控件」结构的行用（状态栏网格、子项勾选格）
struct SettingsBlockRow<Content: View>: View {
    var showsDivider: Bool
    var isSubrow: Bool
    @ViewBuilder let content: () -> Content

    init(showsDivider: Bool = true, isSubrow: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.showsDivider = showsDivider
        self.isSubrow = isSubrow
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                SettingsHairline()
            }
            content()
                .padding(.leading, isSubrow ? SettingsMetrics.subrowIndent : SettingsMetrics.rowPaddingH)
                .padding(.trailing, SettingsMetrics.rowPaddingH)
                .padding(.top, isSubrow ? 4 : 9)
                .padding(.bottom, isSubrow ? 10 : 9)
        }
    }
}

/// 布尔项整行可点：标题 + 说明在左，开关在行右缘。
/// 开关只做展示，命中区是整个行，与 macOS 系统设置一致
struct SettingsSwitchRow: View {
    let title: String
    var note: String?
    var showsDivider: Bool
    @Binding var isOn: Bool

    init(title: String,
         note: String? = nil,
         showsDivider: Bool = true,
         isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self.showsDivider = showsDivider
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                SettingsHairline()
            }
            Button {
                withAnimation(Motion.control) { isOn.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsStyle.text)
                        if let note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(SettingsStyle.text2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 300, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                    SettingsSwitchKnob(isOn: isOn)
                }
                .padding(.horizontal, SettingsMetrics.rowPaddingH)
                .padding(.vertical, SettingsMetrics.rowPaddingV)
                .frame(minHeight: SettingsMetrics.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? L10n.t("已开启") : L10n.t("已关闭"))
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// 开关图形（26 × 15）：轨道与滑块同步走 Motion.control，关→开不回弹
struct SettingsSwitchKnob: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? SettingsStyle.accent : SettingsStyle.switchTrack)
            Circle()
                .fill(Color.white)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .offset(x: isOn ? 12 : 1)
        }
        .frame(width: SettingsMetrics.switchWidth, height: SettingsMetrics.switchHeight)
        .animation(Motion.control, value: isOn)
    }
}

/// 复选项（14 × 14 + 12.5pt 标签）：用于「不可见元素」这类密集子项
struct SettingsCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Motion.control) { isOn.toggle() }
        } label: {
            HStack(spacing: 7) {
                SettingsCheckboxBox(isOn: isOn)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsStyle.text)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? L10n.t("已开启") : L10n.t("已关闭"))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// 清单行：整行可点的复选项，右侧可带一行归属信息（语法名后面的扩展名）
struct SettingsCheckboxRow: View {
    let title: String
    var detail: String?
    var showsDivider: Bool
    @Binding var isOn: Bool

    init(title: String,
         detail: String? = nil,
         showsDivider: Bool = true,
         isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.showsDivider = showsDivider
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                SettingsHairline()
            }
            Button {
                withAnimation(Motion.control) { isOn.toggle() }
            } label: {
                HStack(spacing: 8) {
                    SettingsCheckboxBox(isOn: isOn)
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsStyle.text)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsStyle.text2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SettingsMetrics.rowPaddingH)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(detail.map { "\(title) \($0)" } ?? title)
            .accessibilityValue(isOn ? L10n.t("已排除") : L10n.t("未排除"))
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// 只有图形的复选方框：给需要自动布局宽度的清单行复用
struct SettingsCheckboxBox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(isOn ? SettingsStyle.accent : SettingsStyle.field)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(isOn ? SettingsStyle.accent : SettingsStyle.controlLine, lineWidth: 1)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0)
            )
            .frame(width: SettingsMetrics.checkboxSize, height: SettingsMetrics.checkboxSize)
    }
}

/// 分段控件：两三项互斥，高 26（22 档位 + 上下 2 留白），选中档位浮一层浅色滑块
struct SettingsSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    @StateObject private var hover = SettingsIndexHoverState()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    withAnimation(Motion.control) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: selection == option ? .medium : .regular))
                        .foregroundStyle(SettingsStyle.text)
                        .padding(.horizontal, 12)
                        .frame(height: SettingsMetrics.segmentHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selection == option
                                      ? SettingsStyle.segmentThumb
                                      : (hover.index == index ? SettingsStyle.selection : Color.clear))
                        )
                        .shadow(color: selection == option ? .black.opacity(0.16) : .clear, radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover.index = $0 ? index : nil }
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(selection == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .fill(SettingsStyle.segmentTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(SettingsStyle.controlLine, lineWidth: 0.5)
        )
    }
}

/// 纵向单选：用于「文稿被其他应用更改时」这类三项互斥
struct SettingsRadioList<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    withAnimation(Motion.control) { selection = option }
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(SettingsStyle.field)
                                .overlay(
                                    Circle().strokeBorder(selection == option
                                                          ? SettingsStyle.accent
                                                          : SettingsStyle.controlLine,
                                                          lineWidth: 1.5)
                                )
                            if selection == option {
                                Circle()
                                    .fill(SettingsStyle.accent)
                                    .padding(3.5)
                            }
                        }
                        .frame(width: 14, height: 14)
                        Text(label(option))
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsStyle.text)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(selection == option ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// MARK: - 外观预览

/// 外观三块预览（66 × 42 + 11pt 标签）：替代原来的三项单选，
/// 选中只看 2pt 强调色环，不加勾选角标
struct AppearanceTiles: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: SettingsMetrics.tileGap) {
            tile(.system, name: L10n.t("匹配系统")) {
                HStack(spacing: 0) {
                    MiniWindowShot(tone: .light)
                    MiniWindowShot(tone: .dark)
                }
            }
            tile(.light, name: L10n.t("浅色")) {
                MiniWindowShot(tone: .light)
            }
            tile(.dark, name: L10n.t("深色")) {
                MiniWindowShot(tone: .dark)
            }
        }
    }

    private func tile<Shot: View>(_ mode: AppearanceMode,
                                  name: String,
                                  @ViewBuilder shot: () -> Shot) -> some View {
        Button {
            withAnimation(Motion.control) { selection = mode }
        } label: {
            VStack(spacing: 5) {
                shot()
                    .frame(width: SettingsMetrics.tileWidth, height: SettingsMetrics.tileHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(SettingsStyle.cardLine, lineWidth: 0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(SettingsStyle.accent, lineWidth: 2)
                            .opacity(selection == mode ? 1 : 0)
                    )
                Text(name)
                    .font(.system(size: 11, weight: selection == mode ? .medium : .regular))
                    .foregroundStyle(selection == mode ? SettingsStyle.text : SettingsStyle.text2)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selection == mode ? [.isButton, .isSelected] : .isButton)
    }
}

/// 预览小窗：顶栏一条、左侧栏一条、正文三行。用相对尺寸，半宽（匹配系统）时同样成立
private struct MiniWindowShot: View {
    let tone: SettingsStyle.MiniTone

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let barHeight = max(3, height * 0.14)
            let sideWidth = max(4, width * 0.17)
            VStack(spacing: 0) {
                tone.bar.frame(height: barHeight)
                HStack(spacing: 0) {
                    tone.side.frame(width: sideWidth)
                    VStack(alignment: .leading, spacing: max(1.5, height * 0.07)) {
                        line(width: width * 0.62, height: height)
                        line(width: width * 0.48, height: height)
                        line(width: width * 0.34, height: height)
                    }
                    .padding(.leading, max(2, width * 0.09))
                    .padding(.top, max(2, height * 0.12))
                    Spacer(minLength: 0)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .background(tone.background)
        }
    }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(tone.line)
            .frame(width: max(2, width), height: max(1, height * 0.05))
    }
}

// MARK: - 输入与按钮

/// 行内数值输入框外形：28 高、圆角 6、0.5 描边、控件底
extension View {
    func settingsFieldLook(width: CGFloat) -> some View {
        self
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(SettingsStyle.text)
            .padding(.horizontal, 8)
            .frame(width: width, height: SettingsMetrics.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .fill(SettingsStyle.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .strokeBorder(SettingsStyle.controlLine, lineWidth: 0.5)
            )
    }
}

/// 设置页普通按钮：28 高、单层 0.5 描边、悬停换底色
struct SettingsButton: View {
    let title: String
    var action: () -> Void
    @StateObject private var hover = InterfaceHoverState()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(SettingsStyle.text)
                .padding(.horizontal, 12)
                .frame(height: SettingsMetrics.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                        .fill(hover.isHovered ? SettingsStyle.controlHover : SettingsStyle.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                        .strokeBorder(SettingsStyle.controlLine, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .accessibilityLabel(title)
    }
}

/// 设置页强调按钮：只用于附属表的确认动作；`isDefault` 让「完成」继续吃回车
struct SettingsAccentButton: View {
    let title: String
    var isDefault: Bool
    var action: () -> Void
    @StateObject private var hover = InterfaceHoverState()

    init(title: String, isDefault: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDefault = isDefault
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(height: SettingsMetrics.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                        .fill(SettingsStyle.accent.opacity(hover.isHovered ? 0.86 : 1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .keyboardShortcut(isDefault ? KeyboardShortcut.defaultAction : nil)
        .accessibilityLabel(title)
    }
}

/// 步进器（22 × 28）：上下两个按钮之间一条发丝线，不再做「外描边 + 内填充」双层
struct SettingsStepper: View {
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    @StateObject private var hover = StepperHoverState()

    var body: some View {
        VStack(spacing: 0) {
            button("chevron.up", index: 0, action: onIncrement)
            Rectangle()
                .fill(SettingsStyle.controlLine)
                .frame(height: 0.5)
            button("chevron.down", index: 1, action: onDecrement)
        }
        .frame(width: SettingsMetrics.stepperWidth, height: SettingsMetrics.fieldHeight)
        .foregroundStyle(SettingsStyle.text2)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .fill(SettingsStyle.control)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(SettingsStyle.controlLine, lineWidth: 0.5)
        )
    }

    private func button(_ symbol: String, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(hover.index == index ? SettingsStyle.controlHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.index = $0 ? index : nil }
    }
}

private final class StepperHoverState: ObservableObject {
    @Published var index: Int?
}
