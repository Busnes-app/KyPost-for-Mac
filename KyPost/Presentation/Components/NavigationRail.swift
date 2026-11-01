//
//  NavigationRail.swift
//  KyPost
//
//  The iOS shell's navigation rail for regular-width windows (the unfolded
//  iPhone Duo, iPad): Inbox, Contacts and Settings stacked on the trailing
//  edge. Always on the right (`ShellNavigation`).
//

import SwiftUI

struct NavigationRail: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AppTab

    static let width: CGFloat = 84

    var body: some View {
        VStack(spacing: 14) {
            item(.inbox, title: "Inbox", systemImage: "tray")
            item(.contacts, title: "Contacts", systemImage: "person.2")
            item(.settings, title: "Settings", systemImage: "gearshape")
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(theme.panel.ignoresSafeArea())
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.line)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
    }

    private func item(_ tab: AppTab, title: LocalizedStringKey, systemImage: String) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                // Outline unless selected; never accent on accent-soft.
                Image(systemName: selected ? systemImage + ".fill" : systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(selected ? theme.inkStrong : theme.secondaryInk)
                    .frame(width: 56, height: 32)
                    .background(selected ? theme.accentSoft : .clear, in: Capsule())
                Text(title)
                    .font(AppFont.ui(12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? theme.inkStrong : theme.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
