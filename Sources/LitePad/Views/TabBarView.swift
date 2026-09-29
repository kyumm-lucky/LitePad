import SwiftUI

/// Notepad++ 式页内标签栏：标签可点击切换、单个关闭，"+" 按钮新建，右端齿轮打开设置
struct TabBarView: View {
    @EnvironmentObject private var session: EditorSession
    /// 顶栏背景与状态栏共用同一设置（见 BarBackground）
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            // 标签与 "+" 随数量横向滚动；齿轮固定在右缘，不随标签滚动移出视野
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabButtonView(
                            tab: tab,
                            isSelected: index == session.selectedTabIndex,
                            onSelect: { session.selectedTabIndex = index },
                            onClose: { session.closeTab(at: index) }
                        )
                        .contextMenu { tabContextMenu(at: index) }
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
            }

            settingsButton
                .buttonStyle(.plain)
                .foregroundStyle(session.isSettingsPresented ? Color.accentColor : Color.secondary)
                .animation(Motion.panel, value: session.isSettingsPresented)
                .help("设置")

            // 工具入口：扳手按钮，展开的下拉与状态栏下拉同一套面板样式
            toolsButton
                .buttonStyle(.plain)
                .foregroundStyle(toolsButtonActive ? Color.accentColor : Color.secondary)
                // 配色与图标转动共用一条弹簧：按钮"拧一下"的手感与下拉、抽屉同一拍
                .animation(Motion.panel, value: toolsButtonActive)
                .help("工具")
                .padding(.trailing, 6)
        }
        .frame(height: 34)
        .background(BarBackground(style: settings.statusBarStyle))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(InterfaceStyle.borderStrong)
                .frame(height: 1)
        }
    }

    /// 扳手按钮的激活态：下拉展开中、或抽屉已打开——两者都由这个按钮发起，收起后一同复位
    private var toolsButtonActive: Bool {
        session.expandedMenu == .tools || session.activeTool != nil
    }

    /// 标签右键菜单（R11 / R28）：六项固定顺序，作用对象是右键点中的那张标签，
    /// 弹出菜单本身不改变活动标签。作用集合与置灰判定都取自会话的同一份计算（KTD17），
    /// 收尾也共用关闭族那一条两阶段路径——视图层不做「边确认边关」
    @ViewBuilder
    private func tabContextMenu(at index: Int) -> some View {
        let targets = session.tabCloseTargets(at: index)
        let tab = session.tabs.indices.contains(index) ? session.tabs[index] : nil
        Button("关闭当前文件") { session.closeTabs(at: targets.current, selecting: tab) }
        Button("关闭非当前文件") { session.closeTabs(at: targets.others, selecting: tab) }
            .disabled(targets.others.isEmpty)
        Divider()
        Button("关闭左边所有") { session.closeTabs(at: targets.left, selecting: tab) }
            .disabled(targets.left.isEmpty)
        Button("关闭右边所有") { session.closeTabs(at: targets.right, selecting: tab) }
            .disabled(targets.right.isEmpty)
        Button("关闭所有") { session.closeTabs(at: targets.all, selecting: tab) }
        Divider()
        // 未标题标签没有文件可定位，置灰；文件已从磁盘消失时由会话给一次明确提示
        Button("打开文件所在位置") { session.revealInFinder(tab) }
            .disabled(tab?.fileURL == nil)
    }

    /// 右上角设置按钮：打开主窗口左侧设置抽屉
    private var settingsButton: some View {
        Button {
            session.toggleSettings()
        } label: {
            gearIcon
        }
    }

    private var gearIcon: some View {
        Image(systemName: session.isSettingsPresented ? "gearshape.fill" : "gearshape")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .accessibilityLabel("设置")
    }

    /// 扳手按钮：展开 / 收起工具下拉（其中列出五个工具，当前打开的一项带勾选）。
    /// 激活时扳手逆时针拧转 20° 并染上强调色，是"工具已打开"最直接的提示
    private var toolsButton: some View {
        Button {
            session.expandedMenu = session.expandedMenu == .tools ? nil : .tools
        } label: {
            Image(systemName: "wrench")
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(toolsButtonActive ? -20 : 0))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .accessibilityLabel("工具")
        }
    }

}

private struct TabButtonView: View {
    @ObservedObject var tab: EditorTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @StateObject private var hover = InterfaceHoverState()

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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? InterfaceStyle.raised : (hover.isHovered ? InterfaceStyle.accentSoft : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? InterfaceStyle.accentBorder : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if isSelected {
                Capsule()
                    .fill(InterfaceStyle.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 9)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover.isHovered = $0 }
        .animation(Motion.control, value: isSelected)
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
