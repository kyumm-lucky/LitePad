import SwiftUI
import AppKit

/// 页面级视觉令牌：显式使用系统语义色，避免浅色外观下依赖透明材质导致控件消失。
enum InterfaceStyle {
    /// 磨砂表面的黑色压色：深色模式加深表面，浅色模式只保留轻微灰度。
    static var frostedBlackOverlay: Color {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Color.black.opacity(isDark ? 0.38 : 0.08)
    }

    /// 磨砂边缘的高光，避免黑色半透明表面与背景融成一块。
    static var frostedEdge: Color {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Color.white.opacity(isDark ? 0.14 : 0.32)
    }

    static var canvas: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var window: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var panel: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var raised: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var field: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var border: Color {
        Color(nsColor: .separatorColor).opacity(0.92)
    }

    static var borderStrong: Color {
        Color(nsColor: .separatorColor)
    }

    static var muted: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static var accent: Color {
        Color(nsColor: .controlAccentColor)
    }

    static var accentSoft: Color {
        accent.opacity(0.12)
    }

    static var accentBorder: Color {
        accent.opacity(0.42)
    }

    static var danger: Color {
        Color(nsColor: .systemRed)
    }

    static var success: Color {
        Color(nsColor: .systemGreen)
    }
}

/// 设置页语义令牌：取值来自设置页设计稿的深浅两套色板，随系统外观动态解析，
/// 切换「匹配系统 / 浅色 / 深色」时无需重建视图。工具栏、工具面板仍用上面的系统色，
/// 两边互不影响
enum SettingsStyle {
    // MARK: - 表面

    /// 抽屉窗口底色
    static var window: Color { dynamic(light: hex(0xF1F1F3), dark: hex(0x1B1B1E)) }
    /// 侧栏底：比窗口深 / 浅一档，不用材质
    static var sidebar: Color { dynamic(light: hex(0xEAEAED), dark: hex(0x212125)) }
    /// 分组卡片底
    static var card: Color { dynamic(light: hex(0xFFFFFF), dark: hex(0x29292D)) }
    /// 卡片描边（浅色靠它定边界，深色只做极轻的一层）
    static var cardLine: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.065))
    }
    /// 控件底：菜单按钮、普通按钮、步进器
    static var control: Color { dynamic(light: hex(0xFFFFFF), dark: hex(0x323237)) }
    static var controlHover: Color { dynamic(light: hex(0xF0F0F2), dark: hex(0x3D3D43)) }
    /// 控件描边：0.5pt 单层，不做内外双层
    static var controlLine: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.14), dark: NSColor.white.withAlphaComponent(0.12))
    }
    /// 输入框底
    static var field: Color { dynamic(light: hex(0xFFFFFF), dark: hex(0x232327)) }
    /// 行与分组的分隔线：0.5pt，行内左起 16
    static var separator: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.085), dark: NSColor.white.withAlphaComponent(0.085))
    }
    /// 抽屉贴在编辑区上的一层投影：只给浮层
    static var drawerShadow: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.18), dark: NSColor.black.withAlphaComponent(0.45))
    }

    // MARK: - 文本

    static var text: Color { dynamic(light: hex(0x1D1D1F), dark: hex(0xF5F5F7)) }
    /// 说明文字：浅色黑 76%、深色白 62%，11pt 正文可达 5 : 1
    static var text2: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.76), dark: NSColor.white.withAlphaComponent(0.62))
    }

    // MARK: - 强调与选中

    /// 强调色只出现在选中、开启、聚焦三处
    static var accent: Color { dynamic(light: hex(0x007AFF), dark: hex(0x0A84FF)) }
    /// 侧栏项悬停底
    static var selection: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.055), dark: NSColor.white.withAlphaComponent(0.075))
    }
    /// 侧栏项选中底：选中只此一处标记
    static var selectionStrong: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.085), dark: NSColor.white.withAlphaComponent(0.12))
    }

    // MARK: - 控件内部

    /// 分段控件轨道与滑块
    static var segmentTrack: Color { dynamic(light: hex(0xECECEF), dark: hex(0x26262A)) }
    static var segmentThumb: Color { dynamic(light: hex(0xFFFFFF), dark: hex(0x45454B)) }
    /// 开关关闭态轨道与滑块拇指
    static var switchTrack: Color {
        dynamic(light: NSColor.black.withAlphaComponent(0.13), dark: NSColor.white.withAlphaComponent(0.14))
    }

    /// 外观预览小窗的两套取色（设计稿给的是绝对色，预览内容不随当前外观变）
    struct MiniTone {
        let background: Color
        let bar: Color
        let side: Color
        let line: Color

        static let light = MiniTone(background: Color(nsColor: hex(0xF7F7F9)),
                                    bar: Color(nsColor: hex(0xE7E7EB)),
                                    side: Color(nsColor: hex(0xEFEFF2)),
                                    line: Color(nsColor: hex(0xC9C9D1)))
        static let dark = MiniTone(background: Color(nsColor: hex(0x1E1E21)),
                                   bar: Color(nsColor: hex(0x2C2C31)),
                                   side: Color(nsColor: hex(0x26262A)),
                                   line: Color(nsColor: hex(0x4A4A52)))
    }

    // MARK: - 换算

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// 设计稿给的是 sRGB 十六进制值，深浅两套共用这一处换算
private func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

/// 设置页尺寸常量：与设计稿 4.1 的表格一一对应，行、控件、卡片共用同一组数值
enum SettingsMetrics {
    /// 输入框统一高度：行高、窗口宽高、额外滚动与等宽字体显示框共用，
    /// 新增输入框时一并取这里，避免各行高度再次走散
    static let fieldHeight: CGFloat = 28
    /// 侧栏宽度
    static let sidebarWidth: CGFloat = 168
    /// 页头高度
    static let headerHeight: CGFloat = 60
    /// 内容区滚动边距：上 12、左右 20、下 26
    static let contentTop: CGFloat = 12
    static let contentSide: CGFloat = 20
    static let contentBottom: CGFloat = 26
    /// 分组之间与组标题到卡片
    static let groupSpacing: CGFloat = 22
    static let groupTitleGap: CGFloat = 8
    /// 卡片圆角与行内边距
    static let cardRadius: CGFloat = 10
    static let rowMinHeight: CGFloat = 38
    static let rowPaddingH: CGFloat = 16
    static let rowPaddingV: CGFloat = 8
    /// 子项行（依赖父开关的输入项）左缩进
    static let subrowIndent: CGFloat = 32
    /// 行内与组内控件间距
    static let controlSpacing: CGFloat = 8
    /// 控件高与圆角
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 6
    /// 步进器、开关、复选
    static let stepperWidth: CGFloat = 22
    static let switchWidth: CGFloat = 26
    static let switchHeight: CGFloat = 15
    static let checkboxSize: CGFloat = 14
    /// 侧栏项
    static let sidebarItemHeight: CGFloat = 30
    static let sidebarItemRadius: CGFloat = 6
    /// 分段控件
    static let segmentHeight: CGFloat = 22
    /// 外观预览瓷砖
    static let tileWidth: CGFloat = 66
    static let tileHeight: CGFloat = 42
    static let tileGap: CGFloat = 9
}

/// 统一的磨砂黑表面：先用系统材质保留背景层次，再叠加黑色透明色调与细边缘高光。
struct FrostedSurface<ShapeType: InsettableShape>: View {
    let shape: ShapeType

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(InterfaceStyle.frostedBlackOverlay))
            .overlay(shape.stroke(InterfaceStyle.frostedEdge, lineWidth: 1))
    }
}

/// 顶栏（标签栏）与状态栏共用的背景：色调 = 磨砂材质，不透明 = 窗口底色。
/// 两条栏必须同一口径——一条材质、一条纯色时，浅色下一条偏冷灰、一条偏白，看着像两种窗口
struct BarBackground: View {
    let style: StatusBarBackgroundStyle

    var body: some View {
        if style == .tinted {
            FrostedSurface(shape: Rectangle())
        } else {
            InterfaceStyle.window
        }
    }
}

/// 供多个页面控件共用的悬停状态。使用对象承载瞬时状态，兼容当前 Command Line Tools 工具链。
final class InterfaceHoverState: ObservableObject {
    @Published var isHovered = false
}

/// 面板内的高对比二态选择框。
struct LitePadToggle: View {
    let title: String
    @Binding var isOn: Bool
    var help: String = ""

    @StateObject private var hover = InterfaceHoverState()

    var body: some View {
        Button {
            withAnimation(Motion.control) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? InterfaceStyle.accent : InterfaceStyle.field)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? InterfaceStyle.accent : InterfaceStyle.borderStrong,
                                      lineWidth: isOn ? 0 : 1.2)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 15, height: 15)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover.isHovered ? InterfaceStyle.accentSoft : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hover.isHovered ? InterfaceStyle.accentBorder : Color.clear,
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? L10n.t("已开启") : L10n.t("已关闭"))
    }
}

enum PanelButtonTone: Equatable {
    case neutral
    case accent
}

/// 工具面板中的紧凑操作按钮，保证浅色背景下仍有稳定边界和按下反馈。
struct PanelActionButtonStyle: ButtonStyle {
    let tone: PanelButtonTone
    /// 最小高度：紧邻设置页 28pt 输入框的按钮传入同高值，默认 0 保持工具面板的紧凑尺寸
    var minHeight: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone == .accent ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(minHeight: minHeight)
            .background(background(isPressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tone == .accent ? InterfaceStyle.accent : InterfaceStyle.borderStrong,
                                  lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.control, value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> Color {
        switch tone {
        case .neutral:
            return isPressed ? InterfaceStyle.accentSoft : InterfaceStyle.raised
        case .accent:
            return isPressed ? InterfaceStyle.accent.opacity(0.82) : InterfaceStyle.accent
        }
    }
}
