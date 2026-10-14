//
//  RecipientTokenField.swift
//  KyPost
//
//  A compose address field: committed recipients as pills, followed by an
//  input that wraps onto new lines (ContactAutocomplete.md §2).
//

import SwiftUI

struct RecipientTokenField: View {
    @Environment(\.theme) private var theme

    let placeholder: String
    @Binding var tokens: [RecipientToken]
    @Binding var input: String
    /// Commit whatever is typed (Return, a separator, or losing focus).
    let onCommit: () -> Void
    let onRemove: (RecipientToken) -> Void

    var body: some View {
        FlowLayout {
            ForEach(tokens) { token in
                pill(token)
            }
            TextField(tokens.isEmpty ? placeholder : "", text: $input)
                .textFieldStyle(.plain)
                .font(AppFont.mono(13))
                .foregroundStyle(theme.inkStrong)
                .onSubmit(onCommit)
                .flowGreedy()
        }
        // Typing a separator is a commit — it's what people do out of habit.
        .onChange(of: input) { _, text in
            guard text.hasSuffix(",") || text.hasSuffix(";") else { return }
            input = String(text.dropLast())
            onCommit()
        }
    }

    private func pill(_ token: RecipientToken) -> some View {
        HStack(spacing: 6) {
            if token.isContactBacked {
                AvatarView(name: token.label, size: 16)
            }
            // A bare address in mono is the honest tell that this recipient
            // isn't in the address book.
            Text(token.label)
                .font(token.isContactBacked ? AppFont.ui(12, weight: .medium) : AppFont.mono(12))
                .foregroundStyle(theme.inkStrong)
                .lineLimit(1)
            Button {
                onRemove(token)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.secondaryInk)
            }
            .buttonStyle(.plain)
            .help("Remove \(token.address)")
            .accessibilityLabel("Remove \(token.address)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
        .help(token.address)
    }
}
