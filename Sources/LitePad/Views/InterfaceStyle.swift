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
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

enum PanelButtonTone: Equatable {
    case neutral
    case accent
}

/// 工具面板中的紧凑操作按钮，保证浅色背景下仍有稳定边界和按下反馈。
struct PanelActionButtonStyle: ButtonStyle {
    let tone: PanelButtonTone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone == .accent ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
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
