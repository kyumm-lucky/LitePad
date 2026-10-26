import AppKit
import Foundation

/// 一条跨文件搜索命中：文件、行号与该行文本（用于结果列表展示与跳转）
struct FolderSearchResult: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let line: Int
    let preview: String

    var fileName: String { url.lastPathComponent }
    var location: String { "\(fileName):\(line)" }
}

/// 文件夹级搜索：只按行匹配，逐文件宽容解码后扫描；目录与体积都有上限，
/// 结果按「路径 → 行号」排序，避免一次搜索把整个磁盘读进来
enum FolderSearch {
    /// 跳过的目录：版本库、依赖与构建产物不属于用户文稿
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", "build", "node_modules", "DerivedData", ".swiftpm"
    ]
    private static let maxFiles = 2000
    private static let maxFileBytes = 2 << 20
    private static let maxResults = 500

    struct Outcome {
        let results: [FolderSearchResult]
        let reachedLimit: Bool
        let scannedFiles: Int
    }

    static func run(folder: URL,
                    query: String,
                    useRegex: Bool,
                    caseSensitive: Bool,
                    wholeWord: Bool,
                    encodingPriority: [TextEncoding],
                    respectCharsetDeclaration: Bool) -> Outcome {
        guard !query.isEmpty else { return Outcome(results: [], reachedLimit: false, scannedFiles: 0) }

        var regex: NSRegularExpression?
        if useRegex {
            var options: NSRegularExpression.Options = []
            if !caseSensitive { options.insert(.caseInsensitive) }
            guard let compiled = try? NSRegularExpression(pattern: query, options: options) else {
                return Outcome(results: [], reachedLimit: false, scannedFiles: 0)
            }
            regex = compiled
        }

        var results: [FolderSearchResult] = []
        var scanned = 0
        var reachedLimit = false

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return Outcome(results: [], reachedLimit: false, scannedFiles: 0)
        }

        outer: for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > maxFileBytes { continue }
            guard !isBinaryExtension(fileURL.pathExtension) else { continue }

            scanned += 1
            if scanned > maxFiles {
                reachedLimit = true
                break outer
            }
            guard let data = try? Data(contentsOf: fileURL), !data.contains(0) else { continue }
            let (text, _) = TextEncoding.decode(
                data,
                priority: encodingPriority,
                respectCharsetDeclaration: respectCharsetDeclaration)

            let lines = splitLines(text)
            for (index, line) in lines.enumerated() {
                guard matches(line: line, query: query, regex: regex,
                              caseSensitive: caseSensitive, wholeWord: wholeWord) else { continue }
                results.append(FolderSearchResult(url: fileURL, line: index + 1,
                                                  preview: preview(of: line)))
                if results.count >= maxResults {
                    reachedLimit = true
                    break
                }
            }
            if reachedLimit { break }
        }

        results.sort {
            if $0.url.path != $1.url.path { return $0.url.path < $1.url.path }
            return $0.line < $1.line
        }
        return Outcome(results: results, reachedLimit: reachedLimit, scannedFiles: scanned)
    }

    private static func matches(line: String, query: String, regex: NSRegularExpression?,
                                caseSensitive: Bool, wholeWord: Bool) -> Bool {
        if let regex {
            let nsLine = line as NSString
            let full = NSRange(location: 0, length: nsLine.length)
            let found = regex.matches(in: line, options: [], range: full)
                .contains { match in
                    guard wholeWord else { return true }
                    return isWholeWord(match.range, in: nsLine)
                }
            return found
        }
        var options: String.CompareOptions = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        let nsLine = line as NSString
        var start = 0
        while start < nsLine.length {
            let searchRange = NSRange(location: start, length: nsLine.length - start)
            let found = nsLine.range(of: query, options: options, range: searchRange, locale: nil)
            guard found.location != NSNotFound else { return false }
            if !wholeWord || isWholeWord(found, in: nsLine) { return true }
            start = found.location + max(found.length, 1)
        }
        return false
    }

    /// 全词：两侧不能是词字符；CJK 逐字视为边界（与查找面板同一口径）
    private static func isWholeWord(_ range: NSRange, in nsText: NSString) -> Bool {
        let end = range.location + range.length
        let beforeOK = range.location == 0 || !isWordChar(at: range.location - 1, in: nsText)
        let afterOK = end >= nsText.length || !isWordChar(at: end, in: nsText)
        return beforeOK && afterOK
    }

    private static func isWordChar(at index: Int, in nsText: NSString) -> Bool {
        guard let scalar = Unicode.Scalar(nsText.character(at: index)) else { return false }
        return !DocumentStats.isCJKScalar(scalar) && CharacterSet.alphanumerics.contains(scalar)
    }

    /// 结果行只展示前若干个字符，避免超长行把列表撑坏
    private static func preview(of line: String, limit: Int = 200) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    /// 按 LF / CRLF / CR 拆行，行号从 1 起；末尾没有换行时最后一行的内容仍然算一行
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\r" || character == "\n" {
                lines.append(String(text[start..<index]))
                var next = text.index(after: index)
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    next = text.index(after: next)
                }
                start = next
                index = next
            } else {
                index = text.index(after: index)
            }
        }
        if start < text.endIndex {
            lines.append(String(text[start..<text.endIndex]))
        }
        return lines
    }

    private static func isBinaryExtension(_ ext: String) -> Bool {
        let binary: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp",
            "mp3", "mp4", "mov", "avi", "mkv", "m4a", "flac", "wav",
            "zip", "gz", "tar", "7z", "rar", "dmg", "pkg", "pdf",
            "icns", "app", "exe", "dll", "dylib", "so", "a", "o",
            "ttf", "otf", "woff", "woff2", "class", "jar"
        ]
        return binary.contains(ext.lowercased())
    }
}

/// 文件夹搜索工具的面板状态：目录、条件、结果与进行中的任务都挂在会话级
@MainActor
final class FolderSearchState: ObservableObject {
    static let shared = FolderSearchState()

    @Published var folder: URL?
    @Published var query = ""
    @Published var useRegex = false
    @Published var caseSensitive = false
    @Published var wholeWord = false
    @Published private(set) var results: [FolderSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var summary = ""

    private var task: Task<Void, Never>?

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.t("选择要在其中搜索的文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        results = []
        summary = ""
    }

    func search() {
        guard let folder, !query.isEmpty else { return }
        task?.cancel()
        let settings = AppSettings.shared
        isSearching = true
        summary = L10n.t("搜索中…")
        results = []
        let priority = settings.encodingPriority
        let respectDeclaration = settings.respectCharsetDeclaration
        let query = query
        let useRegex = useRegex
        let caseSensitive = caseSensitive
        let wholeWord = wholeWord

        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                FolderSearch.run(folder: folder, query: query, useRegex: useRegex,
                                 caseSensitive: caseSensitive, wholeWord: wholeWord,
                                 encodingPriority: priority,
                                 respectCharsetDeclaration: respectDeclaration)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.isSearching = false
            self.results = outcome.results
            if outcome.results.isEmpty {
                self.summary = L10n.t("没有命中")
            } else if outcome.reachedLimit {
                self.summary = L10n.format("命中已达上限，仅显示前 %d 条", outcome.results.count)
            } else {
                self.summary = L10n.format("命中 %d 条 · 扫描 %d 个文件", outcome.results.count, outcome.scannedFiles)
            }
        }
    }
}
