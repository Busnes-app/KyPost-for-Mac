//
//  ContactSuggestionsDropdown.swift
//  KyPost
//
//  The floating match list under a compose address field
//  (ContactAutocomplete.md §2).
//

import SwiftUI

struct ContactSuggestionsDropdown: View {
    @Environment(\.theme) private var theme

    let matches: [ContactMatch]
    /// nil means nothing is highlighted — see ComposeView's key handling for
    /// why that's the resting state.
    let highlighted: Int?
    let onHighlight: (Int?) -> Void
    let onSelect: (ContactMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text("No contacts found")
                    .font(AppFont.ui(13))
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                    row(match, isHighlighted: index == highlighted)
                        .onHover { inside in
                            onHighlight(inside ? index : nil)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: Shape.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Shape.panel)
                .strokeBorder(theme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    private func row(_ match: ContactMatch, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(name: match.entry.displayName, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HighlightedText(
                    text: match.entry.displayName,
                    highlight: match.nameHighlight,
                    font: AppFont.ui(13),
                    highlightFont: AppFont.ui(13, weight: .bold)
                )
                .foregroundStyle(theme.inkStrong)
                .lineLimit(1)

                HighlightedText(
                    text: match.entry.address,
                    highlight: match.addressHighlight,
                    font: AppFont.mono(11),
                    highlightFont: AppFont.mono(11, weight: .bold)
                )
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            // Tells apart two rows for the same person.
            if let label = match.entry.addressLabel, !label.isEmpty {
                Text(label)
                    .font(AppFont.ui(10))
                    .foregroundStyle(theme.secondaryInk)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? theme.panel : .clear)
        // Deliberately not a Button: on macOS a Button steals first
        // responder, which drops the field's focus and tears this view down
        // before the action can run — the click would do nothing.
        .contentShape(Rectangle())
        .onTapGesture { onSelect(match) }
    }
}
