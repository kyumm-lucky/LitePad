import AppKit

/// 视图自报「本区域应有的光标」，光标仲裁按它裁决（如工具抽屉左缘的调宽把手）
protocol CursorDeclaring: AnyObject {
    var preferredCursor: NSCursor { get }
}

/// 光标仲裁：AppKit 的光标按「光标矩形」裁决，而光标矩形只看几何、不看遮挡——
/// 编辑器文本视图铺满窗口内容区，它声明的 I-beam 会连带盖住悬浮其上的下拉面板、设置抽屉、
/// 工具抽屉、标签栏、状态栏与留白；且光标是「黏」的，移出后不会自己复位成箭头，
/// 于是非编辑区也会显示竖线光标。
///
/// 这里改为按命中视图判定：命中链上有可编辑文本视图就用 I-beam（编辑器、面板输入框），
/// 有自报光标的视图就用它声明的光标（抽屉调宽把手），其余一律箭头。
///
/// 事件不吞：AppKit 仍在事件派发里按光标矩形设置光标，所以判定推迟到本次事件派发之后
/// （下一个主队列周期）执行，落定时已是最终结果。mouseMoved 照常下发给 SwiftUI，
/// onHover 悬停高亮、工具提示等依赖鼠标移动行为不受影响。
final class CursorArbiter {
    static let shared = CursorArbiter()

    private var monitor: Any?
    private var activationObserver: NSObjectProtocol?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate]) { [weak self] event in
            // 延后一个主队列周期再判定：AppKit 处理完本次事件（含按光标矩形设光标）后才轮到我们
            DispatchQueue.main.async { self?.refresh() }
            return event
        }
        // 切回本应用时指针可能已在别处，补算一次
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        prepareMouseMovedEvents()
    }

    /// 指针没动但指针下的区域变了（面板 / 抽屉开合、窗口尺寸变化）时主动补算一次
    func refresh() {
        guard let window = keyWindow, let root = window.contentView else { return }
        apply(at: window.mouseLocationOutsideOfEventStream, in: window, root: root)
    }

    private var keyWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    /// 窗口默认不投递 mouseMoved，这里显式开启：指针移动时才能重算光标
    private func prepareMouseMovedEvents() {
        for window in NSApp.windows {
            window.acceptsMouseMovedEvents = true
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
    }

    /// 命中测试的点取「接收者父视图」的坐标：内容视图的父视图是窗口框架，故用窗口坐标
    private func apply(at locationInWindow: NSPoint, in window: NSWindow, root: NSView) {
        // 指针不在内容视图内（标题栏、窗口边框）时不插手：边框上的系统缩放光标由 AppKit 管
        guard let first = root.hitTest(locationInWindow) else { return }
        var hit: NSView? = first
        while let view = hit {
            if let declaring = view as? CursorDeclaring {
                declaring.preferredCursor.set()
                return
            }
            if let textView = view as? NSTextView, textView.isEditable || textView.isSelectable {
                NSCursor.iBeam.set()
                return
            }
            if let textField = view as? NSTextField, textField.isEditable || textField.isSelectable {
                NSCursor.iBeam.set()
                return
            }
            hit = view.superview
        }
        NSCursor.arrow.set()
    }
}
