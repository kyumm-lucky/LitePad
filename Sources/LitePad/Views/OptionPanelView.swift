import SwiftUI
import AppKit

/// 窗口内绘制的选项面板：状态栏下拉（右下）、工具下拉（右上）与设置页下拉共用同一套视觉语言——
/// 明确表面、图标/选中态、悬停高亮和展开动效；由调用方定位，永不超出 App
/// （设置页下拉的召唤方见 `SettingsPopupLayer`：按锚点摆放，换不下时改向上展开并限制 maxRowsHeight）
struct OptionPanel: View {
    let title: String
    let options: [String]
    let selectedIndex: Int?
    let hoveredIndex: Int?
    var width: CGFloat = 200
    /// 出场动画的起始纵向位移：挂在按钮下方（工具下拉）用负值自上方落下，状态栏面板用正值自下方升起
    var revealOffset: CGFloat = -6
    let onSelect: (Int) -> Void
    let onHover: (Int?) -> Void
    /// 工具列表传入图标；状态栏菜单不传时继续显示通用选择状态。
    var optionSymbols: [String]? = nil
    /// 选项区高度上限：宿主空间放不下整个面板时只滚动选项，表头与分隔线保持可见
    var maxRowsHeight: CGFloat? = nil
    /// 出场动画状态。宿主是 NSHostingView，位移与透明度加在容器外层不会渲染，
    /// 只有宿主内部的 SwiftUI 内容能真正动起来，所以淡入做在这里
    @StateObject private var reveal = PanelReveal()

    /// 单行高度与行距：宿主按可用空间换算可视行数时复用同一组数值
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 2
    /// 表头、分隔线与内外边距合计高度。取整偏大，让宿主判断空间时留有余量
    static let chromeHeight: CGFloat = 46

    /// 面板完整展开的高度：宿主据此决定向上还是向下展开
    static func estimatedHeight(optionCount: Int) -> CGFloat {
        chromeHeight + rowsHeight(optionCount: optionCount)
    }

    static func rowsHeight(optionCount: Int) -> CGFloat {
        guard optionCount > 0 else { return 0 }
        return CGFloat(optionCount) * rowHeight + CGFloat(optionCount - 1) * rowSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            header
            divider
            rowsSection
        }
        .padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background(FrostedSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        .overlay(ArrowCursorOverlay())
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .opacity(reveal.shown ? 1 : 0)
        .scaleEffect(reveal.shown || Motion.prefersReducedMotion ? 1 : 0.98,
                     anchor: revealOffset < 0 ? .top : .bottom)
        .offset(y: reveal.shown || Motion.prefersReducedMotion ? 0 : revealOffset)
        .animation(Motion.control, value: hoveredIndex)
        .onAppear {
            withAnimation(Motion.panel) { reveal.shown = true }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(InterfaceStyle.accent)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text("\(options.count)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(InterfaceStyle.muted)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(InterfaceStyle.border)
            .frame(height: 1)
            .padding(.horizontal, 8)
    }

    /// 选项区：上限小于自然高度时改为内部滚动，选项再多也够得到
    @ViewBuilder
    private var rowsSection: some View {
        if let maxRowsHeight, maxRowsHeight < Self.rowsHeight(optionCount: options.count) {
            ScrollView(.vertical, showsIndicators: true) {
                rowList
            }
            .frame(height: maxRowsHeight)
        } else {
            rowList
        }
    }

    private var rowList: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(options.indices, id: \.self) { index in
                optionRow(index)
            }
        }
    }

    private func optionRow(_ index: Int) -> some View {
        Button {
            withAnimation(Motion.control) {
                onSelect(index)
            }
        } label: {
            HStack(spacing: 8) {
                if let optionSymbols, optionSymbols.indices.contains(index) {
                    Image(systemName: optionSymbols[index])
                        .font(.system(size: 13, weight: index == selectedIndex ? .semibold : .regular))
                        .foregroundStyle(index == selectedIndex ? InterfaceStyle.accent : InterfaceStyle.muted)
                        .frame(width: 18, height: 18)
                }
                Text(options[index])
                    .font(.system(size: 11, weight: index == selectedIndex ? .medium : .regular))
                    .foregroundStyle(index == selectedIndex ? .primary : InterfaceStyle.muted)
                Spacer(minLength: 0)
            }
            .frame(height: Self.rowHeight)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground(for: index))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(index == selectedIndex ? InterfaceStyle.accentBorder : Color.clear,
                                  lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if index == selectedIndex {
                    Capsule()
                        .fill(InterfaceStyle.accent)
                        .frame(width: 3)
                        .padding(.vertical, 5)
                        .padding(.leading, 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                onHover(hovering ? index : nil)
            }
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(for index: Int) -> Color {
        if index == selectedIndex {
            return InterfaceStyle.accentSoft
        }
        return hoveredIndex == index ? InterfaceStyle.raised : Color.clear
    }
}

/// 面板出场动画的瞬时状态：面板每次展开都是新视图，故初值为「未出现」，
/// onAppear 时置真并借 withAnimation 播一次淡入
private final class PanelReveal: ObservableObject {
    @Published var shown = false
}

/// 覆盖在面板最上层的透明视图：把光标设成箭头。
/// 面板悬浮在编辑器之上，自身没有光标声明的区域（空白内边距、标签、按钮）会漏出下层
/// NSTextView 的 I-beam 竖线光标；SwiftUI 文本注册的光标区域又比祖先视图的优先级更高，
/// 所以必须在顶层再盖一层：不拦截点击（hitTest 返回 nil），
/// 并通过 cursorUpdate / mouseMoved 按位置设定光标。
/// skipRects 为「保持系统光标」的区域（可编辑文本区），传面板自身坐标（左上为原点）
struct ArrowCursorOverlay: NSViewRepresentable {
    var skipRects: [CGRect] = []

    func makeNSView(context: Context) -> ArrowCursorNSView {
        let view = ArrowCursorNSView()
        view.skipRects = skipRects
        return view
    }

    func updateNSView(_ view: ArrowCursorNSView, context: Context) {
        view.skipRects = skipRects
    }
}

final class ArrowCursorNSView: NSView {
    /// 保持系统 I-beam 的可编辑文本区；其余区域一律箭头
    var skipRects: [CGRect] = [] {
        didSet {
            guard skipRects != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            applyCursorAtCurrentMouseLocation()
        }
    }

    /// 用与 SwiftUI 一致的上左原点坐标，skipRects 可直接比较
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        DispatchQueue.main.async { [weak self] in
            self?.applyCursorAtCurrentMouseLocation()
        }
    }

    /// 光标矩形是本层生效的关键：窗口对光标矩形统一裁决，层级最前的视图优先，
    /// 因此本覆盖层声明的箭头压得住下层文本视图（编辑器 NSTextView、SwiftUI 文本）的 I-beam；
    /// 只靠 mouseMoved / cursorUpdate 事件是不够的——窗口默认不投递 mouseMoved，
    /// 事件也不会让已经生效的 I-beam 失效
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        for rect in skipRects {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

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
        applyCursor(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(for: event)
    }

    private func applyCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        applyCursor(at: point)
    }

    private func applyCursorAtCurrentMouseLocation() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        applyCursor(at: point)
    }

    private func applyCursor(at point: NSPoint) {
        if skipRects.contains(where: { $0.contains(point) }) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// 面板的原生容器：声明箭头光标（SwiftUI 内容本身不参与光标管理，
/// 否则会保持下层编辑器的 I-beam 竖线光标），内部用 NSHostingView 承载面板内容
struct PanelCursorContainer: NSViewRepresentable {
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

final class PanelCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard self.bounds.contains(point) else { return }
            NSCursor.arrow.set()
        }
    }
}

/// 面板展开时覆盖全窗口的点击层：光标为箭头，点击任意位置收起面板
struct DismissLayer: NSViewRepresentable {
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

final class DismissCursorNSView: NSView {
    var onClose: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard self.bounds.contains(point) else { return }
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClose?()
    }
}
