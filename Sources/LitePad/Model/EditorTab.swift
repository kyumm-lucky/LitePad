import Foundation
import Combine

/// 单个标签页对应的文档状态
final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()

    @Published var text: String {
        didSet { isDirty = text != savedText }
    }
    @Published private(set) var savedText: String
    @Published private(set) var fileURL: URL?
    @Published var language: LanguageDefinition
    @Published private(set) var isDirty = false

    var displayName: String {
        fileURL?.lastPathComponent ?? "未命名"
    }

    init(fileURL: URL? = nil, text: String = "", savedText: String? = nil) {
        self.fileURL = fileURL
        self.language = LanguageDefinition.detect(from: fileURL)
        self.text = text
        self.savedText = savedText ?? text
        self.isDirty = false
    }

    /// 保存成功后调用：更新落盘基准与语言（扩展名可能变化）
    func markSaved(to url: URL?) {
        fileURL = url
        savedText = text
        language = LanguageDefinition.detect(from: url)
        isDirty = false
    }
}
