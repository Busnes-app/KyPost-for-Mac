//
//  KeywordTabView.swift
//  KyPost
//
//  Pill filter tabs (STYLE_GUIDE §4, web .inbox-page-tab): stadium chips,
//  inactive = transparent + line stroke, active = accent fill + readable text.
//

import SwiftUI

struct KeywordTabView: View {
    @Environment(\.theme) private var theme

    let tabs: [KeywordTab]
    /// The All chip is hideable like any keyword (Keyword Settings).
    var showsAll = true
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if showsAll {
                    chip(name: String(localized: "All"), count: nil, isActive: selected == nil) {
                        selected = nil
                    }
                }
                ForEach(tabs, id: \.name) { tab in
                    chip(name: tab.name, count: tab.count, isActive: selected == tab.name) {
                        selected = tab.name
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func chip(
        name: String,
        count: Int?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(name)
                if let count {
                    Text("\(count)")
                        .opacity(0.7)
                }
            }
            .font(AppFont.ui(13, weight: .medium))
            .foregroundStyle(isActive ? theme.readableOnAccent : theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isActive {
                    Capsule().fill(theme.accent)
                } else {
                    Capsule().strokeBorder(theme.line, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}
