//
//  StatusText.swift
//  KyPost
//
//  A status sentence in the theme's status colour, always led by its icon:
//  a status is never told by colour alone (ky-ui 0.8.0).
//

import SwiftUI

enum StatusKind: Sendable {
    case danger, warning, success

    var systemImage: String {
        switch self {
        case .danger: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    func color(in theme: ThemePalette) -> Color {
        switch self {
        case .danger: theme.danger
        case .warning: theme.warning
        case .success: theme.success
        }
    }
}

struct StatusText: View {
    @Environment(\.theme) private var theme

    let text: Text
    let kind: StatusKind
    /// Nil keeps the surrounding font (a form row's value).
    var size: CGFloat?
    var weight: Font.Weight = .regular

    /// A literal is looked up like `Text("…")`; a String variable is shown as is.
    init(_ key: LocalizedStringKey, kind: StatusKind, size: CGFloat? = 13, weight: Font.Weight = .regular) {
        self.init(text: Text(key), kind: kind, size: size, weight: weight)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S, kind: StatusKind, size: CGFloat? = 13, weight: Font.Weight = .regular) {
        self.init(text: Text(text), kind: kind, size: size, weight: weight)
    }

    private init(text: Text, kind: StatusKind, size: CGFloat?, weight: Font.Weight) {
        self.text = text
        self.kind = kind
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: kind.systemImage)
                .accessibilityHidden(true)
        }
        .font(size.map { AppFont.ui($0, weight: weight) })
        .foregroundStyle(kind.color(in: theme))
    }
}
