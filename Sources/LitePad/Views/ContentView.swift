import SwiftUI
import AppKit

/// 状态栏弹出面板的种类
enum StatusBarMenuKind {
    case encoding
    case lineEnding
    case language
}

/// 主界面：标签栏 + 编辑区 + 状态栏
struct ContentView: View {
    @EnvironmentObject private var session: EditorSession

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                TabBarView()
                if let tab = session.selectedTab {
                    // 切换标签时以 id 重建编辑器，避免不同标签间文本与选区串扰
                    CodeTextView(tab: tab)
                        .id(tab.id)
                        // 查找面板挂编辑区右上；FindPanelHost 自行观察 tab 的 findState
                        .overlay(alignment: .topTrailing) {
                            FindPanelHost(tab: tab)
                        }
                } else {
                    emptyView
                }
                statusBar(for: session.selectedTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 窗口标题跟随当前标签（ContentView 不观察 EditorTab，脏状态刷新由独立视图承担）
            if let tab = session.selectedTab {
                WindowTitleSync(tab: tab)
            }

            if session.expandedMenu != nil {
                // 覆盖全窗口的透明点击层：光标为箭头，点面板外任意位置收起面板
                DismissLayer(onClose: { session.expandedMenu = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let kind = session.expandedMenu, let tab = session.selectedTab {
                // 原生容器声明箭头光标，内部承载面板内容
                PanelCursorContainer(content: menuPanel(for: kind, tab: tab))
                    .fixedSize()
                    .padding(.trailing, 8)
                    .padding(.bottom, 30)
            }
        }
    }

    /// 右下角的选项面板：绘制在窗口坐标系内（右缘贴窗口右缘、底边贴状态栏上方），永不超出 App；
    /// 各面板只提供标题/选项/当前项/业务赋值，悬停清理与收起面板统一在此收尾
    private func menuPanel(for kind: StatusBarMenuKind, tab: EditorTab) -> OptionPanel {
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
        }
        return OptionPanel(title: option.title,
                           options: option.options,
                           selectedIndex: option.selectedIndex,
                           hoveredIndex: session.hoveredPanelIndex,
                           onSelect: { index in
                               option.commit(index)
                               session.hoveredPanelIndex = nil
                               session.expandedMenu = nil
                           },
                           onHover: { session.hoveredPanelIndex = $0 })
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
                .background(Color(nsColor: .windowBackgroundColor))
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
    let onOpen: (StatusBarMenuKind) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("行：\(tab.stats.totalLines)")
            Text("字符：\(tab.stats.characterCount)")
            Text("字：\(tab.stats.wordCount)")
            Text("位置：\(tab.stats.caretOffset)")
            Text("行：\(tab.stats.caretLine)")
            Text("列：\(tab.stats.caretColumn)")
            Spacer()
            Text(tab.isDirty ? "未保存" : "-")
            StatusBarMenu(label: tab.language.displayName, onOpen: { onOpen(.language) })
            StatusBarMenu(label: tab.encoding.displayName, onOpen: { onOpen(.encoding) })
            StatusBarMenu(label: tab.lineEnding.displayName, onOpen: { onOpen(.lineEnding) })
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
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
            .foregroundColor: NSColor.secondaryLabelColor,
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
        labelAttributed.map { NSSize(width: $0.size().width + 4, height: $0.size().height + 2) }
            ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        labelAttributed?.draw(at: NSPoint(x: 2, y: (bounds.height - (labelAttributed?.size().height ?? 0)) / 2))
    }

    override func mouseUp(with event: NSEvent) {
        onOpen?()
    }
}

/// 窗口内绘制的选项面板：文字 11pt 灰色与状态栏一致，当前项带勾选标记，悬停行高亮；
/// 由 ContentView 定位在状态栏上方、窗口右缘内侧，永不超出 App
private struct OptionPanel: View {
    let title: String
    let options: [String]
    let selectedIndex: Int?
    let hoveredIndex: Int?
    let onSelect: (Int) -> Void
    let onHover: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            ForEach(options.indices, id: \.self) { index in
                Button {
                    onSelect(index)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(index == selectedIndex ? 1 : 0)
                        Text(options[index])
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(hoveredIndex == index ? 0.18 : 0))
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        onHover(hovering ? index : nil)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 200, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(ArrowCursorOverlay())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

/// 覆盖在面板最上层的透明视图：强制箭头光标。
/// SwiftUI 文本内容会注册 I-beam 光标区域且比祖先视图的光标矩形更优先，
/// 所以必须在顶层再盖一层：不拦截点击（hitTest 返回 nil），
/// 并通过 cursorUpdate / mouseMoved 事件持续把光标设回箭头
private struct ArrowCursorOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> ArrowCursorNSView { ArrowCursorNSView() }
    func updateNSView(_ view: ArrowCursorNSView, context: Context) {}
}

private final class ArrowCursorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// 面板的原生容器：声明箭头光标（SwiftUI 内容本身不参与光标管理，
/// 否则会保持下层编辑器的 I-beam 竖线光标），内部用 NSHostingView 承载面板内容
private struct PanelCursorContainer: NSViewRepresentable {
    let content: OptionPanel

    func makeNSView(context: Context) -> PanelCursorNSView {
        let container = PanelCursorNSView()
        install(content: content, in: container)
        return container
    }

    func updateNSView(_ view: PanelCursorNSView, context: Context) {
        install(content: content, in: view)
    }

    private func install(content: OptionPanel, in container: PanelCursorNSView) {
        if let hosting = container.subviews.first as? NSHostingView<OptionPanel> {
            hosting.rootView = content
        } else {
            let hosting = NSHostingView(rootView: content)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
    }
}

private final class PanelCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// 面板展开时覆盖全窗口的点击层：光标为箭头，点击任意位置收起面板
private struct DismissLayer: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> DismissCursorNSView {
        let view = DismissCursorNSView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: DismissCursorNSView, context: Context) {
        view.onClose = onClose
    }
}

private final class DismissCursorNSView: NSView {
    var onClose: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        onClose?()
    }
}
