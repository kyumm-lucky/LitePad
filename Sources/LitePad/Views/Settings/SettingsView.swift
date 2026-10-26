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
        case .general: return L10n.t("通用")
        case .appearance: return L10n.t("外观")
        case .window: return L10n.t("编辑器")
        case .format: return L10n.t("格式")
        }
    }

    /// 页头副标题：承接原侧栏项的第二行文字，侧栏因此只留一行标签
    var subtitle: String {
        switch self {
        case .general: return L10n.t("启动与保存")
        case .appearance: return L10n.t("字体与主题")
        case .window: return L10n.t("显示与排版")
        case .format: return L10n.t("编码与语法")
        }
    }

    /// 侧栏图标：14 × 14、单色说明灰，不做彩色圆底
    var icon: String {
        switch self {
        case .general: return "square.grid.2x2"
        case .appearance: return "circle.lefthalf.filled"
        case .window: return "text.alignleft"
        case .format: return "doc.text"
        }
    }
}

private final class SettingsNavigationState: ObservableObject {
    @Published var section: SettingsSection = .general
}

/// 内容滚动位置：页头底边只在内容滚起来之后才出现分隔线（与设计稿的 is-scrolled 一致）
private final class SettingsScrollState: ObservableObject {
    @Published var isScrolled = false
}

/// 主窗口左侧设置抽屉：分组导航固定在左侧，具体选项在右侧滚动查看。
/// 视觉口径为 macOS 系统设置式极简：纯窗口底 + 一层分组卡片 + 发丝线 + 单一强调色
struct SettingsView: View {
    static let drawerWidth: CGFloat = 660
    /// 详情区坐标空间：下拉锚点与弹层同用一处，弹层才能按锚点摆对位置
    static let detailCoordinateSpace = "settingsDetail"
    /// 内容滚动区的坐标空间：只为测量「滚起来没有」
    private static let scrollCoordinateSpace = "settingsScroll"

    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var navigation = SettingsNavigationState()
    @StateObject private var popups = SettingsPopupState(space: SettingsView.detailCoordinateSpace)
    @StateObject private var closeHover = InterfaceHoverState()
    @StateObject private var sidebarHover = SettingsIndexHoverState()
    @StateObject private var scroll = SettingsScrollState()

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(SettingsStyle.separator)
                .frame(width: 0.5)
            detail
        }
        .frame(width: Self.drawerWidth)
        .frame(maxHeight: .infinity)
        .background(SettingsStyle.window)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 抽屉浮在编辑区上，只有浮层给阴影；不再做磨砂材质与边光高光
        .shadow(color: SettingsStyle.drawerShadow, radius: 18, y: 4)
        .onChange(of: settings.appearanceMode) { _ in settings.applyAppearance() }
        // 换页时原页面连同按钮一起消失，弹层留在宿主顶层不会自己收，这里显式收掉
        .onChange(of: navigation.section) { _ in popups.dismiss() }
        // 「启动动作」行随父开关隐藏时同理：触发按钮已经不在了，不能把弹层留在半空
        .onChange(of: settings.restoreSessionOnLaunch) { _ in popups.dismiss() }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("设置"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsStyle.text)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 16)

            Text(L10n.t("工作区配置"))
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(SettingsStyle.text2)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    sidebarItem(section, index: index(of: section))
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 1) {
                Text("LitePad")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsStyle.text)
                Text(L10n.t("原生文本工作台"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsStyle.text2)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsStyle.sidebar)
    }

    private func index(of section: SettingsSection) -> Int {
        SettingsSection.allCases.firstIndex(of: section) ?? 0
    }

    private func sidebarItem(_ section: SettingsSection, index: Int) -> some View {
        let isActive = navigation.section == section
        return Button {
            withAnimation(Motion.settingsPane) {
                navigation.section = section
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(SettingsStyle.text2)
                Text(section.title)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(SettingsStyle.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: SettingsMetrics.sidebarItemHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.sidebarItemRadius, style: .continuous)
                    .fill(isActive
                          ? SettingsStyle.selectionStrong
                          : (sidebarHover.index == index ? SettingsStyle.selection : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.control, value: sidebarHover.index)
        .onHover { sidebarHover.index = $0 ? index : nil }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - 详情

    private var detail: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                currentPane
                    .padding(EdgeInsets(top: SettingsMetrics.contentTop,
                                        leading: SettingsMetrics.contentSide,
                                        bottom: SettingsMetrics.contentBottom,
                                        trailing: SettingsMetrics.contentSide))
                    // 首组距页头再多 6（设计稿 .group:first-child 的 margin-top）
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { syncScrolled(proxy.frame(in: .named(Self.scrollCoordinateSpace)).minY) }
                                .onChange(of: proxy.frame(in: .named(Self.scrollCoordinateSpace)).minY) {
                                    syncScrolled($0)
                                }
                        }
                    )
                    // 换页时整页替换：新页淡入 + 上移 4pt，旧页不参与动画
                    .id(navigation.section)
                    .transition(Motion.settingsPaneTransition)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpace)
        }
        .frame(maxHeight: .infinity)
        // 弹层挂在滚动视图之外：滚动内容裁不到它，页内顺序也压不住它
        .settingsPopupHost(popups)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(navigation.section.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsStyle.text)
                Text(navigation.section.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsStyle.text2)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(closeHover.isHovered ? SettingsStyle.text : SettingsStyle.text2)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(closeHover.isHovered ? SettingsStyle.selectionStrong : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { closeHover.isHovered = $0 }
            .help(L10n.t("关闭设置"))
            .accessibilityLabel(L10n.t("关闭设置"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .frame(height: SettingsMetrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SettingsStyle.separator)
                .frame(height: 0.5)
                .opacity(scroll.isScrolled ? 1 : 0)
        }
    }

    private func syncScrolled(_ minY: CGFloat) {
        let scrolled = minY < -0.5
        guard scrolled != scroll.isScrolled else { return }
        scroll.isScrolled = scrolled
    }

    @ViewBuilder
    private var currentPane: some View {
        switch navigation.section {
        case .general:
            GeneralSettingsPane(popups: popups)
        case .appearance:
            AppearanceSettingsPane(popups: popups)
        case .window:
            WindowSettingsPane()
        case .format:
            FormatSettingsPane(popups: popups)
        }
    }
}

// MARK: - 下拉弹层

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

/// 列表内的悬停行；同样不能用 @State。
/// 不设 private：设置页侧栏与 SettingsControls.swift 里的分段控件、侧栏项共用这一个
final class SettingsIndexHoverState: ObservableObject {
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

/// 与状态栏下拉共用 OptionPanel 的设置选择器；面板由宿主（`settingsPopupHost`）渲染。
/// 按钮改成 28 高、单层 0.5 描边、箭头用说明文字灰；弹层定位逻辑不变
private struct SettingsPicker<Option: Hashable & Identifiable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    let width: CGFloat
    @ObservedObject var popups: SettingsPopupState
    @StateObject private var anchor = SettingsAnchorState()
    @StateObject private var hover = InterfaceHoverState()

    private var selectedIndex: Int? {
        options.firstIndex(of: selection)
    }

    private var isOpen: Bool {
        popups.request?.id == title
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Text(label(selection))
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsStyle.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(SettingsStyle.text2)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: SettingsMetrics.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .fill(hover.isHovered || isOpen ? SettingsStyle.controlHover : SettingsStyle.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .strokeBorder(isOpen ? SettingsStyle.accent : SettingsStyle.controlLine,
                                  lineWidth: isOpen ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
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

/// 单位文字：11pt 说明灰，与说明行同一节奏
private struct SettingsUnitText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(SettingsStyle.text2)
            .fixedSize()
    }
}

// MARK: - 通用

private struct GeneralSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var popups: SettingsPopupState
    @StateObject private var sheet = SheetToggle()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup(L10n.t("界面")) {
                SettingsRow(L10n.t("界面语言"), showsDivider: false) {
                    SettingsPicker(title: L10n.t("界面语言"),
                                   selection: $settings.interfaceLanguage,
                                   options: InterfaceLanguage.allCases,
                                   label: \.displayName,
                                   width: 180,
                                   popups: popups)
                }
            }

            SettingsGroup(L10n.t("启动")) {
                SettingsSwitchRow(title: L10n.t("重新打开最后关闭的窗口"),
                                  note: L10n.t("恢复上次的标签、选区与滚动位置。"),
                                  showsDivider: false,
                                  isOn: $settings.restoreSessionOnLaunch)
                // 没有可恢复的文稿时怎么启动，只在恢复会话开启时出现（设计稿 data-reveal）
                if settings.restoreSessionOnLaunch {
                    SettingsRow(L10n.t("没有可恢复的文稿时")) {
                        SettingsPicker(title: L10n.t("启动动作"),
                                       selection: $settings.launchAction,
                                       options: LaunchAction.allCases,
                                       label: \.displayName,
                                       width: 180,
                                       popups: popups)
                    }
                }
            }

            SettingsGroup(L10n.t("保存"),
                          footnote: L10n.t("两项清理只在显式保存（含关闭标签与退出时的确认保存）前执行；自动保存不改动正文。")) {
                SettingsSwitchRow(title: L10n.t("自动保存"),
                                  note: L10n.t("编辑已保存的文件时自动写盘；未标题文稿仍需手动保存。"),
                                  showsDivider: false,
                                  isOn: $settings.autosaveEnabled)
                SettingsSwitchRow(title: L10n.t("保存时删除行尾空白"),
                                  note: L10n.t("只去空格与制表符；会破坏 Markdown 行尾双空格与补丁文件空行。"),
                                  isOn: $settings.trimTrailingWhitespaceOnSave)
                SettingsSwitchRow(title: L10n.t("保存时补齐末尾换行"),
                                  note: L10n.t("在末尾补一个换行；补丁类文件以此为语义。"),
                                  isOn: $settings.ensureFinalNewlineOnSave)
                SettingsRow(L10n.t("例外语法")) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        Text(L10n.format("%d 种", settings.saveCleanupExcludedLanguageIDs.count))
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsStyle.text2)
                        SettingsButton(title: L10n.t("编辑…")) { sheet.isPresented = true }
                    }
                }
                .opacity(settings.saveCleanupEnabled ? 1 : 0.42)
                .disabled(!settings.saveCleanupEnabled)
            }

            SettingsGroup(L10n.t("外部更改")) {
                SettingsRow(L10n.t("文稿被其他应用更改时"), showsDivider: false) {
                    SettingsRadioList(options: ExternalChangeAction.allCases,
                                      selection: $settings.externalChangeAction,
                                      label: \.displayName)
                }
            }
        }
        .sheet(isPresented: $sheet.isPresented) {
            SaveCleanupExclusionSheet(onClose: { sheet.isPresented = false })
        }
    }
}

/// 保存时清理的按语法排除表在 `SaveCleanupExclusionView.swift`

// MARK: - 外观

private struct AppearanceSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var popups: SettingsPopupState

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup(L10n.t("字体")) {
                SettingsRow(L10n.t("等宽字体"), showsDivider: false) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        Text(settings.editorFontDisplayName)
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsStyle.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .trailing)
                        SettingsButton(title: L10n.t("选择…")) { chooseFont() }
                    }
                }
                SettingsRow(L10n.t("字号")) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        Text("\(Int(settings.editorFontSize))")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(SettingsStyle.text)
                            .frame(minWidth: 20, alignment: .trailing)
                        SettingsStepper(onIncrement: { settings.stepEditorFontSize(by: 1) },
                                        onDecrement: { settings.stepEditorFontSize(by: -1) })
                        SettingsUnitText(text: L10n.t("点"))
                    }
                }
                SettingsSwitchRow(title: L10n.t("连字"),
                                  note: L10n.t("为 Fira Code 这类字体启用 → ≠ ≥ 的连字替换。"),
                                  isOn: $settings.ligaturesEnabled)
                SettingsRow(L10n.t("行高")) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        TextField("", value: $settings.lineHeightMultiple,
                                  format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .settingsFieldLook(width: 64)
                        SettingsStepper(onIncrement: { bumpLineHeight(0.1) },
                                        onDecrement: { bumpLineHeight(-0.1) })
                        SettingsUnitText(text: L10n.t("倍"))
                    }
                }
            }

            SettingsGroup(L10n.t("主题")) {
                SettingsRow(L10n.t("外观"), showsDivider: false) {
                    AppearanceTiles(selection: $settings.appearanceMode)
                }
                SettingsRow(L10n.t("语法主题"), note: L10n.t("只作用于代码与标记的高亮配色。")) {
                    SettingsPicker(title: L10n.t("语法主题"),
                                   selection: $settings.syntaxTheme,
                                   options: SyntaxTheme.allCases,
                                   label: \.displayName,
                                   width: 150,
                                   popups: popups)
                }
                SettingsRow(L10n.t("顶栏与状态栏")) {
                    SettingsSegmented(options: StatusBarBackgroundStyle.allCases,
                                      selection: $settings.statusBarStyle,
                                      label: \.displayName)
                }
                SettingsRow(L10n.t("编辑器透明度"), note: L10n.t("100% 时编辑区完全不透明。")) {
                    HStack(spacing: 10) {
                        Slider(value: $settings.editorOpacity, in: 10...100, step: 5)
                            .tint(SettingsStyle.accent)
                            .frame(width: 170)
                        Text("\(Int(settings.editorOpacity))%")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(SettingsStyle.text2)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
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

// MARK: - 编辑器

private struct WindowSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup(L10n.t("窗口")) {
                SettingsRow(L10n.t("窗口大小"), showsDivider: false) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        TextField(L10n.t("自动"), text: widthBinding)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .settingsFieldLook(width: 72)
                        SettingsUnitText(text: "×")
                        TextField(L10n.t("自动"), text: heightBinding)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .settingsFieldLook(width: 72)
                        SettingsUnitText(text: L10n.t("像素"))
                    }
                }
            }

            SettingsGroup(L10n.t("显示")) {
                SettingsSwitchRow(title: L10n.t("行号"),
                                  showsDivider: false,
                                  isOn: $settings.showLineNumbers)
                SettingsSwitchRow(title: L10n.t("不可见元素"),
                                  note: L10n.t("显示空白与换行等不可见字符。"),
                                  isOn: $settings.showInvisibles)
                if settings.showInvisibles {
                    SettingsBlockRow(showsDivider: false, isSubrow: true) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .leading),
                                            GridItem(.flexible(), spacing: 10, alignment: .leading),
                                            GridItem(.flexible(), alignment: .leading)],
                                  alignment: .leading,
                                  spacing: 6) {
                            SettingsCheckbox(title: L10n.t("行尾"), isOn: $settings.invisibles.lineEndings)
                            SettingsCheckbox(title: L10n.t("制表符"), isOn: $settings.invisibles.tabs)
                            SettingsCheckbox(title: L10n.t("空格"), isOn: $settings.invisibles.spaces)
                            SettingsCheckbox(title: L10n.t("其他空白字符"),
                                             isOn: $settings.invisibles.otherWhitespace)
                            SettingsCheckbox(title: L10n.t("其他控制字符"),
                                             isOn: $settings.invisibles.otherControl)
                        }
                    }
                }
                SettingsSwitchRow(title: L10n.t("缩进指示"),
                                  isOn: $settings.showIndentGuides)
                SettingsSwitchRow(title: L10n.t("列位置页面指示"),
                                  isOn: $settings.pageGuideEnabled)
                SettingsRow(L10n.t("页面宽度"), isSubrow: true) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        TextField("", value: $settings.pageGuideColumn, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .settingsFieldLook(width: 64)
                        SettingsUnitText(text: L10n.t("列"))
                    }
                }
                .opacity(settings.pageGuideEnabled ? 1 : 0.42)
                .disabled(!settings.pageGuideEnabled)
                SettingsSwitchRow(title: L10n.t("当前行高亮"),
                                  note: L10n.t("用背景色标出光标所在行。"),
                                  isOn: $settings.highlightCurrentLine)
            }

            SettingsGroup(L10n.t("缩进与换行")) {
                SettingsSwitchRow(title: L10n.t("Tab 键插入空格"),
                                  note: L10n.t("关闭时插入一个制表符，宽度按缩进宽度换算。"),
                                  showsDivider: false,
                                  isOn: $settings.insertSpacesForTab)
                SettingsRow(L10n.t("缩进宽度")) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        TextField("", value: $settings.indentWidth, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .settingsFieldLook(width: 56)
                        SettingsStepper(onIncrement: { settings.stepIndentWidth(by: 1) },
                                        onDecrement: { settings.stepIndentWidth(by: -1) })
                        SettingsUnitText(text: L10n.t("个字符"))
                    }
                }
                SettingsSwitchRow(title: L10n.t("换行以适合编辑器宽度"),
                                  isOn: $settings.wrapLines)
                // 自动换行缩进只在「换行以适合编辑器宽度」开启时出现（设计稿 data-reveal）
                if settings.wrapLines {
                    SettingsRow(L10n.t("自动换行缩进"), isSubrow: true) {
                        HStack(spacing: SettingsMetrics.controlSpacing) {
                            // 「自动换行缩进」的开关：设计稿未列这一项，但设置本身存在，
                            // 与数字同排，整行不承担点击
                            SettingsWrapIndentSwitch(isOn: $settings.wrapIndentEnabled)
                            TextField("", value: $settings.wrapIndentChars, format: .number)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .settingsFieldLook(width: 56)
                                .disabled(!settings.wrapIndentEnabled)
                                .opacity(settings.wrapIndentEnabled ? 1 : 0.42)
                            SettingsStepper(onIncrement: { bumpWrapIndent(1) },
                                            onDecrement: { bumpWrapIndent(-1) })
                                .opacity(settings.wrapIndentEnabled ? 1 : 0.42)
                                .disabled(!settings.wrapIndentEnabled)
                            SettingsUnitText(text: L10n.t("个空格"))
                        }
                    }
                }
                SettingsRow(L10n.t("书写方向")) {
                    SettingsSegmented(options: WritingDirectionOption.allCases,
                                      selection: $settings.writingDirection,
                                      label: \.displayName)
                }
                SettingsRow(L10n.t("额外滚动"), note: L10n.t("在正文末尾保留一段可滚动空白。")) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        TextField("", value: $settings.extraScrollPercent,
                                  format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .settingsFieldLook(width: 64)
                        SettingsStepper(onIncrement: { bumpExtraScroll(5) },
                                        onDecrement: { bumpExtraScroll(-5) })
                        SettingsUnitText(text: "%")
                    }
                }
            }

            SettingsGroup(L10n.t("状态栏")) {
                SettingsBlockRow(showsDivider: false) {
                    SettingsStatusBarGrid()
                }
            }
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

    private func bumpWrapIndent(_ delta: Int) {
        settings.wrapIndentChars = min(16, max(0, settings.wrapIndentChars + delta))
    }
}

/// 子行里的开关：只占一个开关的宽度，点击只切它自己（外层行不承担点击）
private struct SettingsWrapIndentSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Motion.control) { isOn.toggle() }
        } label: {
            SettingsSwitchKnob(isOn: isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("自动换行缩进"))
        .accessibilityValue(isOn ? L10n.t("已开启") : L10n.t("已关闭"))
    }
}

/// 状态栏七项显示开关：两列网格，每个格子整行可点
private struct SettingsStatusBarGrid: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())],
                  alignment: .leading,
                  spacing: 0) {
            cell(L10n.t("行数"), $settings.statusBarLineCount)
            cell(L10n.t("字符数"), $settings.statusBarCharCount)
            cell(L10n.t("字数"), $settings.statusBarWordCount)
            cell(L10n.t("选区"), $settings.statusBarSelectionCount)
            cell(L10n.t("位置"), $settings.statusBarCaretOffset)
            cell(L10n.t("当前行"), $settings.statusBarCaretLine)
            cell(L10n.t("当前列"), $settings.statusBarCaretColumn)
            Color.clear.frame(height: 30)
        }
    }

    private func cell(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(Motion.control) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsStyle.text)
                Spacer(minLength: 0)
                SettingsSwitchKnob(isOn: isOn.wrappedValue)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? L10n.t("已开启") : L10n.t("已关闭"))
        .accessibilityAddTraits(isOn.wrappedValue ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 格式

private struct FormatSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var popups: SettingsPopupState
    /// 本机 CommandLineTools 工具链缺少 SwiftUI 宏插件（@State 不可用），临时 UI 状态用 @StateObject 承载
    @StateObject private var sheet = SheetToggle()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup(L10n.t("新建文稿")) {
                SettingsRow(L10n.t("默认行尾"), showsDivider: false) {
                    SettingsPicker(title: L10n.t("默认行尾"),
                                   selection: $settings.defaultLineEnding,
                                   options: LineEnding.allCases,
                                   label: lineEndingName,
                                   width: 190,
                                   popups: popups)
                }
                SettingsRow(L10n.t("默认文本编码")) {
                    SettingsPicker(title: L10n.t("默认文本编码"),
                                   selection: $settings.defaultEncoding,
                                   options: TextEncoding.allCases,
                                   label: \.displayName,
                                   width: 200,
                                   popups: popups)
                }
                SettingsRow(L10n.t("默认语法")) {
                    SettingsPicker(title: L10n.t("默认语法"),
                                   selection: Binding<LanguageDefinition>(
                                       get: { settings.defaultLanguage },
                                       set: { settings.setDefaultLanguage($0) }
                                   ),
                                   options: LanguageDefinition.all,
                                   label: \.displayName,
                                   width: 190,
                                   popups: popups)
                }
            }

            SettingsGroup(L10n.t("编码探测")) {
                SettingsRow(L10n.t("编码优先级"),
                            note: L10n.t("无 BOM 的文件按顺序尝试解码。"),
                            showsDivider: false) {
                    HStack(spacing: SettingsMetrics.controlSpacing) {
                        Text(encodingSummary)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(SettingsStyle.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 160, alignment: .trailing)
                        SettingsButton(title: L10n.t("编辑列表…")) { sheet.isPresented = true }
                    }
                }
                SettingsSwitchRow(title: L10n.t("参考文稿中的编码声明"),
                                  note: L10n.t("读取 HTML、XML 里的 charset 声明来决定解码。"),
                                  isOn: $settings.respectCharsetDeclaration)
            }
        }
        .sheet(isPresented: $sheet.isPresented) {
            EncodingPrioritySheet(onClose: { sheet.isPresented = false })
        }
    }

    private var encodingSummary: String {
        settings.encodingPriority.map(\.displayName).joined(separator: " › ")
    }

    private func lineEndingName(_ ending: LineEnding) -> String {
        switch ending {
        case .lf: return "macOS / Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr: return L10n.t("经典 Mac (CR)")
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
    private let candidates: [TextEncoding] = [
        .utf8, .gb18030, .big5, .shiftJIS, .eucKR, .latin1,
        .utf16LE, .utf16BE, .utf32LE, .utf32BE
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("无 BOM 的文件按以下顺序依次尝试解码，顺序即优先级。"))
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                EncodingPriorityList(options: settings.encodingPriority,
                                     selection: $state.selection,
                                     title: L10n.t("编码优先级"),
                                     label: \.displayName,
                                     width: 300,
                                     height: 190)
                VStack(spacing: 8) {
                    SettingsButton(title: L10n.t("上移")) { move(-1) }
                    SettingsButton(title: L10n.t("下移")) { move(1) }
                    SettingsButton(title: L10n.t("移除")) { remove() }
                }
                .padding(.top, 4)
            }
            HStack(spacing: SettingsMetrics.controlSpacing) {
                SettingsPicker(title: L10n.t("添加编码"),
                               selection: addBinding,
                               options: remainingCandidates,
                               label: \.displayName,
                               width: 280,
                               popups: popups)
                    // 候选加完时按钮置灰，选择器也要一起禁用：否则还能展开一个只有表头的空面板
                    .disabled(remainingCandidates.isEmpty)
                SettingsButton(title: L10n.t("添加")) {
                    settings.updateEncodingPriority(settings.encodingPriority + [addBinding.wrappedValue])
                }
                .disabled(remainingCandidates.isEmpty)
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                SettingsAccentButton(title: L10n.t("完成"), isDefault: true) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(SettingsStyle.window)
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

/// 编码优先级列表：保留选择、悬停和标题计数，外观走设置页的分组卡片口径
private struct EncodingPriorityList<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option?
    let title: String
    let label: (Option) -> String
    let width: CGFloat
    let height: CGFloat
    @StateObject private var hover = SettingsIndexHoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsStyle.text)
                Spacer(minLength: 0)
                Text("\(options.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(SettingsStyle.text2)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, 10)

            Rectangle()
                .fill(SettingsStyle.separator)
                .frame(height: 0.5)
                .padding(.leading, SettingsMetrics.rowPaddingH)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        Button {
                            selection = option
                        } label: {
                            HStack(spacing: 8) {
                                Text(label(option))
                                    .font(.system(size: 13))
                                    .foregroundStyle(SettingsStyle.text)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, SettingsMetrics.rowPaddingH)
                            .frame(height: 30)
                            .background(selection == option
                                        ? SettingsStyle.selectionStrong
                                        : (hover.index == index ? SettingsStyle.selection : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hover.index = $0 ? index : nil }
                        .accessibilityLabel(label(option))
                        .accessibilityAddTraits(selection == option ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(SettingsStyle.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(SettingsStyle.cardLine, lineWidth: 0.5)
        )
    }
}
