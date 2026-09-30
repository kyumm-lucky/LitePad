import Foundation

/// 恢复区里的一条未标题文稿（KTD3）：稳定标题、正文、正文最近一次变化的时刻
struct RecoveryEntry: Equatable {
    /// 条目在恢复区里的键，也是恢复出来的标签标题（「新文件1」式，R8 / KD4）
    let title: String
    let text: String
    let savedAt: Date
}

/// 恢复区的可见上报：落盘失败与两类超限都要经由这个通道交出去。
/// 用无法报告失败的持久化形态，等于把「内容不丢」悄悄降级成无保护（R6 / R7 的风险口径）
enum RecoveryAlert: Equatable {
    /// 落盘失败（承载目录只读、空间不足等）：这一次的内容没有进入恢复区
    case writeFailed(message: String)
    /// 正文超过单条上限：这一条不写入，异常终止后恢复不了
    case entryTooLarge(title: String, bytes: Int, limit: Int)
    /// 条目数已达上限：最旧的一条被移出（本次写入本身是成功的）
    case evicted(title: String, limit: Int)

    /// 去重键：同一条告警连续出现只上报一次，对应的写盘成功一次即重新武装
    var dedupeKey: String {
        switch self {
        case .writeFailed:
            return "write"
        case .entryTooLarge(let title, _, _):
            return "large:\(title)"
        case .evicted(let title, _):
            return "evicted:\(title)"
        }
    }
}

/// 未标题文稿的恢复区（R6 / R7 / R8；KTD3）
///
/// 与会话恢复是两条并列通道、互不读写对方的键：这里只承载未标题标签的正文与标题，
/// 会话恢复（`lastSession.urls`）只记文件路径。
///
/// 条目按**稳定标题**为键，不用标签的运行时标识 —— 标识每次启动都是新值，
/// 按它做键会让恢复出来的条目永远删不掉、每次启动都复活。
///
/// 承载形态定死为 Application Support 下的一个 JSON 文件，整区一次原子重写：
/// - 不用 UserDefaults：那是报不出失败的持久化形态，写不进去时用户会以为内容受保护；
///   换成文件之后「把承载目录设为只读」这条验收才成立，失败也才报得出来。
/// - 所有写入与删除都从 `persist` 一条路径出去，串行化由 @MainActor 保证：提交顺序即
///   执行顺序、中间不留异步窗口，所以删除不会被还没落盘的写入反超，也不需要落盘线程。
///   单次重写的成本由下面两个上限封顶（最坏 16 MiB，正常只有几 KB），主线程上毫秒级。
/// - 结构损坏的条目（字段类型不对 / 缺字段 / 正文为空）在读取时整条丢弃、按「不存在」处理，
///   绝不降级成「正文为空」的条目让用户去恢复；其余条目不受影响。
///
/// 两个上限（实施时定死，取值理由见 `maxEntryBytes` / `maxEntries`）：
/// 单条正文 1 MiB 与条目数 16 条；超限策略分别是「跳过该条并上报」与「淘汰最旧的并上报」。
@MainActor
final class RecoveryStore {
    /// 全局唯一实例：承载目录取 Application Support/LitePad/Recovery
    static let shared = RecoveryStore()

    /// 单条正文上限（UTF-8 字节）。恢复区是「未标题草稿的最后一道保底」，不是长期存储：
    /// 1 MiB 纯文本已是几万行，覆盖正常草稿绰绰有余，同时把每次去抖重写的编码与写盘成本
    /// 压在毫秒级。超过上限的那一条跳过不写并上报 —— 用户必须知道这段内容没受保护
    static let maxEntryBytes = 1 << 20

    /// 条目数上限。未标题标签是人手动开出来的，正常同时打开的数量是个位数；16 条已经远超
    /// 正常用量，配合单条上限把最坏情况下的承载文件锁在 16 MiB。超出时淘汰最旧的一条并上报
    /// —— 淘汰最旧而不是拒绝最新，是因为最新写入的那一条正是用户此刻在动的内容
    static let maxEntries = 16

    /// 可见上报通道（会话据此显示提示）；同一条告警已上报过就不再重复调用
    var onAlert: (@MainActor (RecoveryAlert) -> Void)?

    /// 承载文件 `Application Support/LitePad/Recovery/entries.json`
    private let fileURL: URL
    /// 当前条目：键是稳定标题
    private var entries: [String: RecoveryEntry]
    /// 已结束的写入方（标签标识）。去抖窗口里可能还有一笔在途写入，墓碑拦下它，
    /// 免得用户已经丢弃的内容被放回恢复区（KTD3 / HTD 的条目生命周期）。
    /// 压实时机定死为「删除那一刻」：条目正文在同一个动作里就离开了承载文件（整区原子重写，
    /// 旧文件被原子替换、不再含这段正文），墓碑只留在内存里、只对本次运行有效 ——
    /// 跨进程不可能存在未落盘的写入请求，所以不需要把墓碑写进文件、也就不会延长正文留存。
    /// 新建标签是另一个写入方，不受旧墓碑影响（同标题复用不会被自己挡住）
    private var retiredWriters: Set<UUID> = []
    /// 已经上报过的告警（按去重键）：同一条连续出现只打扰一次，写盘成功一次即重新武装
    private var reportedAlerts: Set<String> = []

    /// `directory` 为 nil 时取 Application Support/LitePad/Recovery
    init(directory: URL? = nil) {
        let file = (directory ?? Self.defaultDirectory()).appendingPathComponent("entries.json")
        self.fileURL = file
        self.entries = Self.load(from: file)
    }

    // MARK: - 读

    /// 恢复区当前的全部条目（标题 + 正文 + 时间戳），按时间由新到旧。
    /// 损坏的条目在读取时已经丢弃，这里拿到的一定是可用条目（U7 的启动提示据此列名单）
    func allEntries() -> [RecoveryEntry] {
        entries.values.sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: - 写

    /// 写入或覆盖一条目（正文变化去抖后调用）。`writer` 是发起写入的标签标识，只用于墓碑判定：
    /// 条目的键始终是稳定标题。空正文不进恢复区（由调用方走 `remove`），
    /// 免得恢复出来一堆空标签
    func write(_ entry: RecoveryEntry, writer: UUID) {
        guard !retiredWriters.contains(writer), !entry.text.isEmpty else { return }

        let bytes = entry.text.utf8.count
        guard bytes <= Self.maxEntryBytes else {
            report(.entryTooLarge(title: entry.title, bytes: bytes, limit: Self.maxEntryBytes))
            return
        }
        // 正文没变就不重复写盘，时间戳继续表示正文最近一次变化的时刻
        if entries[entry.title]?.text == entry.text { return }

        var next = entries
        next[entry.title] = entry
        var evicted: RecoveryEntry?
        if next.count > Self.maxEntries,
           let oldest = next.values.min(by: { $0.savedAt < $1.savedAt }) {
            next.removeValue(forKey: oldest.title)
            evicted = oldest
        }
        // 落盘失败时内存状态保持原样：承载文件没变，内存也不该显得比它新
        guard persist(next) else { return }
        entries = next
        reportedAlerts.remove("large:\(entry.title)")
        if let evicted {
            report(.evicted(title: evicted.title, limit: Self.maxEntries))
        }
    }

    /// 删除条目（HTD 的「标签正文被清空」出口）：标签还在，之后重新输入的内容照常写入，
    /// 所以不留墓碑 —— 立了墓碑会把用户自己重新敲进来的内容一起挡掉
    func remove(title: String) {
        guard entries[title] != nil else { return }
        var next = entries
        next.removeValue(forKey: title)
        guard persist(next) else { return }
        entries = next
    }

    /// 只给写入方立墓碑，不动任何条目：标签结束时条目可能已经换了主人（同名的新标签刚写过它），
    /// 这时不能删 —— 但去抖窗口里仍然可能有一笔属于这个写入方的在途写入，必须挡住
    func tombstone(writer: UUID) {
        retiredWriters.insert(writer)
    }

    /// 标签结束（关闭标签、正常退出确认后、另存为绑定文件）：移除条目并给写入方立墓碑。
    /// 调用方已经取消了这个标签的订阅，但去抖窗口里可能仍有一笔写入排在删除之后 ——
    /// 墓碑是这一笔的兜底：没有它，用户已经丢弃的内容会在一两次启动之间复活。
    /// 调用方必须先确认条目归这个标签所有（另一端见 `tombstone(writer:)`）
    func retire(title: String, writer: UUID) {
        tombstone(writer: writer)
        remove(title: title)
    }

    /// 全部清空（R7：用户选择放弃时调用）：一次不可逆的批量删除。
    /// 与其他写删同一口径：落盘失败就保持原样并上报 —— 承载文件没变，内存也不该显得比它新；
    /// 下次启动会重新提示，用户至少不会以为内容已经清掉了
    func removeAll() {
        retiredWriters.removeAll()
        guard !entries.isEmpty else { return }
        guard persist([:]) else { return }
        entries = [:]
    }

    // MARK: - 落盘与读取

    /// 唯一的落盘路径：整个恢复区一次原子重写。
    /// 写入与删除都从这里出去 —— 单一入口 + @MainActor 的提交顺序就是执行顺序，
    /// 因此不存在「删除被还没落盘的写入反超」的窗口。
    /// 失败返回 false 并上报；调用方保持内存状态不变
    private func persist(_ next: [String: RecoveryEntry]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            let content = FileContent(version: Self.version, entries: next.values
                .sorted { $0.savedAt > $1.savedAt }
                .map { FileEntry(title: $0.title, savedAt: $0.savedAt.timeIntervalSince1970, text: $0.text) })
            // 分行 + 键排序：这个文件会被人手工查看，验收里还有「人为破坏一条条目的结构」
            // 这一条手工用例，密排的一行 JSON 不方便做这件事
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(content).write(to: fileURL, options: .atomic)
        } catch {
            report(.writeFailed(message: error.localizedDescription))
            return false
        }
        reportedAlerts.remove("write")
        return true
    }

    /// 读取承载文件。整份文件读不出来（不存在、被写坏、不是 JSON）时按「空恢复区」处理；
    /// 单条结构坏掉只丢那一条，其余条目照常读出 —— 一个元素解码失败不能让整个数组跟着失效
    private static func load(from fileURL: URL) -> [String: RecoveryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawEntries = root[Key.entries] as? [Any] else { return [:] }

        var loaded: [String: RecoveryEntry] = [:]
        for raw in rawEntries {
            guard let item = raw as? [String: Any],
                  let title = item[Key.title] as? String, !title.isEmpty,
                  let seconds = item[Key.savedAt] as? Double,
                  let text = item[Key.text] as? String, !text.isEmpty else { continue }
            let entry = RecoveryEntry(title: title, text: text,
                                      savedAt: Date(timeIntervalSince1970: seconds))
            // 同一标题出现多条（文件被手改过 / 旧版本留下）时留最新的那条
            if let existing = loaded[title], existing.savedAt >= entry.savedAt { continue }
            loaded[title] = entry
        }
        return loaded
    }

    /// 上报一次（去重后）：同一条告警连续出现只打扰一次，对应的写入成功即重新武装
    private func report(_ alert: RecoveryAlert) {
        guard reportedAlerts.insert(alert.dedupeKey).inserted else { return }
        onAlert?(alert)
    }

    /// 承载目录：Application Support/LitePad/Recovery
    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support",
                                                                             isDirectory: true)
        return support.appendingPathComponent("LitePad/Recovery", isDirectory: true)
    }

    /// 承载文件的版本号：留着是为了将来能认出旧格式，读侧不依赖它
    private static let version = 1

    /// 承载文件里的一条记录。写侧用 JSONEncoder，读侧用 JSONSerialization：
    /// 读侧要能逐条容错（见 `load`），一个坏条目不该让整份文件作废
    private struct FileEntry: Encodable {
        let title: String
        let savedAt: Double
        let text: String

        enum CodingKeys: String, CodingKey { case title, savedAt, text }
    }

    private struct FileContent: Encodable {
        let version: Int
        let entries: [FileEntry]

        enum CodingKeys: String, CodingKey { case version, entries }
    }

    /// 读侧的键名取自写侧的 `CodingKeys`：两边各写一份字面量时，改名会让读侧静默解析成
    /// 空恢复区（旧内容既看不出来、也会被下一次写盘抹掉），这里把单侧改名的风险掐掉
    private enum Key {
        static let entries = FileContent.CodingKeys.entries.rawValue
        static let title = FileEntry.CodingKeys.title.rawValue
        static let savedAt = FileEntry.CodingKeys.savedAt.rawValue
        static let text = FileEntry.CodingKeys.text.rawValue
    }
}
