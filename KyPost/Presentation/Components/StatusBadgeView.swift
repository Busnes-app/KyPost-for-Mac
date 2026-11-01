//
//  StatusBadgeView.swift
//  KyPost
//
//  Status badge + dot (STYLE_GUIDE §4, web .contacts-status-active/inactive):
//  pill outline with a leading circular dot. Active uses the fixed success
//  colors; inactive uses the palette's line/ink.
//

import SwiftUI

struct StatusBadgeView: View {
    @Environment(\.theme) private var theme

    let label: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? theme.success : theme.line)
                .frame(width: 7, height: 7)
            Text(label)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(isActive ? theme.success : theme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().strokeBorder(
                isActive ? theme.success : theme.line,
                lineWidth: 1
            )
        )
    }
}
