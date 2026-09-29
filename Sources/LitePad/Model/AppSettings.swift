import AppKit
import Combine

/// 启动时无可恢复文件的行为
enum LaunchAction: String, CaseIterable, Identifiable {
    case newDocument
    case doNothing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newDocument: return "创建新文稿"
        case .doNothing: return "不创建"
        }
    }
}

/// 文稿被其他应用更改时的应对策略
enum ExternalChangeAction: String, CaseIterable, Identifiable {
    case keepVersion
    case ask
    case update

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepVersion: return "保留 LitePad 的版本"
        case .ask: return "询问如何更新"
        case .update: return "更新到被更改的版本"
        }
    }
}

/// 应用外观
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "匹配系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 顶栏（标签栏）与状态栏的背景口径，两条栏共用：色调 = 磨砂材质，不透明 = 窗口底色
enum StatusBarBackgroundStyle: String, CaseIterable, Identifiable {
    case tinted
    case opaque

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinted: return "色调"
        case .opaque: return "不透明"
        }
    }
}

/// 编辑器书写方向（竖排暂不支持，仅提供横排两个方向）
enum WritingDirectionOption: String, CaseIterable, Identifiable {
    case ltr
    case rtl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ltr: return "从左到右"
        case .rtl: return "从右到左"
        }
    }
}

/// 不可见元素的显示项
struct InvisiblesOptions: Equatable {
    var lineEndings = true
    var tabs = true
    var spaces = false
    var otherWhitespace = true
    var otherControl = true
}

/// 全局设置：UserDefaults 持久化的单例，仅在主线程访问
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // MARK: - 通用

    @Published var restoreSessionOnLaunch: Bool {
        didSet { defaults.set(restoreSessionOnLaunch, forKey: "settings.restoreSession") }
    }
    @Published var launchAction: LaunchAction {
        didSet { defaults.set(launchAction.rawValue, forKey: "settings.launchAction") }
    }
    /// 编辑已保存文件时自动写盘；未标题文稿仍需手动保存
    @Published var autosaveEnabled: Bool {
        didSet { defaults.set(autosaveEnabled, forKey: "settings.autosave") }
    }
    /// 显式保存时删除每行行尾的空格与制表符；默认关闭（对 Markdown 硬换行、补丁文件不是保义操作）
    @Published var trimTrailingWhitespaceOnSave: Bool {
        didSet { defaults.set(trimTrailingWhitespaceOnSave, forKey: "settings.saveTrimTrailingWhitespace") }
    }
    /// 显式保存时补齐文件末尾的一个换行；默认关闭
    @Published var ensureFinalNewlineOnSave: Bool {
        didSet { defaults.set(ensureFinalNewlineOnSave, forKey: "settings.saveEnsureFinalNewline") }
    }
    /// 保存时清理不作用的语法（语言 id 列表）；默认空，即两项清理对全部语法生效
    @Published private(set) var saveCleanupExcludedLanguageIDs: [String] {
        didSet { defaults.set(saveCleanupExcludedLanguageIDs, forKey: "settings.saveCleanupExcludedLanguages") }
    }
    @Published var externalChangeAction: ExternalChangeAction {
        didSet { defaults.set(externalChangeAction.rawValue, forKey: "settings.externalChange") }
    }

    /// 两项保存时清理是否有任一项开启（设置页据此决定是否展示按语法排除的口径）
    var saveCleanupEnabled: Bool {
        trimTrailingWhitespaceOnSave || ensureFinalNewlineOnSave
    }

    /// 保存时清理是否作用于该语法：两项都关闭或该语法已被排除时不做。
    /// 判定只在这里做一次，编辑视图与会话两侧共用同一口径
    func saveCleanupApplies(to language: LanguageDefinition) -> Bool {
        saveCleanupEnabled && !isSaveCleanupExcluded(language)
    }

    func isSaveCleanupExcluded(_ language: LanguageDefinition) -> Bool {
        saveCleanupExcludedLanguageIDs.contains(language.id)
    }

    /// 切换某语法的清理排除状态
    func setSaveCleanupExcluded(_ excluded: Bool, for language: LanguageDefinition) {
        var ids = saveCleanupExcludedLanguageIDs.filter { $0 != language.id }
        if excluded {
            ids.append(language.id)
        }
        saveCleanupExcludedLanguageIDs = ids
    }

    // MARK: - 外观

    /// 编辑器字体；未命中已存字体名时回退到系统等宽字体
    var editorFont: NSFont {
        get {
            NSFont(name: editorFontName, size: CGFloat(editorFontSize))
                ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        set {
            editorFontName = newValue.fontName
            editorFontSize = Double(newValue.pointSize)
        }
    }
    @Published private(set) var editorFontName: String {
        didSet { defaults.set(editorFontName, forKey: "settings.fontName") }
    }
    @Published var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: "settings.fontSize") }
    }
    /// 字体选择框的展示名；系统内置等宽字体的内部名不适合展示
    var editorFontDisplayName: String {
        editorFont.fontName.hasPrefix(".") ? "系统等宽" : (editorFont.displayName ?? editorFontName)
    }
    @Published var ligaturesEnabled: Bool {
        didSet { defaults.set(ligaturesEnabled, forKey: "settings.ligatures") }
    }
    /// 行高倍数，应用侧收敛到 0.5 - 5
    @Published var lineHeightMultiple: Double {
        didSet { defaults.set(lineHeightMultiple, forKey: "settings.lineHeight") }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: "settings.appearance") }
    }
    @Published var statusBarStyle: StatusBarBackgroundStyle {
        didSet { defaults.set(statusBarStyle.rawValue, forKey: "settings.statusBarStyle") }
    }
    /// 编辑器不透明度（10 - 100，百分比）
    @Published var editorOpacity: Double {
        didSet { defaults.set(editorOpacity, forKey: "settings.editorOpacity") }
    }

    // MARK: - 窗口

    /// 新窗口默认尺寸；nil 表示自动
    @Published var windowWidth: Int? {
        didSet {
            if let windowWidth {
                defaults.set(windowWidth, forKey: "settings.windowWidth")
            } else {
                defaults.removeObject(forKey: "settings.windowWidth")
            }
        }
    }
    @Published var windowHeight: Int? {
        didSet {
            if let windowHeight {
                defaults.set(windowHeight, forKey: "settings.windowHeight")
            } else {
                defaults.removeObject(forKey: "settings.windowHeight")
            }
        }
    }
    @Published var showLineNumbers: Bool {
        didSet { defaults.set(showLineNumbers, forKey: "settings.lineNumbers") }
    }
    @Published var showInvisibles: Bool {
        didSet { defaults.set(showInvisibles, forKey: "settings.showInvisibles") }
    }
    @Published var invisibles: InvisiblesOptions {
        didSet {
            defaults.set(invisibles.lineEndings, forKey: "settings.inv.lineEndings")
            defaults.set(invisibles.tabs, forKey: "settings.inv.tabs")
            defaults.set(invisibles.spaces, forKey: "settings.inv.spaces")
            defaults.set(invisibles.otherWhitespace, forKey: "settings.inv.otherWhitespace")
            defaults.set(invisibles.otherControl, forKey: "settings.inv.otherControl")
        }
    }
    @Published var showIndentGuides: Bool {
        didSet { defaults.set(showIndentGuides, forKey: "settings.indentGuides") }
    }
    /// 一级缩进的宽度（可配置区间 1 - 16，越界取值在应用侧收敛）：回车继承的加级、
    /// Tab 插入的空格数与缩进指示线的一级宽度共用这一口径（KTD10）
    @Published var indentWidth: Int {
        didSet { defaults.set(indentWidth, forKey: "settings.indentWidth") }
    }
    /// 按 Tab 键插入空格；关闭时插入一个制表符（其显示宽度同样按缩进宽度换算）
    @Published var insertSpacesForTab: Bool {
        didSet { defaults.set(insertSpacesForTab, forKey: "settings.tabInsertsSpaces") }
    }
    @Published var pageGuideEnabled: Bool {
        didSet { defaults.set(pageGuideEnabled, forKey: "settings.pageGuideEnabled") }
    }
    @Published var pageGuideColumn: Int {
        didSet { defaults.set(pageGuideColumn, forKey: "settings.pageGuideColumn") }
    }
    @Published var highlightCurrentLine: Bool {
        didSet { defaults.set(highlightCurrentLine, forKey: "settings.currentLine") }
    }
    @Published var wrapLines: Bool {
        didSet { defaults.set(wrapLines, forKey: "settings.wrapLines") }
    }
    @Published var wrapIndentEnabled: Bool {
        didSet { defaults.set(wrapIndentEnabled, forKey: "settings.wrapIndentEnabled") }
    }
    @Published var wrapIndentChars: Int {
        didSet { defaults.set(wrapIndentChars, forKey: "settings.wrapIndentChars") }
    }
    @Published var writingDirection: WritingDirectionOption {
        didSet { defaults.set(writingDirection.rawValue, forKey: "settings.writingDirection") }
    }
    /// 内容底部额外可滚动区域（0 - 100，百分比）
    @Published var extraScrollPercent: Double {
        didSet { defaults.set(extraScrollPercent, forKey: "settings.extraScroll") }
    }
    @Published var statusBarLineCount: Bool {
        didSet { defaults.set(statusBarLineCount, forKey: "settings.sb.lineCount") }
    }
    @Published var statusBarCharCount: Bool {
        didSet { defaults.set(statusBarCharCount, forKey: "settings.sb.charCount") }
    }
    @Published var statusBarWordCount: Bool {
        didSet { defaults.set(statusBarWordCount, forKey: "settings.sb.wordCount") }
    }
    @Published var statusBarCaretOffset: Bool {
        didSet { defaults.set(statusBarCaretOffset, forKey: "settings.sb.caretOffset") }
    }
    @Published var statusBarCaretLine: Bool {
        didSet { defaults.set(statusBarCaretLine, forKey: "settings.sb.caretLine") }
    }
    @Published var statusBarCaretColumn: Bool {
        didSet { defaults.set(statusBarCaretColumn, forKey: "settings.sb.caretColumn") }
    }

    // MARK: - 工具抽屉

    /// 各工具的面板宽度（键为工具 id）：工具面板是窗口右缘的通栏抽屉，宽度可拖拽调整
    @Published private(set) var toolsPanelWidths: [String: Double] {
        didSet { defaults.set(toolsPanelWidths, forKey: "settings.toolsPanelWidths") }
    }

    /// 抽屉宽度下限：再窄控件行与对比两栏都排不下
    static let toolsPanelMinWidth: Double = 360

    /// 当前工具的面板宽度：没调过时按工具给默认值
    func toolsPanelWidth(for kind: TextToolKind) -> Double {
        toolsPanelWidths[kind.rawValue] ?? Self.defaultToolsPanelWidth(for: kind)
    }

    /// 松手后落盘：拖拽中的实时宽度由会话持有，避免每帧写 UserDefaults
    func setToolsPanelWidth(_ width: Double, for kind: TextToolKind) {
        toolsPanelWidths[kind.rawValue] = width
    }

    /// 默认宽度：对比工具是 A/B 两栏，比编码转换宽一些
    static func defaultToolsPanelWidth(for kind: TextToolKind) -> Double {
        kind.isConverter ? 420 : 620
    }

    // MARK: - 格式

    @Published var defaultLineEnding: LineEnding {
        didSet { defaults.set(defaultLineEnding.rawValue, forKey: "settings.defaultLineEnding") }
    }
    @Published var defaultEncoding: TextEncoding {
        didSet { defaults.set(defaultEncoding.rawValue, forKey: "settings.defaultEncoding") }
    }
    /// 无 BOM 文件的解码尝试顺序；BOM 变体与宽字符端序由固定探测处理
    @Published private(set) var encodingPriority: [TextEncoding] {
        didSet { defaults.set(encodingPriority.map(\.rawValue), forKey: "settings.encodingPriority") }
    }
    @Published var respectCharsetDeclaration: Bool {
        didSet { defaults.set(respectCharsetDeclaration, forKey: "settings.respectCharset") }
    }
    /// 新建未标题文稿的默认语法；打开文件仍按扩展名检测
    @Published private(set) var defaultLanguage: LanguageDefinition {
        didSet { defaults.set(defaultLanguage.id, forKey: "settings.defaultLanguage") }
    }

    /// 更新解码优先级；去重并剔除固定探测已覆盖的编码
    func updateEncodingPriority(_ list: [TextEncoding]) {
        var seen = Set<TextEncoding>()
        encodingPriority = list.filter { AppSettings.isPriorityCandidate($0) && seen.insert($0).inserted }
    }

    func setDefaultLanguage(_ language: LanguageDefinition) {
        defaultLanguage = language
    }

    /// 应用外观模式到整个应用
    func applyAppearance() {
        switch appearanceMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 可进入优先级列表的编码：无 BOM 变体（BOM 探测固定先行）
    static func isPriorityCandidate(_ encoding: TextEncoding) -> Bool {
        !isBOMVariant(encoding)
    }

    /// 编码是否为带 BOM 的变体（由固定 BOM 探测处理，不参与优先级）
    private static func isBOMVariant(_ encoding: TextEncoding) -> Bool {
        switch encoding {
        case .utf8BOM, .utf16, .utf32: return true
        default: return false
        }
    }

    // MARK: - 初始化

    private init() {
        restoreSessionOnLaunch = defaults.object(forKey: "settings.restoreSession") as? Bool ?? true
        launchAction = defaults.string(forKey: "settings.launchAction").flatMap(LaunchAction.init(rawValue:)) ?? .newDocument
        autosaveEnabled = defaults.object(forKey: "settings.autosave") as? Bool ?? true
        trimTrailingWhitespaceOnSave = defaults.object(forKey: "settings.saveTrimTrailingWhitespace") as? Bool ?? false
        ensureFinalNewlineOnSave = defaults.object(forKey: "settings.saveEnsureFinalNewline") as? Bool ?? false
        saveCleanupExcludedLanguageIDs = defaults.stringArray(forKey: "settings.saveCleanupExcludedLanguages") ?? []
        externalChangeAction = defaults.string(forKey: "settings.externalChange")
            .flatMap(ExternalChangeAction.init(rawValue:)) ?? .update

        editorFontName = defaults.string(forKey: "settings.fontName") ?? ""
        editorFontSize = defaults.object(forKey: "settings.fontSize") as? Double ?? 13
        ligaturesEnabled = defaults.object(forKey: "settings.ligatures") as? Bool ?? false
        lineHeightMultiple = defaults.object(forKey: "settings.lineHeight") as? Double ?? 1.0
        appearanceMode = defaults.string(forKey: "settings.appearance")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        statusBarStyle = defaults.string(forKey: "settings.statusBarStyle")
            .flatMap(StatusBarBackgroundStyle.init(rawValue:)) ?? .opaque
        editorOpacity = defaults.object(forKey: "settings.editorOpacity") as? Double ?? 100

        windowWidth = defaults.object(forKey: "settings.windowWidth") as? Int
        windowHeight = defaults.object(forKey: "settings.windowHeight") as? Int
        showLineNumbers = defaults.object(forKey: "settings.lineNumbers") as? Bool ?? true
        showInvisibles = defaults.object(forKey: "settings.showInvisibles") as? Bool ?? false
        invisibles = InvisiblesOptions(
            lineEndings: defaults.object(forKey: "settings.inv.lineEndings") as? Bool ?? true,
            tabs: defaults.object(forKey: "settings.inv.tabs") as? Bool ?? true,
            spaces: defaults.object(forKey: "settings.inv.spaces") as? Bool ?? false,
            otherWhitespace: defaults.object(forKey: "settings.inv.otherWhitespace") as? Bool ?? true,
            otherControl: defaults.object(forKey: "settings.inv.otherControl") as? Bool ?? true
        )
        showIndentGuides = defaults.object(forKey: "settings.indentGuides") as? Bool ?? false
        indentWidth = defaults.object(forKey: "settings.indentWidth") as? Int ?? 4
        insertSpacesForTab = defaults.object(forKey: "settings.tabInsertsSpaces") as? Bool ?? true
        pageGuideEnabled = defaults.object(forKey: "settings.pageGuideEnabled") as? Bool ?? false
        pageGuideColumn = defaults.object(forKey: "settings.pageGuideColumn") as? Int ?? 80
        highlightCurrentLine = defaults.object(forKey: "settings.currentLine") as? Bool ?? false
        wrapLines = defaults.object(forKey: "settings.wrapLines") as? Bool ?? true
        wrapIndentEnabled = defaults.object(forKey: "settings.wrapIndentEnabled") as? Bool ?? true
        wrapIndentChars = defaults.object(forKey: "settings.wrapIndentChars") as? Int ?? 0
        writingDirection = defaults.string(forKey: "settings.writingDirection")
            .flatMap(WritingDirectionOption.init(rawValue:)) ?? .ltr
        extraScrollPercent = defaults.object(forKey: "settings.extraScroll") as? Double ?? 0
        statusBarLineCount = defaults.object(forKey: "settings.sb.lineCount") as? Bool ?? true
        statusBarCharCount = defaults.object(forKey: "settings.sb.charCount") as? Bool ?? true
        statusBarWordCount = defaults.object(forKey: "settings.sb.wordCount") as? Bool ?? true
        statusBarCaretOffset = defaults.object(forKey: "settings.sb.caretOffset") as? Bool ?? true
        statusBarCaretLine = defaults.object(forKey: "settings.sb.caretLine") as? Bool ?? true
        statusBarCaretColumn = defaults.object(forKey: "settings.sb.caretColumn") as? Bool ?? true
        toolsPanelWidths = defaults.dictionary(forKey: "settings.toolsPanelWidths") as? [String: Double] ?? [:]

        defaultLineEnding = defaults.string(forKey: "settings.defaultLineEnding")
            .flatMap(LineEnding.init(rawValue:)) ?? .lf
        defaultEncoding = defaults.string(forKey: "settings.defaultEncoding")
            .flatMap(TextEncoding.init(rawValue:)) ?? .utf8
        let storedPriority = defaults.stringArray(forKey: "settings.encodingPriority")?
            .compactMap(TextEncoding.init(rawValue:)) ?? []
        encodingPriority = storedPriority.isEmpty ? [.utf8, .gb18030] : storedPriority
        respectCharsetDeclaration = defaults.object(forKey: "settings.respectCharset") as? Bool ?? true
        let storedLanguageID = defaults.string(forKey: "settings.defaultLanguage")
        defaultLanguage = LanguageDefinition.all.first { $0.id == storedLanguageID } ?? .plain
    }
}
