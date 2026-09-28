import SwiftUI
import AppKit

/// 全局动效语汇：工具抽屉的进出、抽屉内的内容换场、窗口内下拉面板的展开收起，
/// 以及按钮高亮这类微反馈，全部从这里取曲线。连贯感来自同一组节拍——
/// 各处各自定义时长与缓动，看起来就是几段互不相干的动画拼在一起
enum Motion {
    /// 抽屉进出，以及随之发生的编辑区让位
    static let drawer = Animation.spring(response: 0.36, dampingFraction: 0.84, blendDuration: 0.08)
    /// 抽屉内工具切换时的内容换场：比抽屉快半拍，内容先在面板里到位，再等宽度收束
    static let content = Animation.spring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.05)
    /// 窗口内下拉面板的展开与收起（挂在按钮旁，动作要轻，不与抽屉抢视线）
    static let panel = Animation.spring(response: 0.23, dampingFraction: 0.9, blendDuration: 0.04)
    /// 按钮高亮、勾选态、选项出现这类微反馈：短促且不做位移
    static let control = Animation.easeOut(duration: 0.16)
    /// 液体分段控件的胶囊：短促、回弹明显——像一滴水被拽过去再收回。
    /// 时长要压住：拖到 0.3 秒以上，中途那几帧就会被看成"一块板在慢慢挪"
    static let liquid = Animation.spring(response: 0.27, dampingFraction: 0.74, blendDuration: 0.04)

    /// 系统「减弱动态效果」开关：开启后大幅位移一律退化为淡入淡出，缩放与推进照旧
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 抽屉入场：从右缘滑入并淡入。下拉面板不走位移（见 ContentView 里关于
    /// NSHostingView 承载面板的说明），只按 reduceMotion 决定是否淡入
    static func slideTransition(from edge: Edge) -> AnyTransition {
        prefersReducedMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// 内容换场：旧内容朝一侧让位、新内容自另一侧推进，两者同向移动，读起来像一列内容被翻过去。
    /// 位移刻意只取 26pt 而不是整块宽度——换场常与面板变宽同时发生，整幅横移会盖过宽度变化本身
    static func swapTransition(forward: Bool) -> AnyTransition {
        guard !prefersReducedMotion else { return .opacity }
        let shift: CGFloat = 26
        return .asymmetric(
            insertion: .modifier(active: ContentSwap(x: forward ? shift : -shift, opacity: 0, scale: 0.985),
                                 identity: ContentSwap(x: 0, opacity: 1, scale: 1)),
            removal: .modifier(active: ContentSwap(x: forward ? -shift : shift, opacity: 0, scale: 0.985),
                               identity: ContentSwap(x: 0, opacity: 1, scale: 1))
        )
    }
}

/// 内容换场的进出修饰：横向推进 + 淡出 + 轻微缩放（缩放让新内容像从面板里浮出来）
private struct ContentSwap: ViewModifier {
    let x: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}
