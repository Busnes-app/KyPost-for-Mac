//
//  ToastView.swift
//  KyPost
//
//  Bottom-anchored transient message, shared by the contact list's sync
//  status and compose's duplicate-recipient notice.
//

import SwiftUI

struct ToastView: View {
    @Environment(\.theme) private var theme

    let message: String
    /// A failure or warning: the status icon and colour on its tint.
    var kind: StatusKind?

    var body: some View {
        Group {
            if let kind {
                StatusText(message, kind: kind)
            } else {
                Text(message)
                    .font(AppFont.ui(13))
                    .foregroundStyle(theme.inkStrong)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
        .padding(.bottom, 10)
    }

    private var fill: Color {
        switch kind {
        case .danger: theme.dangerSoft
        case .warning: theme.warningSoft
        case .success: theme.successSoft
        case nil: theme.panel
        }
    }
}

extension View {
    /// Shows `message` over the bottom of this view, or nothing when nil.
    ///
    /// A pure renderer: dismissal is the caller's business. The contact
    /// screens pass a sync status that's meant to persist until it changes,
    /// while compose expires its own toast on a timer — so a timer in here
    /// would be wrong for half the callers.
    func toast(message: String?, kind: StatusKind? = nil) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                ToastView(message: message, kind: kind)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}
