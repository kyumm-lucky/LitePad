import SwiftUI

/// 保存时清理的按语法排除表：勾中的语法在保存时保留原样
/// （Markdown 的行尾双空格是硬换行、补丁文件的空行有意义，这类格式不能删行尾空白）
struct SaveCleanupExclusionList: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var hover = SettingsIndexHoverState()

    var body: some View {
        let languages = LanguageDefinition.all
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.square")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.accent)
                Text("不清理这些语法")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(settings.saveCleanupExcludedLanguageIDs.count)/\(languages.count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(InterfaceStyle.muted)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rectangle()
                .fill(InterfaceStyle.border)
                .frame(height: 1)
                .padding(.horizontal, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(languages.indices, id: \.self) { index in
                        let language = languages[index]
                        // 行的画法与无障碍语义共用这一个判定：两边各取一次会在同一帧里读出两种状态
                        let excluded = settings.isSaveCleanupExcluded(language)
                        Button {
                            settings.setSaveCleanupExcluded(!excluded, for: language)
                        } label: {
                            row(language, index: index, excluded: excluded)
                        }
                        .buttonStyle(.plain)
                        .onHover { hover.index = $0 ? index : nil }
                        // 勾选状态只由一个图标符号的两种画法表达，VoiceOver 读不出来：
                        // 按工程既有口径补上名称、状态与选中特征（与 LitePadToggle、LiquidSegmented 一致）
                        .accessibilityLabel("\(language.displayName) \(language.extensions.joined(separator: " / "))")
                        .accessibilityValue(excluded ? "已排除" : "未排除")
                        .accessibilityAddTraits(excluded ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 300, height: 150, alignment: .topLeading)
        .background(FrostedSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(InterfaceStyle.borderStrong, lineWidth: 1)
        )
    }

    /// 一行语法：勾选框 + 语法名 + 归属的扩展名（落到该语法的文件都会受影响）
    private func row(_ language: LanguageDefinition, index: Int, excluded: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: excluded ? "checkmark.square.fill" : "square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(excluded ? InterfaceStyle.accent : InterfaceStyle.muted)
            Text(language.displayName)
                .font(.system(size: 11, weight: excluded ? .medium : .regular))
                .foregroundStyle(excluded ? .primary : InterfaceStyle.muted)
                .lineLimit(1)
            Text(language.extensions.joined(separator: " / "))
                .font(.system(size: 9))
                .foregroundStyle(InterfaceStyle.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(excluded
                      ? InterfaceStyle.accentSoft
                      : (hover.index == index ? InterfaceStyle.raised : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(excluded ? InterfaceStyle.accentBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
