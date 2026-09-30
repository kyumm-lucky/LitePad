import SwiftUI
import AppKit

/// 面板底部的动作行：承载「是一件事、不是当前值」的条目（如编码下拉里的「按此编码重新载入」）。
/// 与选项行共用同一套行样式，但与选中态无关：点它只执行动作，不改面板当前选中的值
struct PanelAction {
    let title: String
    /// 说明文字（小字灰色）：动作只有标题时读起来像又一个选项，这里点明它与上面选项的区别
    let detail: String
    /// 拿不到文件（未标题标签）这类场景置为不可用：置灰且不响应点击与悬停
    let isEnabled: Bool
    let perform: () -> Void
}

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
    /// 底部动作区（默认没有）：与选项区分开、不随选项滚动，高度见 `actionAreaHeight`
    var action: PanelAction? = nil
    /// 出场动画状态。宿主是 NSHostingView，位移与透明度加在容器外层不会渲染，
    /// 只有宿主内部的 SwiftUI 内容能真正动起来，所以淡入做在这里
    @StateObject private var reveal = PanelReveal()

    /// 单行高度与行距：宿主按可用空间换算可视行数时复用同一组数值
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 2
    /// 表头、分隔线与内外边距合计高度。取整偏大，让宿主判断空间时留有余量
    static let chromeHeight: CGFloat = 46
    /// 面板完整展开的高度：宿主据此决定向上还是向下展开。
    /// 只算选项区：当前带底部动作区的面板（状态栏编码下拉）是内联 SwiftUI 视图、自下而上生长，
    /// 不走这套估算；将来若有宿主给带动作的面板估高，需要把动作区高度一并算进来
    static func estimatedHeight(optionCount: Int) -> CGFloat {
        chromeHeight + rowsHeight(optionCount: optionCount)
    }

    static func rowsHeight(optionCount: Int) -> CGFloat {
        guard optionCount > 0 else { return 0 }
        return CGFloat(optionCount) * rowHeight + CGFloat(optionCount - 1) * rowSpacing
    }

    /// 动作行的悬停索引：动作行不是选项，借用「选项数」这个哨兵值进既有的单槽位悬停状态，
    /// 面板内所有行仍然只需要一个 hoveredIndex 就能表达高亮
    private var actionHoverIndex: Int { options.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            header
            divider
            rowsSection
            if let action {
                divider
                actionRow(action)
            }
        }
        .padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background(FrostedSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        // 整块参与命中测试：面板内边距与行距处不漏到下方编辑器（点击与光标都留在面板上）
        .contentShape(Rectangle())
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

    /// 动作行：与选项行同一套行样式（同高、同圆角、同悬停底色），但没有选中态与左侧色条——
    /// 它不是当前值，只是一次动作；标题下的小字点明与上面选项的区别
    private func actionRow(_ action: PanelAction) -> some View {
        Button {
            guard action.isEnabled else { return }
            withAnimation(Motion.control) {
                action.perform()
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(action.isEnabled ? .primary : InterfaceStyle.muted)
                Text(action.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(InterfaceStyle.muted)
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(action.isEnabled && hoveredIndex == actionHoverIndex
                          ? InterfaceStyle.raised : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                // 置灰的动作行不上报悬停：面板里不留一个悬不上的高亮
                guard action.isEnabled else { return }
                onHover(hovering ? actionHoverIndex : nil)
            }
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.55)
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

/// 面板展开时覆盖全窗口的点击层：点击任意位置收起面板（光标由光标仲裁统一改成箭头）
struct DismissLayer: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> DismissClickView {
        let view = DismissClickView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: DismissClickView, context: Context) {
        view.onClose = onClose
    }
}

final class DismissClickView: NSView {
    var onClose: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClose?()
    }
}
