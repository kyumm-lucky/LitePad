import Foundation

/// 恢复区里的一条已命名文稿草稿：以规范化后的绝对路径为键
struct NamedRecoveryEntry: Equatable {
    let path: String
    let text: String
    let savedAt: Date

    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// 已命名文稿恢复区的可见上报
enum NamedRecoveryAlert: Equatable {
    case writeFailed(message: String)
    case readFailed(message: String)
    case contentCorrupted
    case entryTooLarge(name: String, bytes: Int, limit: Int)
    case evicted(name: String, limit: Int)

    var dedupeKey: String {
        switch self {
        case .writeFailed: return "write"
        case .readFailed: return "read"
        case .contentCorrupted: return "corrupt"
        case .entryTooLarge(let name, _, _): return "large:\(name)"
        case .evicted(let name, _): return "evicted:\(name)"
        }
    }
}

/// 已命名文稿的崩溃恢复区：与未标题恢复区并列、互不读写对方的文件。
/// 未标题文稿的正文没有落盘位置，只能整篇进恢复区；已命名文稿平时由自动保存写回文件，
/// 这里只在「正文与保存基准不一致」时留一份草稿，覆盖自动保存关闭、写盘失败与崩溃窗口。
///
/// 承载形态与 `RecoveryStore` 同一口径：Application Support 下的一个 JSON 文件、整区原子重写、
/// 单一写入路径、读失败禁止改写、单条 / 条目数上限与可见上报。
@MainActor
final class NamedRecoveryStore {
    static let shared = NamedRecoveryStore()

    /// 单条正文上限（UTF-8 字节）：已命名文稿正常靠自动保存，恢复区只是兜底，给 2 MiB 足够
    static let maxEntryBytes = 2 << 20
    /// 条目数上限：正常同时脏着的文件远少于这个数，超出淘汰最旧并上报
    static let maxEntries = 32

    var onAlert: (@MainActor (NamedRecoveryAlert) -> Void)?

    private let fileURL: URL
    private var entries: [String: NamedRecoveryEntry]
    private var reportedAlerts: Set<String> = []
    private var persistBlocked = false
    private var pendingLoadAlert: NamedRecoveryAlert?

    init(directory: URL? = nil) {
        let file = (directory ?? Self.defaultDirectory())
            .appendingPathComponent("named-entries.json")
        self.fileURL = file
        switch Self.load(from: file) {
        case .loaded(let entries):
            self.entries = entries
        case .missing:
            self.entries = [:]
        case .corrupted:
            self.entries = [:]
            pendingLoadAlert = .contentCorrupted
        case .unreadable(let error):
            self.entries = [:]
            persistBlocked = true
            pendingLoadAlert = .readFailed(message: error.localizedDescription)
        }
    }

    func takeLoadAlert() -> NamedRecoveryAlert? {
        guard let alert = pendingLoadAlert else { return nil }
        pendingLoadAlert = nil
        guard reportedAlerts.insert(alert.dedupeKey).inserted else { return nil }
        return alert
    }

    func allEntries() -> [NamedRecoveryEntry] {
        entries.values.sorted { $0.savedAt > $1.savedAt }
    }

    func entry(forPath path: String) -> NamedRecoveryEntry? {
        entries[path]
    }

    // MARK: - 写

    /// 写入或覆盖一条草稿：空正文按删除处理，正文没变不重复写盘
    func write(path: String, text: String, savedAt: Date = Date()) {
        guard !text.isEmpty else {
            remove(path: path)
            return
        }
        let bytes = text.utf8.count
        guard bytes <= Self.maxEntryBytes else {
            report(.entryTooLarge(name: URL(fileURLWithPath: path).lastPathComponent,
                                  bytes: bytes, limit: Self.maxEntryBytes))
            return
        }
        if entries[path]?.text == text { return }

        var next = entries
        next[path] = NamedRecoveryEntry(path: path, text: text, savedAt: savedAt)
        var evicted: NamedRecoveryEntry?
        if next.count > Self.maxEntries,
           let oldest = next.values.min(by: { $0.savedAt < $1.savedAt }) {
            next.removeValue(forKey: oldest.path)
            evicted = oldest
        }
        guard persist(next) else { return }
        entries = next
        reportedAlerts.remove("large:\(URL(fileURLWithPath: path).lastPathComponent)")
        if let evicted {
            report(.evicted(name: evicted.fileName, limit: Self.maxEntries))
        }
    }

    func remove(path: String) {
        guard entries[path] != nil else { return }
        var next = entries
        next.removeValue(forKey: path)
        guard persist(next) else { return }
        entries = next
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        guard persist([:]) else { return }
        entries = [:]
    }

    // MARK: - 落盘与读取

    private func persist(_ next: [String: NamedRecoveryEntry]) -> Bool {
        guard !persistBlocked else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let content = FileContent(version: Self.version, entries: next.values
                .sorted { $0.savedAt > $1.savedAt }
                .map { FileEntry(path: $0.path, savedAt: $0.savedAt.timeIntervalSince1970,
                                 text: $0.text) })
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

    private static func load(from fileURL: URL) -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if RecoveryStore.isMissingFile(error) { return .missing }
            return .unreadable(error)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawEntries = root[Key.entries] as? [Any] else { return .corrupted }

        var loaded: [String: NamedRecoveryEntry] = [:]
        for raw in rawEntries {
            guard let item = raw as? [String: Any],
                  let path = item[Key.path] as? String, !path.isEmpty,
                  let seconds = item[Key.savedAt] as? Double,
                  let text = item[Key.text] as? String, !text.isEmpty else { continue }
            let entry = NamedRecoveryEntry(path: path, text: text,
                                           savedAt: Date(timeIntervalSince1970: seconds))
            if let existing = loaded[path], existing.savedAt >= entry.savedAt { continue }
            loaded[path] = entry
        }
        return .loaded(loaded)
    }

    private enum LoadOutcome {
        case loaded([String: NamedRecoveryEntry])
        case missing
        case corrupted
        case unreadable(Error)
    }

    private func report(_ alert: NamedRecoveryAlert) {
        guard reportedAlerts.insert(alert.dedupeKey).inserted else { return }
        onAlert?(alert)
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("LitePad/Recovery", isDirectory: true)
    }

    private static let version = 1

    private struct FileEntry: Encodable {
        let path: String
        let savedAt: Double
        let text: String
        enum CodingKeys: String, CodingKey { case path, savedAt, text }
    }

    private struct FileContent: Encodable {
        let version: Int
        let entries: [FileEntry]
        enum CodingKeys: String, CodingKey { case version, entries }
    }

    private enum Key {
        static let entries = FileContent.CodingKeys.entries.rawValue
        static let path = FileEntry.CodingKeys.path.rawValue
        static let savedAt = FileEntry.CodingKeys.savedAt.rawValue
        static let text = FileEntry.CodingKeys.text.rawValue
    }
}
