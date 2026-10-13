//
//  InboxListChrome.swift
//  KyPost
//
//  The small pieces around the mail list that both shells share: the
//  freshness line, the Undo bar, and the "N new messages" pill.
//

import SwiftUI

/// "Updated 3 minutes ago" for the folder on screen, or "Not updated yet"
/// before its first successful refresh. Re-renders on its own as time passes.
struct FreshnessLine: View {
    @Environment(\.theme) private var theme

    let lastRefreshed: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(InboxRules.freshnessText(refreshedAt: lastRefreshed, now: context.date))
                .font(AppFont.ui(11))
                .foregroundStyle(theme.ink.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
    }
}

/// One bar for every action held in the undo window. The caller owns its
/// lifetime (the view model's timer), so this is a pure renderer.
struct UndoBar: View {
    @Environment(\.theme) private var theme

    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(message)
                .font(AppFont.ui(13))
                .foregroundStyle(theme.inkStrong)
                .lineLimit(1)
            Button("Undo", action: onUndo)
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }
}

/// Shown over the list when mail landed above the top while the user was
/// scrolled away. Tapping it scrolls up.
struct NewMailPill: View {
    @Environment(\.theme) private var theme

    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                count == 1
                    ? String(localized: "1 new message")
                    : String(localized: "\(count) new messages"),
                systemImage: "arrow.up"
            )
            .font(AppFont.ui(13, weight: .medium))
            .foregroundStyle(theme.inkStrong)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension View {
    /// The Undo bar, over the bottom of the inbox screen.
    func undoBar(_ viewModel: InboxViewModel) -> some View {
        overlay(alignment: .bottom) {
            if let message = viewModel.undoMessage {
                UndoBar(message: message) { viewModel.undoHeldActions() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.undoMessage)
    }

    /// The "N new messages" pill, over the top of the list itself so it never
    /// covers the tab strip.
    func newMailPill(_ viewModel: InboxViewModel) -> some View {
        overlay(alignment: .top) {
            if viewModel.newMailCount > 0 {
                NewMailPill(count: viewModel.newMailCount) { viewModel.acknowledgeNewMail() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.newMailCount)
    }

    /// Reports whether the list is scrolled to its top, so new mail is shown
    /// in place there and announced by the pill elsewhere.
    func reportsScrollTop(to viewModel: InboxViewModel) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top <= 8
        } action: { _, atTop in
            viewModel.listScrolled(atTop: atTop)
        }
    }
}
