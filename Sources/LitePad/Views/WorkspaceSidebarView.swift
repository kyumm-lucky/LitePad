import SwiftUI
import AppKit

/// 文件夹工作区侧栏：列出所选文件夹下的文件（扁平列表 + 相对路径），点一行打开为标签。
/// 只做浏览与打开，不监听目录变化；刷新由重新选择文件夹或重开侧栏触发
struct WorkspaceSidebarView: View {
    let folder: URL
    let onClose: () -> Void
    @EnvironmentObject private var session: EditorSession
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model = WorkspaceFolderModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.files, id: \.self) { url in
                        Button {
                            session.open(url: url)
                        } label: {
                            row(for: url)
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                    if model.files.isEmpty {
                        Text(L10n.t("这个文件夹里没有可打开的文件"))
                            .font(.system(size: 10))
                            .foregroundStyle(InterfaceStyle.muted)
                            .padding(10)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 230)
        .background(BarBackground(style: settings.statusBarStyle))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(InterfaceStyle.borderStrong)
                .frame(width: 1)
        }
        .onAppear { model.load(folder: folder) }
        .onChange(of: folder) { newValue in model.load(folder: newValue) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(InterfaceStyle.accent)
            Text(folder.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(InterfaceStyle.muted)
            .help(L10n.t("关闭文件夹工作区"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func row(for url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(InterfaceStyle.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                let relative = model.relativePath(for: url)
                if !relative.isEmpty {
                    Text(relative)
                        .font(.system(size: 9))
                        .foregroundStyle(InterfaceStyle.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// 侧栏的文件清单：枚举上限与跨文件搜索同一口径，避免大目录把界面卡住
@MainActor
private final class WorkspaceFolderModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    private var rootPath = ""

    private static let maxFiles = 2000
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", "build", "node_modules", "DerivedData", ".swiftpm"
    ]

    func load(folder: URL) {
        rootPath = folder.path
        files = Self.enumerateFiles(in: folder)
    }

    func relativePath(for url: URL) -> String {
        guard url.path.hasPrefix(rootPath + "/") else { return "" }
        let relative = String(url.path.dropFirst(rootPath.count + 1))
        return (relative as NSString).deletingLastPathComponent
    }

    private static func enumerateFiles(in folder: URL) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > (2 << 20) { continue }
            result.append(url)
            if result.count >= maxFiles { break }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
