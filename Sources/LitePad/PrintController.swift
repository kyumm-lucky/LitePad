import AppKit

/// 打印（R22）：把当前文稿交给系统打印面板，面板以窗口内的表单呈现。
///
/// 打印用的是一份专供打印的文本视图，而不是编辑器里那个活的文本视图：后者的宽度跟着窗口走
/// （按屏幕宽度折行，纸面上会被裁切），语法高亮的前景属性写在文本存储里，当前行色带 /
/// 不可见元素 / 缩进指示由装饰层画在排版层，查找与选中词高亮是排版管理器的临时属性——
/// 直接拿它去打印，这些都会一并印进纸面。这里另建一套 TextKit 栈（普通 NSLayoutManager，
/// 不带装饰层），正文强制深色、不画背景，宽度按可打印宽度排。
@MainActor
final class PrintController: NSObject {
    static let shared = PrintController()

    /// 页面四周的页边距（磅，1 英寸）。必须显式给：边距留 0 时打印管线会按自己的默认可用宽度
    /// 缩放正文——实测 13 磅正文印出来是 10.5 磅且整体偏移，与分页用的纸面高度还对不上；
    /// 给了边距之后版心、字号与分页三者才一致
    private static let pageMargin: CGFloat = 72

    /// 正在跑的打印操作：打印面板是异步关的表单，其间必须有人持有操作对象，
    /// 由完成回执放掉
    private var inFlight: NSPrintOperation?

    /// 把文稿送进打印面板。`text` 取模型里的正文——与保存写盘的口径一致，
    /// 未标题文稿（没有文件路径）同样可打；`jobName` 是打印任务名，取标签的展示名
    func printDocument(_ text: String, jobName: String) {
        // 面板是挂在窗口上的表单：没有窗口可挂时不打印，也不退回应用级模态。
        // 上一次的表单还没关时不再开一个（同一窗口上叠表单会排队，用户会看不出发生了什么）
        guard inFlight == nil, let window = hostWindow else {
            NSSound.beep()
            return
        }
        let printInfo = makePrintInfo()
        let operation = NSPrintOperation(view: makePrintView(text: text, printInfo: printInfo),
                                        printInfo: printInfo)
        operation.jobTitle = jobName
        // 走系统打印面板：面板里可以换打印机、纸张与「存储为 PDF」
        operation.showsPrintPanel = true
        inFlight = operation
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: nil)
    }

    /// 本次打印的打印信息：复制共享的全局打印信息后再按文稿情况调整——共享对象归系统与
    /// 后续打印共用，直接改它会污染下一次打印与页面设置
    func makePrintInfo() -> NSPrintInfo {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.leftMargin = Self.pageMargin
        printInfo.rightMargin = Self.pageMargin
        printInfo.topMargin = Self.pageMargin
        printInfo.bottomMargin = Self.pageMargin
        // 正文按可打印宽度排满整行，不需要再居中；居中会让版心相对页边距整体偏移
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        // 横向 .fit：正文宽度已经等于可打印宽度，不发生缩放；用户在面板里换更小的纸张时
        // 结果是等比缩小而不是横向裁掉。纵向必须 .automatic——.fit 会把整篇文稿缩到一页上
        // （实测 300 行长文被压成 1 页），分页要按纸面高度自动切
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        return printInfo
    }

    /// 专供打印的文本视图：正文用编辑器字体、强制深色，视图不画背景，也没有任何装饰层。
    /// 宽度取可打印宽度（纸张宽度减左右页边距）；高度在排版后按实际内容给——打印分页按
    /// 视图高度切页，高度不够末尾内容会被丢掉（与编辑器里必须放开 maxSize 是同一个道理）
    func makePrintView(text: String, printInfo: NSPrintInfo) -> NSTextView {
        let width = max(1, printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin)
        let font = AppSettings.shared.editorFont
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        // 初始高度只是占位，排完版后按内容重设
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: width),
                                  textContainer: container)
        // 打印副本不参与交互：不画选区，也不留插入点
        textView.isEditable = false
        textView.isSelectable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // 版心由页边距决定，文本视图自身不再加内边距（编辑器里的 4/8 内边距是屏幕上的留白）
        textView.textContainerInset = .zero
        // 纸面不画任何背景：编辑器背景色、深色外观下的底色都不该印进去
        textView.drawsBackground = false

        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: font, range: full)
        // 强制深色：深色外观下的 `.textColor` 是白的，印到白纸上就是一片空白
        storage.addAttribute(.foregroundColor, value: NSColor.black, range: full)
        storage.addAttribute(.paragraphStyle, value: paragraphStyle(for: font), range: full)

        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: ceil(used.height))
        return textView
    }

    /// 打印用段落样式：只对齐制表位这一个与版心有关的项。制表位取与编辑器同一把尺子
    /// （空格宽度 × 缩进宽度），否则纸面上的 Tab 会跳成段落样式自带的 28 磅默认档位
    private func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(IndentRules.clampedWidth(AppSettings.shared.indentWidth))
        return style
    }

    /// 表单的宿主窗口：优先当前活动窗口，其余按可见窗口兜底（应用级模态不在此列）
    private var hostWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    /// 打印面板关掉后的回执（按 selector 回调）：操作对象只在表单期间需要被强持有。
    /// 用户取消同样走这里——不产生打印任务，编辑器与标签状态不受影响
    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        if operation === inFlight {
            inFlight = nil
        }
    }
}
