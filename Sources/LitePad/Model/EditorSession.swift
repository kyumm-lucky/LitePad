import AppKit
import Combine

/// 管理所有标签页的会话：新建 / 打开 / 保存 / 关闭
@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published var selectedTabIndex: Int = 0

    init() {
        tabs = [EditorTab()]
    }

    var selectedTab: EditorTab? {
        guard tabs.indices.contains(selectedTabIndex) else { return nil }
        return tabs[selectedTabIndex]
    }

    func newTab() {
        tabs.append(EditorTab())
        selectedTabIndex = tabs.count - 1
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要编辑的文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            tabs.append(EditorTab(fileURL: url, text: content))
            selectedTabIndex = tabs.count - 1
        } catch {
            presentErrorAlert(title: "无法读取文件", message: error.localizedDescription)
        }
    }

    func saveSelectedTab() {
        guard let tab = selectedTab else { return }
        save(tab: tab)
    }

    @discardableResult
    func save(tab: EditorTab) -> Bool {
        var targetURL = tab.fileURL
        if targetURL == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "未命名.txt"
            panel.message = "选择保存位置"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            targetURL = chosen
        }
        guard let url = targetURL else { return false }

        do {
            try tab.text.write(to: url, atomically: true, encoding: .utf8)
            tab.markSaved(to: url)
            return true
        } catch {
            presentErrorAlert(title: "无法保存文件", message: error.localizedDescription)
            return false
        }
    }

    func closeSelectedTab() {
        guard tabs.indices.contains(selectedTabIndex) else { return }
        closeTab(at: selectedTabIndex)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]

        if tab.isDirty {
            switch confirmSave(of: tab) {
            case .save:
                guard save(tab: tab) else { return } // 保存被取消则不关闭
            case .discard:
                break
            case .cancel:
                return
            }
        }

        tabs.remove(at: index)
        if tabs.isEmpty {
            tabs = [EditorTab()] // 始终保留一个空标签，与 Notepad++ 行为一致
            selectedTabIndex = 0
        } else if index < selectedTabIndex {
            selectedTabIndex -= 1
        } else {
            selectedTabIndex = min(selectedTabIndex, tabs.count - 1)
        }
    }

    // MARK: - Private

    private enum SaveChoice { case save, discard, cancel }

    private func confirmSave(of tab: EditorTab) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = "是否保存对“\(tab.displayName)”的更改？"
        alert.informativeText = "如果不保存，更改将会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
