import SwiftUI

/// 主界面：标签栏 + 编辑区 + 状态栏
struct ContentView: View {
    @EnvironmentObject private var session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
            if let tab = session.selectedTab {
                // 切换标签时以 id 重建编辑器，避免不同标签间文本与选区串扰
                CodeTextView(tab: tab)
                    .id(tab.id)
            } else {
                emptyView
            }
            statusBar(for: session.selectedTab)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("没有打开的标签页")
                .foregroundStyle(.secondary)
            Button("新建标签页") { session.newTab() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func statusBar(for tab: EditorTab?) -> some View {
        if let tab {
            // 独立视图持有 @ObservedObject，保证脏标记 / 语言变化实时刷新
            StatusBarView(tab: tab)
        } else {
            Text("-")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct StatusBarView: View {
    @ObservedObject var tab: EditorTab

    var body: some View {
        HStack(spacing: 12) {
            Text(tab.language.displayName)
            if let path = tab.fileURL?.path {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            }
            Spacer()
            Text("UTF-8")
            Text(tab.isDirty ? "未保存" : "已保存")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
