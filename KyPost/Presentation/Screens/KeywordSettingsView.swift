//
//  KeywordSettingsView.swift
//  KyPost
//
//  Show/hide toggles per keyword (spec §2, §9), led by the All tab, which is
//  hideable like any keyword. Keywords come from the cached inbox;
//  visibility persists in KeywordSettingsStore.
//

import SwiftUI

struct KeywordSettingsView: View {
    @Environment(\.theme) private var theme

    let viewModel: SettingsViewModel

    var body: some View {
        List {
            // All is app-owned and pinned first: it is not part of the
            // reorderable keyword list, so it carries no move handle.
            Toggle(
                "All",
                isOn: Binding(
                    get: { viewModel.allTabVisible },
                    set: { viewModel.setAllTabVisible($0) }
                )
            )
            .font(AppFont.ui(15))
            .listRowBackground(theme.panel)

            if viewModel.keywordSettings.isEmpty {
                Text("No keywords yet — they appear after your first inbox refresh.")
                    .font(AppFont.ui(14))
                    .foregroundStyle(theme.ink.opacity(0.75))
                    .listRowBackground(theme.panel)
            } else {
                ForEach(viewModel.keywordSettings) { setting in
                    Toggle(
                        setting.name,
                        isOn: Binding(
                            get: { setting.visible },
                            set: { viewModel.setKeywordVisible($0, for: setting.name) }
                        )
                    )
                    .font(AppFont.ui(15))
                    .listRowBackground(theme.panel)
                }
                .onMove(perform: viewModel.moveKeywords)
            }
        }
        .scrollContentBackground(.hidden)
#if os(iOS)
        .environment(\.editMode, .constant(.active))
#endif
        .background(theme.bg)
        .navigationTitle("Keyword Settings")
        .task { await viewModel.loadKeywordSettings() }
    }
}
