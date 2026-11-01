//
//  ThemesView.swift
//  KyPost
//
//  Theme settings (iOS): the appearance mode (System, Light, Dark) and the
//  six suite pairs, each previewing both halves. macOS shows the same
//  choices in Settings → Appearance (`MacPreferencesView`).
//

import SwiftUI

struct ThemesView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                Picker("Appearance", selection: modeBinding) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows this device's light or dark setting.")
            }
            .listRowBackground(theme.panel)

            Section {
                ForEach(AppTheme.pairs) { pair in
                    Button {
                        themeManager.setPair(pair)
                    } label: {
                        HStack(spacing: 12) {
                            ThemePairPreview(pair: pair)
                            Text(pair.name)
                                .font(AppFont.ui(15, weight: .medium))
                                .foregroundStyle(theme.inkStrong)
                            Spacer()
                            if themeManager.pair.id == pair.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(themeManager.pair.id == pair.id ? .isSelected : [])
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Each theme has a light and a dark half. Themes are shared with the web and Android apps.")
            }
            .listRowBackground(theme.panel)
        }
        .tint(theme.accent)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Theme")
    }

    private var modeBinding: Binding<AppearanceMode> {
        Binding(get: { themeManager.mode }, set: { themeManager.setMode($0) })
    }
}

/// Both halves of a pair side by side: each half's background with its
/// panel and accent on it. Shared by the iOS and macOS theme settings.
struct ThemePairPreview: View {
    let pair: ThemePair

    var body: some View {
        HStack(spacing: 0) {
            half(pair.light)
            half(pair.dark)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.gray.opacity(0.4), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private func half(_ palette: ThemePalette) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(palette.panel)
                .frame(width: 10, height: 14)
            Circle()
                .fill(palette.accent)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background(palette.bg)
    }
}
