//
//  ButtonStyles.swift
//  KyPost
//
//  Button vocabulary from STYLE_GUIDE §4. 10pt radius (soft rectangle, not a
//  pill); press feedback is a native opacity dip, not web's translateY.
//

import SwiftUI

/// Solid accent fill (web .users-create-submit).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.ui(15, weight: .semibold))
            .foregroundStyle(theme.readableOnAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: Shape.button))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Ghost/secondary: transparent, 1pt line stroke, strong ink text
/// (web .notifications-ghost).
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.ui(15, weight: .medium))
            .foregroundStyle(theme.inkStrong)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Shape.button)
                    .strokeBorder(theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Danger: 1pt stroke + the theme's danger tint, never the accent
/// (web .users-action-danger).
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.ui(15, weight: .medium))
            .foregroundStyle(theme.danger)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Shape.button)
                    .fill(theme.dangerSoft)
                    .strokeBorder(theme.danger.opacity(0.4), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
