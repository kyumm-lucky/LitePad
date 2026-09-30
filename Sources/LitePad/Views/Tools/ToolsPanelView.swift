import SwiftUI
import AppKit

/// 工具抽屉：贴窗口右缘的通栏面板（高度与窗口一致），从右向左滑入，左缘可拖拽调宽。
/// 承载编码转换、JSON 格式化、字符串对比、行操作与哈希 / UUID / 时间戳 / HTML 实体，
/// 输入默认取编辑器选区（无选区取全文），结果可复制或写回编辑器
struct ToolsDrawer: View {
    @ObservedObject var tools: TextToolsState
    @ObservedObject var tab: EditorTab
    /// 当前生效宽度（外层已按窗口宽度夹取）
    let width: CGFloat
    /// 拖拽中的目标宽度
    let onResize: (CGFloat) -> Void
    /// 松手落盘
    let onResizeCommit: () -> Void
    @EnvironmentObject private var session: EditorSession

    var body: some View {
        HStack(spacing: 0) {
            // 调宽把手独占左缘一列：光标覆盖层只盖内容区，把手声明的光标不被压掉
            DrawerResizeHandle(currentWidth: { width },
                               onDrag: onResize,
                               onCommit: onResizeCommit)
                .frame(width: 7)
            content
        }
        .frame(width: width)
        .background(FrostedSurface(shape: Rectangle()))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(InterfaceStyle.borderStrong)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(InterfaceStyle.accent.opacity(0.78))
                .frame(height: 2)
                .allowsHitTesting(false)
        }
        // 投影只朝左：面板从左缘压住编辑区，进出场时把"浮在编辑器之上"的关系交代清楚
        .shadow(color: .black.opacity(0.2), radius: 16, x: -4, y: 0)
        .onExitCommand { session.closeTool() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // 工具切换时整块内容换场：方向由工具在列表中的前后关系决定（见 TextToolsState.select），
            // 旧内容与新内容同向移动，读起来像面板里的一列内容被翻过去
            Group {
                // 三套排布：编码转换与行操作是「输入 → 结果」，对比是 A/B 两栏
                switch tools.kind {
                case .diff:
                    DiffSection(tools: tools, tab: tab)
                case .lines:
                    LineOperationsSection(tools: tools, tab: tab)
                default:
                    ConverterSection(tools: tools, tab: tab)
                }
            }
            .id(tools.kind)
            .transition(Motion.swapTransition(forward: tools.toolSwitchesForward))
            .animation(Motion.content, value: tools.kind)
        }
        .padding(12)
        // 换场位移只发生在面板内部：不裁剪的话内容会滑到编辑区上
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 面板标题行：当前工具名（切换工具走标签栏的扳手下拉）+ 取编辑器文本 + 关闭
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(InterfaceStyle.accentSoft)
                Image(systemName: tools.kind.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(InterfaceStyle.accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tools.kind.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                        .animation(Motion.content, value: tools.kind)
                    Text("文本工作台")
                        .font(.system(size: 9))
                        .foregroundStyle(InterfaceStyle.muted)
                }
            }
            .help("在标签栏右侧的扳手下拉中切换工具")

            Spacer(minLength: 0)

            // UUID 不需要输入，取编辑器对它没有意义
            if tools.kind.requiresInput {
                Button {
                    session.seedToolsFromEditor(tab: tab)
                } label: {
                    Label("取编辑器", systemImage: "arrow.down.doc")
                }
                .buttonStyle(PanelActionButtonStyle(tone: .neutral))
                .help("取编辑器当前选区（无选区时取全文）")
            }

            PanelIconButton(symbol: "xmark", help: "关闭（Esc）") { session.closeTool() }
        }
    }

}

/// 抽屉左缘的调宽把手：原生视图，负责 resizeLeftRight 光标与拖拽换算。
/// 拖拽中只回调实时宽度（驱动布局），松手才回调落盘
private struct DrawerResizeHandle: NSViewRepresentable {
    let currentWidth: () -> CGFloat
    let onDrag: (CGFloat) -> Void
    let onCommit: () -> Void

    func makeNSView(context: Context) -> DrawerResizeNSView {
        let view = DrawerResizeNSView()
        view.attach(currentWidth: currentWidth, onDrag: onDrag, onCommit: onCommit)
        return view
    }

    func updateNSView(_ view: DrawerResizeNSView, context: Context) {
        view.attach(currentWidth: currentWidth, onDrag: onDrag, onCommit: onCommit)
    }
}

private final class DrawerResizeNSView: NSView, CursorDeclaring {
    private var currentWidth: (() -> CGFloat)?
    private var onDrag: ((CGFloat) -> Void)?
    private var onCommit: (() -> Void)?
    /// 拖拽基准：按下瞬间的面板宽度与指针位置
    private var dragStartWidth: CGFloat = 0
    private var dragStartX: CGFloat = 0
    /// 悬停 / 拖拽时左缘亮起的提示条：平时把手只留 resizeLeftRight 光标，靠它提示"这里能拖"
    private let hoverBar = NSView()
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverBar.wantsLayer = true
        hoverBar.alphaValue = 0
        refreshHoverBarColor()
        addSubview(hoverBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DrawerResizeNSView 只由代码创建")
    }

    override func layout() {
        super.layout()
        hoverBar.frame = NSRect(x: (bounds.width - 2) / 2, y: 0, width: 2, height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshHoverBarColor()
    }

    /// 强调色随外观 / 系统设置变化，取色时机只在创建与外观切换时，不逐帧解析
    private func refreshHoverBarColor() {
        hoverBar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
    }

    func attach(currentWidth: @escaping () -> CGFloat,
                onDrag: @escaping (CGFloat) -> Void,
                onCommit: @escaping () -> Void) {
        self.currentWidth = currentWidth
        self.onDrag = onDrag
        self.onCommit = onCommit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self,
                                       userInfo: nil))
    }

    var preferredCursor: NSCursor { .resizeLeftRight }

    override func mouseEntered(with event: NSEvent) {
        setHoverBar(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        setHoverBar(visible: false)
    }

    /// 提示条的淡入淡出交给 AppKit：悬停是高频交互，不值得整块面板重绘
    private func setHoverBar(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            hoverBar.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartWidth = currentWidth?() ?? 0
        dragStartX = event.locationInWindow.x
        isDragging = true
        setHoverBar(visible: true)
    }

    /// 指针向左 = 变宽；越界由外层夹取，指针位置始终与宽度一一对应（回到范围内即恢复跟手）
    override func mouseDragged(with event: NSEvent) {
        // 拖拽中指针常已移出把手的圈定范围，光标在这类事件里自行保持
        NSCursor.resizeLeftRight.set()
        onDrag?(dragStartWidth + (dragStartX - event.locationInWindow.x))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        // 松手时指针多半已不在把手上，按实际位置决定提示条去留
        setHoverBar(visible: bounds.contains(convert(event.locationInWindow, from: nil)))
        onCommit?()
    }
}

/// 输入 → 结果一类的工具：编码转换、JSON 格式化、哈希、UUID、时间戳与 HTML 实体。
/// 方向分段只在有方向档的工具上出现，输入区只在需要输入的工具上出现；
/// 工具专属选项控制转换口径，结果可复制 / 替换编辑器
private struct ConverterSection: View {
    @ObservedObject var tools: TextToolsState
    @ObservedObject var tab: EditorTab
    @EnvironmentObject private var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if tools.kind.hasDirection {
                    LiquidSegmented(labels: tools.kind.directionLabels,
                                    selectedIndex: ConvertDirection.allCases.firstIndex(of: tools.direction) ?? 0,
                                    onSelect: { index in
                                        tools.direction = ConvertDirection.allCases[index]
                                        tools.recompute()
                                    },
                                    segmentWidth: directionSegmentWidth)
                        .transition(.opacity)
                }
                options
                Spacer(minLength: 0)
            }

            // UUID 是凭空生成，没有输入区（取编辑器的文本对它没有意义）
            if tools.kind.requiresInput {
                PanelSectionLabel(title: "输入", detail: inputDetail)
                CodeTextEditor(text: inputBinding, placeholder: "在此输入或粘贴文本")
            }

            PanelSectionLabel(title: "结果", detail: resultDetail,
                              isError: tools.errorMessage != nil)
            PanelResultText(text: tools.errorMessage ?? tools.output,
                            isError: tools.errorMessage != nil)
                // 方向翻转后结果整块换掉，用淡入淡出交代"重算了"；逐键重算不换身份，不会闪
                .id(tools.direction)
                .transition(.opacity)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                CopyButton(text: tools.output)
                Button {
                    session.writeBackToolsResult(tools.output, replaceSelection: true, tab: tab)
                } label: {
                    Label("替换选区", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PanelActionButtonStyle(tone: .neutral))
                .help("替换编辑器当前选区；无选区时插入到光标处")
                Button {
                    session.writeBackToolsResult(tools.output, replaceSelection: false, tab: tab)
                } label: {
                    Label("替换全文", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PanelActionButtonStyle(tone: .accent))
                .help("用结果替换编辑器全文（可 ⌘Z 回滚）")
            }
            .controlSize(.small)
            // 三个按钮都作用于结果区，能不能用只看结果（KTD12）：不需要输入的工具不受输入为空影响
            .disabled(!tools.resultIsUsable)
        }
        // 编码 ⇄ 解码：只有随方向出现或消失的选项、以及换掉的结果需要过渡，输入栏原地不动
        .animation(Motion.control, value: tools.direction)
    }

    /// 工具专属选项：只影响编码方向的选项在解码时不显示，避免误解
    @ViewBuilder
    private var options: some View {
        switch tools.kind {
        case .unicode:
            if tools.direction == .encode {
                LitePadToggle(title: "转义 ASCII",
                              isOn: optionBinding(\.unicodeEscapesASCII),
                              help: "连 ASCII 字符一起转义为 \\uXXXX")
                    .transition(.opacity)
            }
        case .ascii:
            LiquidSegmented(labels: NumericBase.allCases.map(\.displayName),
                            selectedIndex: NumericBase.allCases.firstIndex(of: tools.numericBase) ?? 0,
                            onSelect: { index in
                                tools.numericBase = NumericBase.allCases[index]
                                tools.recompute()
                            },
                            segmentWidth: 58)
        case .url:
            if tools.direction == .encode {
                LitePadToggle(title: "空格转 +",
                              isOn: optionBinding(\.urlSpaceAsPlus),
                              help: "空格编码为 +（表单风格），默认编码为 %20")
                    .transition(.opacity)
            }
        case .base64:
            if tools.direction == .encode {
                LitePadToggle(title: "URL 安全",
                              isOn: optionBinding(\.base64URLSafe),
                              help: "用 - _ 替代 + / 并去掉结尾 =；解码时两种写法都能识别")
                    .transition(.opacity)
            }
        case .json:
            if tools.direction == .encode {
                LiquidSegmented(labels: JSONIndent.allCases.map(\.displayName),
                                selectedIndex: JSONIndent.allCases.firstIndex(of: tools.jsonIndent) ?? 0,
                                onSelect: { index in
                                    tools.jsonIndent = JSONIndent.allCases[index]
                                    tools.recompute()
                                },
                                segmentWidth: 58)
                    .transition(.opacity)
            }
        case .hash:
            LiquidSegmented(labels: HashAlgorithm.allCases.map(\.displayName),
                            selectedIndex: HashAlgorithm.allCases.firstIndex(of: tools.hashAlgorithm) ?? 0,
                            onSelect: { index in
                                tools.hashAlgorithm = HashAlgorithm.allCases[index]
                                tools.recompute()
                            },
                            segmentWidth: 58)
            LitePadToggle(title: "大写",
                          isOn: optionBinding(\.hashUppercase),
                          help: "结果用大写十六进制；默认小写，与系统命令行工具一致")
        case .uuid:
            LitePadToggle(title: "大写",
                          isOn: optionBinding(\.uuidUppercase),
                          help: "标识用大写字母；默认小写")
            Button {
                tools.regenerateUUID()
            } label: {
                Label("重新生成", systemImage: "shuffle")
            }
            .buttonStyle(PanelActionButtonStyle(tone: .neutral))
            .help("换一个 UUID（打开工具时也会换）")
        case .timestamp:
            LiquidSegmented(labels: TimestampUnit.allCases.map(\.displayName),
                            selectedIndex: TimestampUnit.allCases.firstIndex(of: tools.timestampUnit) ?? 0,
                            onSelect: { index in
                                tools.timestampUnit = TimestampUnit.allCases[index]
                                tools.recompute()
                            },
                            segmentWidth: 62)
            Button {
                tools.fillTimestampNow()
            } label: {
                Label("现在", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(PanelActionButtonStyle(tone: .neutral))
            .help("用当前时间填输入栏（按当前方向填时间戳或本地时间）")
        case .html:
            if tools.direction == .encode {
                LitePadToggle(title: "转义非 ASCII",
                              isOn: optionBinding(\.htmlEscapesNonASCII),
                              help: "连中文等非 ASCII 字符一起转为 &#xXXXX;；默认只转义 & < > \" ' 与不换行空格")
                    .transition(.opacity)
            }
        case .diff, .lines:
            // 对比工具走自己的两栏排布，行操作没有工具专属选项
            EmptyView()
        }
    }

    /// 方向分段的单档宽度：时间戳的两档名字更长，需要更宽的档位
    private var directionSegmentWidth: CGFloat {
        tools.kind == .timestamp ? 64 : 54
    }

    /// 输入区与结果区的说明：时间戳按方向提示该输什么 / 会得到什么，其余工具说明来源
    private var inputDetail: String {
        guard tools.kind == .timestamp else { return "编辑器选区 / 全文" }
        return tools.direction == .encode
            ? "Unix 时间戳（\(tools.timestampUnit.displayName)）"
            : "本地时间，如 2024-01-02 03:04:05"
    }

    private var resultDetail: String {
        if tools.errorMessage != nil { return "转换失败" }
        switch tools.kind {
        case .uuid: return "点「重新生成」换一个"
        case .timestamp: return tools.direction == .encode ? "本地时间" : "Unix 时间戳"
        default: return "实时更新"
        }
    }

    private var inputBinding: Binding<String> {
        Binding(get: { tools.input }, set: { tools.updateInput($0) })
    }

    private func optionBinding<T>(_ keyPath: ReferenceWritableKeyPath<TextToolsState, T>) -> Binding<T> {
        Binding(get: { tools[keyPath: keyPath] },
                set: { newValue in
                    tools[keyPath: keyPath] = newValue
                    tools.recompute()
                })
    }
}

/// 字符串对比：A（编辑器选区 / 全文）/ B（手工输入或取其他标签页）→ 差异行列表
private struct DiffSection: View {
    @ObservedObject var tools: TextToolsState
    @ObservedObject var tab: EditorTab
    @EnvironmentObject private var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(otherTabs) { other in
                        Button(other.displayName) { tools.fillDiffRight(from: other.text) }
                    }
                } label: {
                    Label("从标签页取 B", systemImage: "arrow.down.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(InterfaceStyle.raised,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1)
                        )
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .disabled(otherTabs.isEmpty)
                .help("把另一个标签页的全文填入 B 栏")

                LitePadToggle(title: "忽略大小写",
                              isOn: optionBinding(\.diffIgnoreCase))
                LitePadToggle(title: "忽略行首尾空白",
                              isOn: optionBinding(\.diffIgnoreWhitespace))
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    PanelSectionLabel(title: "A", detail: "编辑器选区 / 全文")
                    CodeTextEditor(text: leftBinding, placeholder: "文本 A")
                }
                VStack(alignment: .leading, spacing: 3) {
                    PanelSectionLabel(title: "B", detail: "手动输入")
                    CodeTextEditor(text: rightBinding, placeholder: "文本 B")
                }
            }
            .frame(minHeight: 90, maxHeight: .infinity)

            HStack(spacing: 8) {
                PanelSectionLabel(title: "差异", detail: summary)
                Spacer(minLength: 0)
                CopyButton(text: exportText, help: "复制差异文本（+ 新增 / - 删除）")
            }

            diffRows
                .frame(minHeight: 90, maxHeight: .infinity)
        }
    }

    private var diffRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tools.diff.rows) { row in
                    DiffRowView(row: row)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PanelStyle.fieldBackground)
    }

    private var otherTabs: [EditorTab] {
        session.tabs.filter { $0 !== tab }
    }

    private var summary: String {
        if tools.diffLeft.isEmpty, tools.diffRight.isEmpty { return "两栏均无内容" }
        if tools.diff.isIdentical { return "完全相同（\(tools.diff.rows.count) 行）" }
        return "新增 \(tools.diff.added) 行 · 删除 \(tools.diff.removed) 行"
    }

    /// 差异导出为 `+` / `-` 前缀文本，便于贴到对话或邮件里
    private var exportText: String {
        tools.diff.rows.map { row in
            let marker: String
            switch row.kind {
            case .equal: marker = "  "
            case .removed: marker = "- "
            case .inserted: marker = "+ "
            }
            return marker + row.segments.map(\.text).joined()
        }
        .joined(separator: "\n")
    }

    private var leftBinding: Binding<String> {
        Binding(get: { tools.diffLeft }, set: { tools.updateDiffLeft($0) })
    }

    private var rightBinding: Binding<String> {
        Binding(get: { tools.diffRight }, set: { tools.updateDiffRight($0) })
    }

    private func optionBinding(_ keyPath: ReferenceWritableKeyPath<TextToolsState, Bool>) -> Binding<Bool> {
        Binding(get: { tools[keyPath: keyPath] },
                set: { newValue in
                    tools[keyPath: keyPath] = newValue
                    tools.recompute()
                })
    }
}

/// 单行差异：左侧行号 / 右侧行号 / 标记 / 文本（行内变化片段加深底色）
private struct DiffRowView: View {
    let row: DiffRow

    var body: some View {
        HStack(spacing: 3) {
            gutter(row.leftNumber)
            gutter(row.rightNumber)
            Text(marker)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(markerColor)
                .frame(width: 9, alignment: .center)
            // 只读差异行同上：不参与命中测试，避免内层文本宿主张贴 I-beam 光标
            Text(attributedText)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
    }

    private var marker: String {
        switch row.kind {
        case .equal: return " "
        case .removed: return "-"
        case .inserted: return "+"
        }
    }

    private var markerColor: Color {
        switch row.kind {
        case .equal: return .secondary
        case .removed: return .red
        case .inserted: return .green
        }
    }

    private var rowBackground: Color {
        switch row.kind {
        case .equal: return .clear
        case .removed: return Color.red.opacity(0.12)
        case .inserted: return Color.green.opacity(0.13)
        }
    }

    private var highlightColor: Color {
        row.kind == .removed ? Color.red.opacity(0.3) : Color.green.opacity(0.32)
    }

    /// 行内片段合成富文本；空行补一个空格，保证行高一致
    private var attributedText: AttributedString {
        var result = AttributedString()
        for segment in row.segments {
            var piece = AttributedString(segment.text)
            if segment.changed {
                piece.backgroundColor = highlightColor
            }
            result += piece
        }
        if result.characters.isEmpty {
            return AttributedString(" ")
        }
        return result
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 30, alignment: .trailing)
    }
}

/// 行操作：菜单里那一套操作的抽屉形态（KD5 的共用实现），沿用「输入 → 结果 + 写回」。
/// 输入取编辑器选区 / 全文，点一项操作算出结果，结果可复制或写回编辑器
private struct LineOperationsSection: View {
    @ObservedObject var tools: TextToolsState
    @ObservedObject var tab: EditorTab
    @EnvironmentObject private var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSectionLabel(title: "操作", detail: "作用于输入文本的每一行")
            operations

            PanelSectionLabel(title: "输入", detail: "编辑器选区 / 全文")
            CodeTextEditor(text: inputBinding, placeholder: "在此输入或粘贴文本")

            PanelSectionLabel(title: "结果", detail: resultDetail, isError: tools.errorMessage != nil)
            PanelResultText(text: tools.errorMessage ?? tools.output,
                            isError: tools.errorMessage != nil)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                CopyButton(text: tools.output)
                Button {
                    session.writeBackToolsResult(tools.output, replaceSelection: true, tab: tab)
                } label: {
                    Label("替换选区", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PanelActionButtonStyle(tone: .neutral))
                .help("替换编辑器当前选区；无选区时插入到光标处")
                Button {
                    session.writeBackToolsResult(tools.output, replaceSelection: false, tab: tab)
                } label: {
                    Label("替换全文", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PanelActionButtonStyle(tone: .accent))
                .help("用结果替换编辑器全文（可 ⌘Z 回滚）")
            }
            .controlSize(.small)
            // 还没选操作时结果区是空的，写回会把选区清空；结果确实算成了空串（如整段都是行尾空白）
            // 则允许写回，所以这里卡的是「没选过操作」而不是「结果为空」
            .disabled(!tools.resultIsUsable || tools.lineOperation == nil)
        }
        // 行注释符号随标签语言变化：注释两项的可用性与已选操作的结果都要跟着重算
        .onAppear { tools.updateLineComment(tab.language.lineComment) }
        .onChange(of: tab.language) { tools.updateLineComment($0.lineComment) }
    }

    /// 操作按钮：两列排布，当前选用的那一项染色；注释两项在没有行注释符号的语言下不可选
    private var operations: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                  spacing: 6) {
            ForEach(LineOperationKind.allCases) { kind in
                Button {
                    tools.applyLineOperation(kind, lineComment: tab.language.lineComment)
                } label: {
                    Text(kind.displayName)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelActionButtonStyle(tone: tools.lineOperation == kind ? .accent : .neutral))
                .disabled(!isAvailable(kind))
                .opacity(isAvailable(kind) ? 1 : 0.55)
                .help(isAvailable(kind)
                      ? "对输入的每一行执行：\(kind.displayName)"
                      : "当前语法（\(tab.language.displayName)）没有行注释符号")
            }
        }
        .animation(Motion.control, value: tools.lineOperation)
    }

    /// 注释类操作要求当前语法有行注释符号（与菜单项的置灰口径一致）
    private func isAvailable(_ kind: LineOperationKind) -> Bool {
        !kind.requiresLineComment || tab.language.lineComment != nil
    }

    private var resultDetail: String {
        if tools.errorMessage != nil { return "不可用" }
        return tools.lineOperation?.displayName ?? "选择一项操作"
    }

    private var inputBinding: Binding<String> {
        Binding(get: { tools.input }, set: { tools.updateInput($0) })
    }
}

// MARK: - 复用的小控件

/// 面板内的分区标题：左侧给出分区名，右侧给出来源或结果状态。
private struct PanelSectionLabel: View {
    let title: String
    let detail: String
    var isError = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isError ? InterfaceStyle.danger : .primary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(isError ? InterfaceStyle.danger : InterfaceStyle.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private enum PanelStyle {
    /// 输入 / 结果 / 差异区的共同底：显式底色 + 细描边
    static var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(InterfaceStyle.field)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1))
    }
}

/// 多行输入框：等宽小字号 + 自定义底色 + 空态提示；抽屉内随分到的空间伸缩
private struct CodeTextEditor: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .frame(minHeight: 64, maxHeight: .infinity)
            .background(PanelStyle.fieldBackground)
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !isFocused {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// 只读结果区：可选中复制，超长内容滚动
private struct PanelResultText: View {
    let text: String
    let isError: Bool

    var body: some View {
        ScrollView {
            // 只读结果区：不做文本选择也不参与命中测试，避免内层文本宿主张贴 I-beam 光标
            // （光标矩形按命中测试裁决，参与命中的内层文本会压过面板顶层的光标覆盖层）；
            // 需要复制时用「复制」按钮
            Text(text.isEmpty ? "等待处理结果" : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isError ? InterfaceStyle.danger : (text.isEmpty ? InterfaceStyle.muted : Color.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .frame(minHeight: 64, maxHeight: .infinity)
        .background(PanelStyle.fieldBackground)
    }
}

/// 复制按钮：点击后短暂显示「已复制」作为反馈。
/// 本工程以 Command Line Tools 构建，SwiftUI 的 @State 宏插件不可用，瞬时状态用轻量对象承载
private struct CopyButton: View {
    let text: String
    var help = "复制结果到剪贴板"
    @StateObject private var feedback = CopyFeedback()

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            feedback.showCopied()
        } label: {
            Label(feedback.copied ? "已复制" : "复制",
                  systemImage: feedback.copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PanelActionButtonStyle(tone: .neutral))
        .help(help)
        .disabled(text.isEmpty)
    }
}

/// 「已复制」提示的瞬时状态，1.2 秒后自动复原
private final class CopyFeedback: ObservableObject {
    @Published private(set) var copied = false
    private var resetTask: Task<Void, Never>?

    @MainActor
    func showCopied() {
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// 图标按钮：与查找面板的小按钮同规格
private struct PanelIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = InterfaceHoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(InterfaceStyle.muted)
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hover.isHovered ? InterfaceStyle.accentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(hover.isHovered ? InterfaceStyle.accentBorder : Color.clear, lineWidth: 1)
        )
        .onHover { hover.isHovered = $0 }
        .help(help)
    }
}
