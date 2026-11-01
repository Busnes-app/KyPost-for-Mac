//
//  EmptyStateView.swift
//  KyPost
//
//  Empty state (STYLE_GUIDE §4, web .inbox-empty-state): dashed 1pt
//  accent-tinted border, centered muted text, 10pt radius. Unframed, it is
//  only the muted icon and text (the empty reader, as Gmail leaves it).
//

import SwiftUI

struct EmptyStateView: View {
    @Environment(\.theme) private var theme

    let message: String
    var systemImage: String?
    var framed = true

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(theme.secondaryInk)
            }
            Text(message)
                .font(AppFont.ui(14))
                .foregroundStyle(theme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background {
            if framed {
                RoundedRectangle(cornerRadius: Shape.emptyState)
                    .strokeBorder(
                        theme.accent.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            }
        }
        .padding()
    }
}
