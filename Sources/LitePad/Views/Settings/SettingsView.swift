import SwiftUI
import AppKit

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case window
    case format

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .window: return "编辑器"
        case .format: return "格式"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "启动与保存"
        case .appearance: return "字体与主题"
        case .window: return "显示与排版"
        case .format: return "编码与语法"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "eyeglasses"
        case .window: return "text.alignleft"
        case .format: return "doc.plaintext"
        }
    }
}

private final class SettingsNavigationState: ObservableObject {
    @Published var section: SettingsSection = .general
}

/// 主窗口左侧设置抽屉：分组导航固定在左侧，具体选项在右侧滚动查看。
struct SettingsView: View {
    static let drawerWidth: CGFloat = 660
    /// 详情区坐标空间：下拉锚点与弹层同用一处，弹层才能按锚点摆对位置
    static let detailCoordinateSpace = "settingsDetail"

    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var navigation = SettingsNavigationState()
    @StateObject private var popups = SettingsPopupState(space: SettingsView.detailCoordinateSpace)

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(InterfaceStyle.border)
                .frame(width: 1)
            detail
        }
        .frame(width: Self.drawerWidth)
        .frame(maxHeight: .infinity)
        .background(FrostedSurface(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(InterfaceStyle.frostedEdge, lineWidth: 1)
        )
        .onChange(of: settings.appearanceMode) { _ in settings.applyAppearance() }
        // 换页时原页面连同按钮一起消失，弹层留在宿主顶层不会自己收，这里显式收掉
        .onChange(of: navigation.section) { _ in popups.dismiss() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.accent)
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 20)

            Text("工作区配置")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(InterfaceStyle.muted)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        withAnimation(Motion.control) {
                            navigation.section = section
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: section.icon)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(section.subtitle)
                                    .font(.system(size: 9))
                                    .foregroundStyle(InterfaceStyle.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(navigation.section == section ? InterfaceStyle.accent : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(navigation.section == section
                                      ? InterfaceStyle.accentSoft
                                      : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(navigation.section == section
                                              ? InterfaceStyle.accentBorder
                                              : Color.clear,
                                              lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("LitePad")
                    .font(.system(size: 11, weight: .semibold))
                Text("原生文本工作台")
                    .font(.system(size: 9))
                    .foregroundStyle(InterfaceStyle.muted)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .frame(width: 150)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.12))
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(navigation.section.title)
                        .font(.system(size: 18, weight: .semibold))
                    Text(navigation.section.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(InterfaceStyle.muted)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭设置")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle()
                .fill(InterfaceStyle.border)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                currentPane
                    .padding(18)
            }
        }
        .frame(maxHeight: .infinity)
        // 弹层挂在滚动视图之外：滚动内容裁不到它，页内顺序也压不住它
        .settingsPopupHost(popups)
    }

    @ViewBuilder
    private var currentPane: some View {
        switch navigation.section {
        case .general:
            SettingsCard(title: "启动与保存",
                         subtitle: "控制工作区恢复、自动保存和外部文件变化",
                         icon: "arrow.clockwise") {
                GeneralSettingsPane(popups: popups)
            }
        case .appearance:
            SettingsCard(title: "字体与主题",
                         subtitle: "调整代码阅读时的字体、颜色和透明度",
                         icon: "eyeglasses") {
                AppearanceSettingsPane()
            }
        case .window:
            SettingsCard(title: "编辑器布局",
                         subtitle: "管理窗口尺寸、辅助标记、换行和状态栏",
                         icon: "text.alignleft") {
                WindowSettingsPane()
            }
        case .format:
            SettingsCard(title: "编码与语法",
                         subtitle: "设置新文稿的编码、行尾和默认语法",
                         icon: "doc.plaintext") {
                FormatSettingsPane(popups: popups)
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: () -> Content

    init(title: String,
         subtitle: String,
         icon: String,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(InterfaceStyle.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(InterfaceStyle.muted)
                }
            }

            Rectangle()
                .fill(InterfaceStyle.border)
                .frame(height: 1)

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(InterfaceStyle.raised.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(InterfaceStyle.border, lineWidth: 1)
        )
    }
}

/// 本机 CommandLineTools 工具链缺少 SwiftUI 宏插件（@State 不可用），
/// 弹层等临时 UI 状态用 @StateObject 承载
private final class SheetToggle: ObservableObject {
    @Published var isPresented = false
}

/// 设置页下拉弹层：锚点由选择器上报，面板统一渲染在宿主顶层。
/// 弹层与按钮分处两层，同行后续视图盖不住它，外层滚动视图也裁不到它
private final class SettingsPopupState: ObservableObject {
    struct Request {
        /// 唯一标识：用选择器标题，同一宿主内不重名；同时充当面板 id，切换时重放出场动画
        var id: String
        var title: String
        var options: [String]
        var selectedIndex: Int?
        var width: CGFloat
        /// 触发按钮在宿主坐标空间 `space` 中的位置
        var anchor: CGRect
        let onSelect: (Int) -> Void
    }

    /// 锚点测量所用的命名坐标空间：设置抽屉与编码优先级表各持一份，互不串用
    let space: String
    /// 弹层与宿主边缘、与按钮之间的安全距离
    static let margin: CGFloat = 8

    @Published var request: Request?
    @Published var hoveredIndex: Int?
    @Published var containerSize: CGSize = .zero

    init(space: String) {
        self.space = space
    }

    func present(_ request: Request) {
        hoveredIndex = nil
        self.request = request
    }

    func dismiss() {
        request = nil
        hoveredIndex = nil
    }

    /// 滚动或布局变化后跟随按钮；只有当前展开的这一项需要更新
    func follow(id: String, anchor: CGRect) {
        guard var current = request, current.id == id, current.anchor != anchor else { return }
        current.anchor = anchor
        request = current
    }
}

/// 选择器的锚点测量值：本工程无 @State 宏，测量值用轻量对象承载
private final class SettingsAnchorState: ObservableObject {
    @Published var anchor: CGRect = .zero
}

/// 列表内的悬停行；同样不能用 @State
private final class SettingsIndexHoverState: ObservableObject {
    @Published var index: Int?
}

/// 弹层宿主：内容布局不变，弹层覆盖其上并按锚点摆放
private struct SettingsPopupHost: ViewModifier {
    @ObservedObject var state: SettingsPopupState

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { state.containerSize = proxy.size }
                        .onChange(of: proxy.size) { state.containerSize = $0 }
                }
            )
            .coordinateSpace(name: state.space)
            .overlay(alignment: .topLeading) {
                SettingsPopupLayer(state: state)
            }
    }
}

/// 弹层本体：按锚点摆在按钮下方；下方放不下改向上展开，两侧都放不下就把选项区限制在可用高度内滚动
private struct SettingsPopupLayer: View {
    @ObservedObject var state: SettingsPopupState

    private struct Placement {
        let top: CGFloat
        let maxRowsHeight: CGFloat?
        let revealOffset: CGFloat
    }

    var body: some View {
        if let request = state.request {
            let placement = placement(for: request)
            OptionPanel(title: request.title,
                        options: request.options,
                        selectedIndex: request.selectedIndex,
                        hoveredIndex: state.hoveredIndex,
                        width: request.width,
                        // 向下展开自上方落下，向上展开自下方升起
                        revealOffset: placement.revealOffset,
                        onSelect: request.onSelect,
                        onHover: { state.hoveredIndex = $0 },
                        maxRowsHeight: placement.maxRowsHeight)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: min(request.anchor.minX, max(0, state.containerSize.width
                                                        - request.width
                                                        - SettingsPopupState.margin)),
                        y: placement.top)
                .id(request.id)
        }
    }

    private func placement(for request: SettingsPopupState.Request) -> Placement {
        let margin = SettingsPopupState.margin
        let natural = OptionPanel.estimatedHeight(optionCount: request.options.count)
        // 两侧可用空间都扣掉两层边距：一层贴着按钮，一层避开宿主边缘（含圆角）
        let below = state.containerSize.height - request.anchor.maxY - margin * 2
        let above = request.anchor.minY - margin * 2

        if natural <= below {
            return Placement(top: request.anchor.maxY + margin, maxRowsHeight: nil, revealOffset: -6)
        }
        if natural <= above {
            return Placement(top: request.anchor.minY - margin - natural, maxRowsHeight: nil, revealOffset: 6)
        }
        // 两侧都放不下：选空间大的一侧，选项区滚起来，面板高度正好占满这一侧
        let cap = OptionPanel.chromeHeight + max(OptionPanel.rowHeight,
                                                max(below, above) - OptionPanel.chromeHeight)
        if below >= above {
            return Placement(top: request.anchor.maxY + margin,
                             maxRowsHeight: cap - OptionPanel.chromeHeight,
                             revealOffset: -6)
        }
        return Placement(top: max(0, request.anchor.minY - margin - cap),
                         maxRowsHeight: cap - OptionPanel.chromeHeight,
                         revealOffset: 6)
    }
}

private extension View {
    /// 让本视图成为下拉弹层的宿主：弹层渲染在内容之上，不受同行视图与滚动视图影响
    func settingsPopupHost(_ state: SettingsPopupState) -> some View {
        modifier(SettingsPopupHost(state: state))
    }
}

/// 与状态栏下拉共用 OptionPanel 的设置选择器；面板由宿主（`settingsPopupHost`）渲染
private struct SettingsPicker<Option: Hashable & Identifiable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    let width: CGFloat
    @ObservedObject var popups: SettingsPopupState
    @StateObject private var anchor = SettingsAnchorState()

    private var selectedIndex: Int? {
        options.firstIndex(of: selection)
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(label(selection))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.accent)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(InterfaceStyle.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(popups.request?.id == title
                                  ? InterfaceStyle.accentBorder
                                  : InterfaceStyle.borderStrong,
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { anchor.anchor = proxy.frame(in: .named(popups.space)) }
                    .onChange(of: proxy.frame(in: .named(popups.space))) { anchor.anchor = $0 }
            }
        )
        // 宿主内滚动或换行时按钮会挪位，弹层跟着走，免得脱开按钮停在半空
        .onChange(of: anchor.anchor) { popups.follow(id: title, anchor: $0) }
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
    }

    private func toggle() {
        guard popups.request?.id != title else {
            popups.dismiss()
            return
        }
        popups.present(SettingsPopupState.Request(id: title,
                                                  title: title,
                                                  options: options.map(label),
                                                  selectedIndex: selectedIndex,
                                                  width: max(width, 200),
                                                  anchor: anchor.anchor,
                                                  onSelect: { index in
                                                      guard options.indices.contains(index) else { return }
                                                      selection = options[index]
                                                      popups.dismiss()
                                                  }))
    }
}

/// 多选项单选列表，替代系统 radioGroup，保持设置页与下拉列表一致。
private struct SettingsRadioList<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    @StateObject private var hover = SettingsIndexHoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selection == option
                              ? "circle.inset.filled"
                              : "circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selection == option
                                             ? InterfaceStyle.accent
                                             : InterfaceStyle.muted)
                        Text(label(option))
                            .font(.system(size: 12, weight: selection == option ? .medium : .regular))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == option
                                  ? InterfaceStyle.accentSoft
                                  : (hover.index == index ? InterfaceStyle.raised : Color.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(selection == option
                                          ? InterfaceStyle.accentBorder
                                          : Color.clear,
                                          lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover.index = $0 ? index : nil }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }
}

/// 编码优先级列表：保留选择、悬停和标题计数，避免系统 List 的默认外观。
private struct SettingsSelectionList<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option?
    let title: String
    let label: (Option) -> String
    let width: CGFloat
    let height: CGFloat
    @StateObject private var hover = SettingsIndexHoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(options.count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(InterfaceStyle.muted)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rectangle()
                .fill(InterfaceStyle.border)
                .frame(height: 1)
                .padding(.horizontal, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        Button {
                            selection = option
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selection == option
                                      ? "circle.inset.filled"
                                      : "circle")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(selection == option
                                                     ? InterfaceStyle.accent
                                                     : InterfaceStyle.muted)
                                Text(label(option))
                                    .font(.system(size: 11, weight: selection == option ? .medium : .regular))
                                    .foregroundStyle(selection == option ? .primary : InterfaceStyle.muted)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 26)
                            .padding(.horizontal, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selection == option
                                          ? InterfaceStyle.accentSoft
                                          : (hover.index == index ? InterfaceStyle.raised : Color.clear))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(selection == option
                                                  ? InterfaceStyle.accentBorder
                                                  : Color.clear,
                                                  lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hover.index = $0 ? index : nil }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(FrostedSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1)
        )
    }
}

private enum SettingsMetrics {
    /// 输入框统一高度：行高、窗口宽高、额外滚动与等宽字体显示框共用，
    /// 新增输入框时一并取这里，避免各行高度再次走散
    static let fieldHeight: CGFloat = 28
    /// 定高输入框里 12pt 文字的基线位置（框顶到基线的距离）；
    /// 只有图形没有文字的控件（步进器）也用它声明基线，行标题才能与框内文字对齐
    static let fieldTextBaseline: CGFloat = 18
}

private extension View {
    func settingsFieldFrame(width: CGFloat) -> some View {
        self
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: width, height: SettingsMetrics.fieldHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(InterfaceStyle.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1)
            )
    }
}

// MARK: - 通用

private struct GeneralSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var popups: SettingsPopupState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("启动时：") {
                VStack(alignment: .leading, spacing: 8) {
                    LitePadToggle(title: "重新打开最后关闭的窗口",
                                  isOn: $settings.restoreSessionOnLaunch)
                    HStack(spacing: 8) {
                        Text("当无项目可以打开时：")
                            .foregroundStyle(.secondary)
                        SettingsPicker(title: "启动动作",
                                       selection: $settings.launchAction,
                                       options: LaunchAction.allCases,
                                       label: \.displayName,
                                       width: 180,
                                       popups: popups)
                        .disabled(!settings.restoreSessionOnLaunch)
                    }
                    .padding(.leading, 18)
                    .opacity(settings.restoreSessionOnLaunch ? 1 : 0.5)
                }
            }
            SettingsDivider()
            SettingsRow("文稿保存：") {
                VStack(alignment: .leading, spacing: 4) {
                    LitePadToggle(title: "开启自动保存", isOn: $settings.autosaveEnabled)
                    Text("编辑已保存的文件时自动写盘；未标题的文稿仍需手动保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LitePadToggle(title: "保存时删除行尾空白",
                                  isOn: $settings.trimTrailingWhitespaceOnSave)
                    LitePadToggle(title: "保存时补齐末尾换行",
                                  isOn: $settings.ensureFinalNewlineOnSave)
                    Text("两项只在显式保存（含关闭标签与退出时的确认保存）前执行，自动保存不改动正文。"
                         + "两项都不是保义操作：删除行尾空白会破坏 Markdown 的行尾双空格（硬换行）与补丁文件的空行，"
                         + "补齐末尾换行会改写补丁文件这类以末尾换行为语义的格式；"
                         + "没有内置语法的扩展名（如 Markdown 的 .md）按「纯文本」归类，"
                         + "需要保留时在下方按语法排除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340, alignment: .leading)
                    // 排除口径只在这两项有任一项开启时才有意义
                    if settings.saveCleanupEnabled {
                        SaveCleanupExclusionList()
                    }
                }
            }
            SettingsDivider()
            SettingsRow("当文稿被其他应用更改时：") {
                SettingsRadioList(options: ExternalChangeAction.allCases,
                                  selection: $settings.externalChangeAction,
                                  label: \.displayName)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 保存时清理的按语法排除表：勾中的语法在保存时保留原样
/// （Markdown 的行尾双空格是硬换行、补丁文件的空行有意义，这类格式不能删行尾空白）
private struct SaveCleanupExclusionList: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var hover = SettingsIndexHoverState()

    var body: some View {
        let languages = LanguageDefinition.all
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.square")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.accent)
                Text("不清理这些语法")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(settings.saveCleanupExcludedLanguageIDs.count)/\(languages.count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(InterfaceStyle.muted)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rectangle()
                .fill(InterfaceStyle.border)
                .frame(height: 1)
                .padding(.horizontal, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(languages.indices, id: \.self) { index in
                        let language = languages[index]
                        Button {
                            settings.setSaveCleanupExcluded(!settings.isSaveCleanupExcluded(language),
                                                            for: language)
                        } label: {
                            row(language, index: index)
                        }
                        .buttonStyle(.plain)
                        .onHover { hover.index = $0 ? index : nil }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 300, height: 150, alignment: .topLeading)
        .background(FrostedSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1)
        )
    }

    /// 一行语法：勾选框 + 语法名 + 归属的扩展名（落到该语法的文件都会受影响）
    private func row(_ language: LanguageDefinition, index: Int) -> some View {
        let excluded = settings.isSaveCleanupExcluded(language)
        return HStack(spacing: 7) {
            Image(systemName: excluded ? "checkmark.square.fill" : "square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(excluded ? InterfaceStyle.accent : InterfaceStyle.muted)
            Text(language.displayName)
                .font(.system(size: 11, weight: excluded ? .medium : .regular))
                .foregroundStyle(excluded ? .primary : InterfaceStyle.muted)
                .lineLimit(1)
            Text(language.extensions.joined(separator: " / "))
                .font(.system(size: 9))
                .foregroundStyle(InterfaceStyle.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(excluded
                      ? InterfaceStyle.accentSoft
                      : (hover.index == index ? InterfaceStyle.raised : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(excluded ? InterfaceStyle.accentBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
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
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .frame(maxWidth: 180)
                            .padding(.horizontal, 10)
                            // 与「行高」等输入框同高；长字体名只截断，不再把这一行撑高
                            .frame(height: SettingsMetrics.fieldHeight)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(InterfaceStyle.field)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(InterfaceStyle.borderStrong)
                            )
                        FontSizeStepper()
                        Button("选择…") { chooseFont() }
                            .buttonStyle(PanelActionButtonStyle(tone: .neutral,
                                                                minHeight: SettingsMetrics.fieldHeight))
                    }
                    LitePadToggle(title: "连字", isOn: $settings.ligaturesEnabled)
                }
            }
            SettingsRow("行高：") {
                HStack(spacing: 6) {
                    TextField("", value: $settings.lineHeightMultiple,
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.plain)
                        .settingsFieldFrame(width: 64)
                        .multilineTextAlignment(.trailing)
                    SettingsStepper(onIncrement: { bumpLineHeight(0.1) },
                                    onDecrement: { bumpLineHeight(-0.1) })
                    Text("倍")
                }
            }
            SettingsRow("外观：") {
                RadioRow(options: AppearanceMode.allCases, selection: $settings.appearanceMode,
                         label: \.displayName)
            }
            SettingsRow("顶栏与状态栏：") {
                RadioRow(options: StatusBarBackgroundStyle.allCases, selection: $settings.statusBarStyle,
                         label: \.displayName)
            }
            SettingsRow("编辑器透明度：") {
                HStack(spacing: 8) {
                    Slider(value: $settings.editorOpacity, in: 10...100, step: 5)
                        .frame(width: 240)
                    Text("\(Int(settings.editorOpacity))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
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

/// 字号微调按钮（上下箭头）：与「行高」等输入框同高，取 SettingsStepper 的默认尺寸
private struct FontSizeStepper: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsStepper(onIncrement: { settings.editorFontSize = min(96, settings.editorFontSize + 1) },
                        onDecrement: { settings.editorFontSize = max(6, settings.editorFontSize - 1) })
    }
}

private struct SettingsStepper: View {
    var width: CGFloat = 22
    var height: CGFloat = 28
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            stepperButton("chevron.up", action: onIncrement)
            stepperButton("chevron.down", action: onDecrement)
        }
        .frame(width: width, height: height)
        // 两个按钮都只有图标没有文字，SwiftUI 合成出的基线偏高，会把同一行左侧的标题
        // 拉到输入框上沿；这里按输入框内文字的基线声明，标题才与框内文字齐平
        .alignmentGuide(.firstTextBaseline) { _ in SettingsMetrics.fieldTextBaseline }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(InterfaceStyle.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1)
        )
    }

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    LitePadToggle(title: "行号", isOn: $settings.showLineNumbers)
                    VStack(alignment: .leading, spacing: 4) {
                        LitePadToggle(title: "不可见元素", isOn: $settings.showInvisibles)
                        if settings.showInvisibles {
                            HStack(spacing: 14) {
                                LitePadToggle(title: "行尾", isOn: $settings.invisibles.lineEndings)
                                LitePadToggle(title: "制表符", isOn: $settings.invisibles.tabs)
                                LitePadToggle(title: "空格", isOn: $settings.invisibles.spaces)
                            }
                            .padding(.leading, 18)
                            HStack(spacing: 14) {
                                LitePadToggle(title: "其他空白字符",
                                              isOn: $settings.invisibles.otherWhitespace)
                                LitePadToggle(title: "其他控制字符",
                                              isOn: $settings.invisibles.otherControl)
                            }
                            .padding(.leading, 18)
                        }
                    }
                    LitePadToggle(title: "缩进指示", isOn: $settings.showIndentGuides)
                    HStack(spacing: 6) {
                        LitePadToggle(title: "列位置页面指示：",
                                      isOn: $settings.pageGuideEnabled)
                        TextField("", value: $settings.pageGuideColumn, format: .number)
                            .textFieldStyle(.plain)
                            .settingsFieldFrame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .disabled(!settings.pageGuideEnabled)
                    }
                    .padding(.leading, 18)
                }
            }
            SettingsRow("当前行：") {
                LitePadToggle(title: "改变背景颜色", isOn: $settings.highlightCurrentLine)
            }
            SettingsDivider()
            SettingsRow("缩进：") {
                VStack(alignment: .leading, spacing: 6) {
                    LitePadToggle(title: "Tab 键插入空格", isOn: $settings.insertSpacesForTab)
                    HStack(spacing: 6) {
                        Text("缩进宽度：")
                        TextField("", value: $settings.indentWidth, format: .number)
                            .textFieldStyle(.plain)
                            .settingsFieldFrame(width: 52)
                            .multilineTextAlignment(.trailing)
                        SettingsStepper(onIncrement: { bumpIndentWidth(1) },
                                        onDecrement: { bumpIndentWidth(-1) })
                        Text("个字符").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 18)
                }
            }
            SettingsDivider()
            SettingsRow("换行：") {
                VStack(alignment: .leading, spacing: 6) {
                    LitePadToggle(title: "换行以适合编辑器宽度", isOn: $settings.wrapLines)
                    HStack(spacing: 6) {
                        LitePadToggle(title: "自动换行缩进字符数：",
                                      isOn: $settings.wrapIndentEnabled)
                            .disabled(!settings.wrapLines)
                        TextField("", value: $settings.wrapIndentChars, format: .number)
                            .textFieldStyle(.plain)
                            .settingsFieldFrame(width: 52)
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
                        .textFieldStyle(.plain)
                        .settingsFieldFrame(width: 70)
                        .multilineTextAlignment(.trailing)
                    SettingsStepper(onIncrement: { bumpExtraScroll(5) },
                                    onDecrement: { bumpExtraScroll(-5) })
                    Text("%").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsDivider()
            SettingsRow("状态栏显示：") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        LitePadToggle(title: "行数", isOn: $settings.statusBarLineCount)
                        LitePadToggle(title: "位置", isOn: $settings.statusBarCaretOffset)
                    }
                    HStack(spacing: 16) {
                        LitePadToggle(title: "字符数", isOn: $settings.statusBarCharCount)
                        LitePadToggle(title: "当前行", isOn: $settings.statusBarCaretLine)
                    }
                    HStack(spacing: 16) {
                        LitePadToggle(title: "字数", isOn: $settings.statusBarWordCount)
                        LitePadToggle(title: "当前列", isOn: $settings.statusBarCaretColumn)
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                    LitePadToggle(title: "选区", isOn: $settings.statusBarSelectionCount)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sizeField(_ placeholder: String, binding: Binding<String>, caption: String) -> some View {
        VStack(spacing: 2) {
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain)
                .settingsFieldFrame(width: 80)
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

    /// 缩进宽度收敛到可配置区间：输入框可以填任意整数，微调按钮落在区间内
    private func bumpIndentWidth(_ delta: Int) {
        settings.indentWidth = IndentRules.clampedWidth(settings.indentWidth + delta)
    }
}

// MARK: - 格式

private struct FormatSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var popups: SettingsPopupState
    /// 本机 CommandLineTools 工具链缺少 SwiftUI 宏插件（@State 不可用），临时 UI 状态用 @StateObject 承载
    @StateObject private var sheet = SheetToggle()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsRow("默认行尾：") {
                SettingsPicker(title: "默认行尾",
                               selection: $settings.defaultLineEnding,
                               options: LineEnding.allCases,
                               label: lineEndingName,
                               width: 240,
                               popups: popups)
            }
            SettingsDivider()
            SettingsRow("默认文本编码：") {
                SettingsPicker(title: "默认文本编码",
                               selection: $settings.defaultEncoding,
                               options: TextEncoding.allCases,
                               label: \.displayName,
                               width: 260,
                               popups: popups)
            }
            SettingsRow("编码优先级：") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("编辑列表…") { sheet.isPresented = true }
                        .buttonStyle(PanelActionButtonStyle(tone: .neutral))
                    LitePadToggle(title: "参考文稿中的编码声明",
                                  isOn: $settings.respectCharsetDeclaration)
                }
            }
            SettingsDivider()
            SettingsRow("默认语法：") {
                SettingsPicker(title: "默认语法",
                               selection: Binding<LanguageDefinition>(
                                   get: { settings.defaultLanguage },
                                   set: { settings.setDefaultLanguage($0) }
                               ),
                               options: LanguageDefinition.all,
                               label: \.displayName,
                               width: 260,
                               popups: popups)
            }
        }
        .padding(.vertical, 2)
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
    static let coordinateSpace = "encodingPrioritySheet"

    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    /// 本机工具链 @State 不可用，临时选中状态用 @StateObject 承载
    @StateObject private var state = SelectionState()
    /// 面板自带一份弹层宿主：这张表是独立窗口，不与设置抽屉共用坐标空间
    @StateObject private var popups = SettingsPopupState(space: EncodingPrioritySheet.coordinateSpace)

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
                SettingsSelectionList(options: settings.encodingPriority,
                                      selection: $state.selection,
                                      title: "编码优先级",
                                      label: \.displayName,
                                      width: 300,
                                      height: 190)
                VStack(spacing: 8) {
                    listButton("上移", "chevron.up") { move(-1) }
                    listButton("下移", "chevron.down") { move(1) }
                    listButton("移除", "minus") { remove() }
                }
                .padding(.top, 4)
            }
            HStack {
                SettingsPicker(title: "添加编码",
                               selection: addBinding,
                               options: remainingCandidates,
                               label: \.displayName,
                               width: 320,
                               popups: popups)
                Button("添加") {
                    settings.updateEncodingPriority(settings.encodingPriority + [addBinding.wrappedValue])
                }
                .buttonStyle(PanelActionButtonStyle(tone: .accent))
                .disabled(remainingCandidates.isEmpty)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PanelActionButtonStyle(tone: .accent))
            }
        }
        .padding(20)
        .frame(width: 460)
        // 表底这一行离窗口下缘太近，弹层放不下就向上开（见 SettingsPopupLayer）
        .settingsPopupHost(popups)
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
        .buttonStyle(PanelActionButtonStyle(tone: .neutral))
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
                .frame(width: 128, alignment: .trailing)
                .multilineTextAlignment(.trailing)
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
    @StateObject private var hover = SettingsIndexHoverState()

    var body: some View {
        HStack(spacing: 16) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: selection == option ? "circle.inset.filled" : "circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selection == option
                                             ? InterfaceStyle.accent
                                             : InterfaceStyle.muted)
                        Text(label(option))
                    }
                    .font(.system(size: 12, weight: selection == option ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == option
                                  ? InterfaceStyle.accentSoft
                                  : (hover.index == index ? InterfaceStyle.raised : Color.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(selection == option
                                          ? InterfaceStyle.accentBorder
                                          : Color.clear,
                                          lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover.index = $0 ? index : nil }
            }
        }
    }
}
