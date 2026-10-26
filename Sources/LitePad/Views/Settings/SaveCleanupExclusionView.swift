import SwiftUI

/// 保存时清理的按语法排除表：勾中的语法在保存时保留原样
/// （Markdown 的行尾双空格是硬换行、补丁文件的空行有意义，这类格式不能删行尾空白）。
/// 外观与编码优先级表同一套分组卡片与复选行，逻辑不变
struct SaveCleanupExclusionSheet: View {
    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    private let languages = LanguageDefinition.all

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("勾选的语法在保存时保留原样；未勾选的语法会被清理。"))
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.text2)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.vertical, showsIndicators: false) {
                SettingsGroup(L10n.t("例外语法")) {
                    ForEach(languages.indices, id: \.self) { index in
                        let language = languages[index]
                        SettingsCheckboxRow(title: language.displayName,
                                            detail: language.extensions.joined(separator: " / "),
                                            showsDivider: index > 0,
                                            isOn: binding(for: language))
                    }
                }
            }
            .frame(height: 320)

            HStack {
                Spacer(minLength: 0)
                SettingsAccentButton(title: L10n.t("完成"), isDefault: true) { onClose() }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(SettingsStyle.window)
    }

    private func binding(for language: LanguageDefinition) -> Binding<Bool> {
        Binding(get: { settings.isSaveCleanupExcluded(language) },
                set: { settings.setSaveCleanupExcluded($0, for: language) })
    }
}
