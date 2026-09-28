import SwiftUI
import AppKit

/// 液体分段控件：选中胶囊像一滴水——切换时先横向拉长、纵向微收，落位时回弹收回。
/// 胶囊位置与拉伸量绑在同一个动画值上（离最近档位中心的距离决定拉伸），因此中途最饱满、
/// 落位自然归零；选中项直接来自调用方，悬停状态只负责视觉反馈，避免与业务状态出现两份真相
struct LiquidSegmented: View {
    let labels: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    /// 单档宽度：由调用方给定，便于与相邻控件对齐
    var segmentWidth: CGFloat = 54
    var height: CGFloat = 22

    @StateObject private var hover = SegmentHoverState()

    private var totalWidth: CGFloat { segmentWidth * CGFloat(labels.count) }
    private var cornerRadius: CGFloat { 7 }
    private var selectionIsValid: Bool { labels.indices.contains(selectedIndex) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(InterfaceStyle.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1)
                )

            if selectionIsValid {
                // 胶囊基准尺寸即单档大小，实际尺寸与位置由 Droplet 投影给出。
                // 几何走液体弹簧（快、带回弹），拉伸只取两成：再大就成一条横板压在字上
                RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                    .fill(InterfaceStyle.accentSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                            .strokeBorder(InterfaceStyle.accentBorder, lineWidth: 1)
                    )
                    .frame(width: segmentWidth, height: height - 3)
                    .modifier(Droplet(center: CGFloat(selectedIndex),
                                      segmentWidth: segmentWidth,
                                      totalWidth: totalWidth))
                    .animation(Motion.liquid, value: selectedIndex)
            }

            HStack(spacing: 0) {
                ForEach(labels.indices, id: \.self) { index in
                    // 用 Button 而不是点击手势：无障碍树里才是可操作的按钮，
                    // VoiceOver 与自动化都能按下（原生分段控件暴露的是 radio，这里保持可操作性）
                    Button {
                        onSelect(index)
                    } label: {
                        Text(labels[index])
                            .font(.system(size: 11))
                            .foregroundStyle(index == selectedIndex ? InterfaceStyle.accent : InterfaceStyle.muted)
                            .frame(width: segmentWidth, height: height)
                            .background(
                                RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                                    .fill(index != selectedIndex && hover.index == index ? InterfaceStyle.accentSoft : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hover.index = $0 ? index : nil }
                    .accessibilityLabel(labels[index])
                    .accessibilityAddTraits(index == selectedIndex ? [.isButton, .isSelected] : .isButton)
                }
            }
            // 墨色单独走短促曲线：若与胶囊共用慢弹簧，中途会留下半灰的字压在胶囊上，
            // 看着像"字先翻完、胶囊还没到"
            .animation(Motion.control, value: selectedIndex)
        }
        .frame(width: totalWidth, height: height)
    }
}

private final class SegmentHoverState: ObservableObject {
    @Published var index: Int?
}

/// 水滴投影：把胶囊的位移与拉伸绑在同一个动画值上。
/// center 以「档位」为单位（0、1、2…），lag 取它离最近档位中心的距离——
/// 行进中途 lag 最大（拉得最长、压得最扁），落位时 lag 归零，胶囊自动收回原尺寸。
/// 弹簧的回弹会让 center 略微越过目标，lag 随之抬起来又落下，看起来就是水珠晃了两下
private struct Droplet: GeometryEffect {
    var center: CGFloat
    let segmentWidth: CGFloat
    let totalWidth: CGFloat

    var animatableData: CGFloat {
        get { center }
        set { center = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // 0＝停在档位中心，1＝正好在两档之间
        let lag = min(abs(center - center.rounded()) / 0.5, 1)
        let stretched = segmentWidth * (1 + 0.22 * lag)
        // 拉伸后的左缘：以 center 居中，并夹在轨道内——贴边的那一档把拉伸量挤向内侧，胶囊不会滑出
        // selectedIndex 表示档位索引，胶囊中心应落在每档的中心，而不是左边缘。
        let rawLeft = (center + 0.5) * segmentWidth - stretched / 2
        let left = min(max(rawLeft, 0), max(totalWidth - stretched, 0))
        let scaleY = 1 - 0.08 * lag
        let y = (size.height - size.height * scaleY) / 2
        return ProjectionTransform(CGAffineTransform(scaleX: stretched / segmentWidth, y: scaleY))
            .concatenating(ProjectionTransform(CGAffineTransform(translationX: left, y: y)))
    }
}
