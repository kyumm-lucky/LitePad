import SwiftUI
import AppKit

/// 窗口内弹出面板的种类：状态栏三项在右下，工具下拉在右上（标签栏扳手按钮下方）
enum WindowMenuKind {
    case encoding
    case lineEnding
    case language
    case tools
}

/// 主界面：标签栏 + 编辑区 + 状态栏；工具抽屉贴窗口右缘，打开时从右向左滑入并挤窄主栏
struct ContentView: View {
    @EnvironmentObject private var session: EditorSession
    @ObservedObject private var settings = AppSettings.shared
    /// 内容区宽度：抽屉宽度上限与拖拽夹取用（本工程无 @State 宏，测量值用轻量对象承载）
    @StateObject private var metrics = LayoutMetrics()
    /// 主栏投放目标的悬停状态（同上，用轻量对象承载）
    @StateObject private var dropState = FileDropState()
    /// 抽屉打开时给编辑区留出的最小宽度
    private static let editorMinWidth: CGFloat = 320

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WindowSizeSync()
            HStack(spacing: 0) {
                mainColumn
                if let tab = session.selectedTab, session.activeTool != nil {
                    ToolsDrawer(tools: session.tools,
                                tab: tab,
                                width: drawerWidth,
                                onResize: { session.resizeToolsDrawer(to: clampedDrawerWidth($0)) },
                                onResizeCommit: { session.commitToolsDrawerWidth() })
                        .transition(Motion.slideTransition(from: .trailing))
                }
            }
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { metrics.width = proxy.size.width }
                    .onChange(of: proxy.size.width) { metrics.width = $0 }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FrostedSurface(shape: Rectangle()))

            // 窗口标题跟随当前标签（ContentView 不观察 EditorTab，脏状态刷新由独立视图承担）
            if let tab = session.selectedTab {
                WindowTitleSync(tab: tab)
            }

            if session.expandedMenu != nil {
                // 覆盖全窗口的透明点击层：光标为箭头，点面板外任意位置收起面板
                DismissLayer(onClose: { session.expandedMenu = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let kind = session.expandedMenu, let tab = session.selectedTab, kind != .tools {
                // 面板贴状态栏右上角；抽屉打开时左移，仍贴着状态栏按钮。
                // 出场动画在 OptionPanel 内部完成：位移或透明度过渡加在宿主外层既不渲染，
                // 还会让宿主每帧重新布局
                menuPanel(for: kind, tab: tab)
                    .fixedSize()
                    .padding(.trailing, 8 + drawerWidth)
                    .padding(.bottom, 30)
            }

            if session.expandedMenu == .tools, let tab = session.selectedTab {
                // 工具下拉：贴窗口右缘、挂在标签栏（34pt）下方；抽屉打开时让到抽屉左侧的扳手处
                menuPanel(for: .tools, tab: tab)
                    .fixedSize()
                    .padding(.trailing, 6 + drawerWidth)
                    .padding(.top, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if session.isSettingsPresented {
                // 设置抽屉从左侧进入；点击抽屉外部收起，避免遮挡后仍可操作编辑器
                DismissLayer(onClose: { session.closeSettings() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(5)

                SettingsView(onClose: { session.closeSettings() })
                    .frame(width: SettingsView.drawerWidth)
                    .frame(maxHeight: .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity,
                           maxHeight: .infinity,
                           alignment: .leading)
                    .transition(Motion.slideTransition(from: .leading))
                    .zIndex(6)
            }
        }
        // 抽屉进出只随工具开关动画；拖拽调宽不触发该值，因而不带缓动、跟手。
        // 键值取 activeTool（而非抽屉宽度）同时覆盖了切换工具时的宽度变化，
        // 以及抽屉开合时下拉面板的让位位移，三者共用同一条曲线
        .animation(Motion.drawer, value: session.activeTool)
        .animation(Motion.drawer, value: session.isSettingsPresented)
        // 面板 / 抽屉开关会改变指针下的区域，但指针不动时不会产生鼠标事件，
        // 这里主动重算一次光标（见 CursorArbiter.swift）
        .onChange(of: session.activeTool) { _ in CursorArbiter.shared.refresh() }
        .onChange(of: session.isSettingsPresented) { _ in CursorArbiter.shared.refresh() }
        .onChange(of: session.expandedMenu) { _ in CursorArbiter.shared.refresh() }
    }

    /// 主栏：标签栏 + 编辑区 + 状态栏，右侧给工具抽屉腾出宽度
    private var mainColumn: some View {
        VStack(spacing: 0) {
            TabBarView()
            if let tab = session.selectedTab {
                // 切换标签时以 id 重建编辑器，避免不同标签间文本与选区串扰
                CodeTextView(tab: tab, session: session)
                    .id(tab.id)
                    // 查找面板挂编辑区右上；工具抽屉打开时正好落在抽屉左侧
                    .overlay(alignment: .topTrailing) {
                        FindPanelHost(tab: tab)
                    }
            } else {
                emptyView
            }
            statusBar(for: session.selectedTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            // 拖到窗口任意位置的另一半：编辑区由编辑视图在 AppKit 层接管（落在文字区的投放
            // 会被可编辑文本视图先消费），标签栏与状态栏这两处没有投放目标，由主栏外层接住。
            // 两层共用同一种接收提示，亮起的范围就是实际可投放的范围
            .dropDestination(for: URL.self) { urls, _ in
                session.openDroppedFiles(urls)
                return true
            } isTargeted: { targeted in
                dropState.isTargeted = targeted
            }
            .overlay { dropHighlight }
    }

    /// 文件拖入时的接收提示：整片可投放区一起亮（编辑区与主栏各上报自己的悬停状态，
    /// 显示取两者的并集，任一处悬停都不会漏提示）
    @ViewBuilder
    private var dropHighlight: some View {
        if session.isFileDropTargeted || dropState.isTargeted {
            ZStack {
                InterfaceStyle.accent.opacity(0.08)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(InterfaceStyle.accentBorder, lineWidth: 2)
                    .padding(2)
            }
            .allowsHitTesting(false)
        }
    }

    /// 抽屉当前生效宽度；关闭时为 0（下拉面板据此避让）
    private var drawerWidth: CGFloat {
        session.activeTool == nil ? 0 : clampedDrawerWidth(session.toolsDrawerWidth)
    }

    /// 抽屉宽度夹取：下限保证控件与对比两栏排得下，上限给编辑区留出空间；
    /// 窗口尺寸尚未测到时只夹下限，避免抽屉刚打开就被压到最小值
    private func clampedDrawerWidth(_ width: CGFloat) -> CGFloat {
        let minimum = CGFloat(AppSettings.toolsPanelMinWidth)
        guard metrics.width > 0 else { return max(width, minimum) }
        return min(max(width, minimum), max(minimum, metrics.width - Self.editorMinWidth))
    }

    /// 选项面板内容：状态栏三项在右下角、工具下拉在右上角，位置由 body 统一指定；
    /// 各面板只提供标题/选项/当前项/业务赋值，悬停清理与收起面板统一在此收尾
    private func menuPanel(for kind: WindowMenuKind, tab: EditorTab) -> OptionPanel {
        let option: (title: String, options: [String], selectedIndex: Int?, commit: (Int) -> Void)
        switch kind {
        case .encoding:
            option = (title: "文本编码",
                      options: TextEncoding.allCases.map(\.displayName),
                      selectedIndex: TextEncoding.allCases.firstIndex(of: tab.encoding),
                      commit: { index in tab.encoding = TextEncoding.allCases[index] })
        case .lineEnding:
            option = (title: "换行符",
                      options: LineEnding.allCases.map(\.displayName),
                      selectedIndex: LineEnding.allCases.firstIndex(of: tab.lineEnding),
                      commit: { index in tab.lineEnding = LineEnding.allCases[index] })
        case .language:
            option = (title: "语言",
                      options: LanguageDefinition.all.map(\.displayName),
                      selectedIndex: LanguageDefinition.all.firstIndex(of: tab.language),
                      commit: { index in tab.language = LanguageDefinition.all[index] })
        case .tools:
            option = (title: "工具",
                      options: TextToolKind.allCases.map(\.displayName),
                      selectedIndex: session.activeTool.flatMap { TextToolKind.allCases.firstIndex(of: $0) },
                      commit: { index in session.openTool(TextToolKind.allCases[index]) })
        }
        // 编码面板多一条底部动作：上面的选项只改保存编码，这一项才真的按它重读磁盘正文（R5）。
        // 未标题标签没有文件可读，动作置灰
        let action: PanelAction? = kind == .encoding
            ? PanelAction(title: "按此编码重新载入",
                          detail: "选项只改保存编码，此项按它重读磁盘正文",
                          isEnabled: tab.fileURL != nil,
                          perform: {
                              // 与选项行同一收尾：动作发出后立刻收起面板，
                              // 重读的三键确认与失败报错都在面板之外发生
                              session.hoveredPanelIndex = nil
                              session.expandedMenu = nil
                              session.reloadSelectedTab(with: tab.encoding)
                          })
            : nil
        return OptionPanel(title: option.title,
                           options: option.options,
                           selectedIndex: option.selectedIndex,
                           hoveredIndex: session.hoveredPanelIndex,
                           // 工具下拉挂在标签栏下方，自上方落下；状态栏面板自下方升起
                           revealOffset: kind == .tools ? -6 : 6,
                           onSelect: { index in
                               option.commit(index)
                               session.hoveredPanelIndex = nil
                               session.expandedMenu = nil
                           },
                           onHover: { session.hoveredPanelIndex = $0 },
                           optionSymbols: kind == .tools
                               ? TextToolKind.allCases.map(\.symbolName)
                               : nil,
                           action: action)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("没有打开的标签页")
                .foregroundStyle(.secondary)
            Button("新建标签页") { session.newTab() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FrostedSurface(shape: Rectangle()))
    }

    @ViewBuilder
    private func statusBar(for tab: EditorTab?) -> some View {
        if let tab {
            // 独立视图持有 @ObservedObject，保证脏标记 / 语言变化实时刷新
            StatusBarView(tab: tab, onOpen: { session.expandedMenu = $0 })
        } else {
            Text("-")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BarBackground(style: settings.statusBarStyle))
        }
    }
}

/// 内容区宽度的测量结果：抽屉宽度上限与拖拽夹取用（本工程无 @State 宏，测量值用轻量对象承载）
private final class LayoutMetrics: ObservableObject {
    @Published var width: CGFloat = 0
}

/// 主栏投放目标的悬停状态（本工程无 @State 宏，用轻量对象承载）
private final class FileDropState: ObservableObject {
    @Published var isTargeted = false
}

/// 启动时按设置应用固定窗口大小（仅新窗口出现时生效一次；空值表示自动）
private struct WindowSizeSync: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard settings.windowWidth != nil || settings.windowHeight != nil,
                      let window = NSApp.keyWindow else { return }
                guard let contentView = window.contentView else { return }
                var size = contentView.frame.size
                if let width = settings.windowWidth {
                    size.width = CGFloat(max(200, width))
                }
                if let height = settings.windowHeight {
                    size.height = CGFloat(max(200, height))
                }
                window.setContentSize(size)
            }
    }
}

/// 窗口标题跟随当前文件名与脏状态：脏标记变化只有直接观察 EditorTab 才能感知，
/// 所以独立成视图；SwiftUI navigationTitle 在 WindowGroup 场景行为随版本有差异，
/// 这里直接同步 NSWindow.title，保证标题确定生效
private struct WindowTitleSync: View {
    @ObservedObject var tab: EditorTab

    private var title: String {
        tab.displayName + (tab.isDirty ? " — 已编辑" : "")
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: title) { NSApp.keyWindow?.title = $0 }
            .onAppear { NSApp.keyWindow?.title = title }
    }
}

private struct StatusBarView: View {
    @ObservedObject var tab: EditorTab
    @ObservedObject private var settings = AppSettings.shared
    let onOpen: (WindowMenuKind) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if settings.statusBarLineCount {
                Text("行：\(tab.stats.totalLines)")
            }
            if settings.statusBarCharCount {
                Text("字符：\(tab.stats.characterCount)")
            }
            if settings.statusBarWordCount {
                Text("字：\(tab.stats.wordCount)")
            }
            if settings.statusBarCaretOffset {
                Text("位置：\(tab.stats.caretOffset)")
            }
            if settings.statusBarCaretLine {
                Text("行：\(tab.stats.caretLine)")
            }
            if settings.statusBarCaretColumn {
                Text("列：\(tab.stats.caretColumn)")
            }
            Spacer()
            Text(tab.isDirty ? "未保存" : "-")
            StatusBarMenu(label: tab.language.displayName, onOpen: { onOpen(.language) })
            StatusBarMenu(label: tab.encoding.displayName, onOpen: { onOpen(.encoding) })
            StatusBarMenu(label: tab.lineEnding.displayName, onOpen: { onOpen(.lineEnding) })
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(InterfaceStyle.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(BarBackground(style: settings.statusBarStyle))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(InterfaceStyle.borderStrong)
                .frame(height: 1)
        }
    }
}

/// 状态栏下拉按钮：原生 NSView 自绘（11pt 灰色文字 + 小箭头，与状态栏一致），点击通知 SwiftUI 展开面板
private struct StatusBarMenu: View {
    let label: String
    let onOpen: () -> Void

    var body: some View {
        MenuButtonNSViewRepresentable(label: label, onOpen: onOpen)
            .fixedSize()
    }
}

private struct MenuButtonNSViewRepresentable: NSViewRepresentable {
    let label: String
    let onOpen: () -> Void

    func makeNSView(context: Context) -> MenuButtonNSView {
        let view = MenuButtonNSView()
        view.update(label: label, onOpen: onOpen)
        return view
    }

    func updateNSView(_ view: MenuButtonNSView, context: Context) {
        view.update(label: label, onOpen: onOpen)
    }
}

/// 下拉按钮的原生实现
private final class MenuButtonNSView: NSView {
    private var label = ""
    private var onOpen: (() -> Void)?
    private var labelAttributed: NSAttributedString?
    private var isHovered = false

    func update(label: String, onOpen: @escaping () -> Void) {
        let labelChanged = label != self.label
        self.label = label
        self.onOpen = onOpen
        if labelChanged || labelAttributed == nil {
            rebuildLabel()
        }
    }

    /// 重建按钮文字（11pt 灰色，与状态栏一致，末尾内联小箭头）
    private func rebuildLabel() {
        let text = NSMutableAttributedString(string: label + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
        if let chevronImage = NSImage(systemSymbolName: "chevron.up.chevron.down",
                                      accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold)) {
            let chevronAttachment = NSTextAttachment()
            chevronAttachment.image = chevronImage
            text.append(NSAttributedString(attachment: chevronAttachment))
        }
        labelAttributed = text
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        labelAttributed.map { NSSize(width: $0.size().width + 16, height: max($0.size().height + 8, 24)) }
            ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        let background = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        labelAttributed?.draw(at: NSPoint(x: 8,
                                          y: (bounds.height - (labelAttributed?.size().height ?? 0)) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildLabel()
    }

    override func mouseUp(with event: NSEvent) {
        onOpen?()
    }
}
