import SwiftUI

struct CodexSettingsView: View {
    @AppStorage(CodexThemeSettings.Keys.appearanceMode) private var appearanceMode = CodexThemeSettings.defaultAppearanceMode
    @AppStorage(CodexThemeSettings.Keys.contrast) private var contrast = CodexThemeSettings.defaultContrast

    var body: some View {
        VStack(alignment: .leading, spacing: CodexTheme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings")
                    .font(ProfileManagerTypography.title)
                    .foregroundStyle(CodexTheme.primaryText)

                Text("Choose the room brightness that helps you focus.")
                    .font(ProfileManagerTypography.body)
                    .foregroundStyle(CodexTheme.mutedText)
            }

            CodexCard(tier: .regular, shadow: false) {
                VStack(alignment: .leading, spacing: 16) {
                    CodexSettingsPickerRow(title: "Appearance") {
                        Picker("Appearance", selection: $appearanceMode) {
                            ForEach(CodexThemeAppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    Divider()
                        .overlay(CodexTheme.surfaceBorder(for: .subtle))

                    CodexSettingsPickerRow(title: "Contrast") {
                        Picker("Contrast", selection: $contrast) {
                            ForEach(CodexThemeContrast.allCases) { contrast in
                                Text(contrast.title).tag(contrast)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .topLeading)
        .background(CodexBackdrop())
        .codexThemeRefreshScope()
    }
}

private struct CodexSettingsPickerRow<Control: View>: View {
    let title: String
    let control: Control

    init(title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(ProfileManagerTypography.bodyStrong)
                .foregroundStyle(CodexTheme.primaryText)
                .frame(width: 96, alignment: .leading)

            control
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
