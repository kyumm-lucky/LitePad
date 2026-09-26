import SwiftUI

/// Notepad++ 式页内标签栏：标签可点击切换、单个关闭，"+" 按钮新建
struct TabBarView: View {
    @EnvironmentObject private var session: EditorSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabButtonView(
                        tab: tab,
                        isSelected: index == session.selectedTabIndex,
                        onSelect: { session.selectedTabIndex = index },
                        onClose: { session.closeTab(at: index) }
                    )
                }
                Button(action: { session.newTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新建标签页")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabButtonView: View {
    @ObservedObject var tab: EditorTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconSymbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(tab.displayName + (tab.isDirty ? " •" : ""))
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭标签页")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color(nsColor: .separatorColor).opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var iconSymbol: String {
        switch tab.language.id {
        case "python": return "chevron.left.forwardslash.chevron.right"
        case "java", "javascript": return "curlybraces"
        case "html", "xml": return "chevron.left.chevron.right"
        case "sql": return "cylinder"
        case "json": return "curlybraces.square"
        default: return "doc.text"
        }
    }
}
