//
//  EmailListRow.swift
//  KyPost
//
//  One inbox row: avatar, sender, subject, keyword chips, unread indicator.
//

import Combine
import SwiftUI

extension EnvironmentValues {
    /// Whether this device holds an enrolled OpenPGP key.
    ///
    /// Defaults to false, which is the safe direction: a row that wrongly
    /// promises "unlock to read" on a device that cannot sends the user to a
    /// prompt with no way through, while the reverse merely points them at
    /// webmail they could have used anyway.
    @Entry var deviceIsEnrolled: Bool = false

    /// "Now" for row dates. Set by `relabelsAtMidnight()` so yesterday's
    /// times turn into dates when the day changes, without a refresh.
    @Entry var inboxToday: Date = .now
}

private struct RelabelsAtMidnight: ViewModifier {
    @State private var today = Date.now

    func body(content: Content) -> some View {
        content
            .environment(\.inboxToday, today)
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                today = .now
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                today = .now
            }
    }
}

extension View {
    /// Re-renders row dates at midnight and on a time-zone change.
    func relabelsAtMidnight() -> some View {
        modifier(RelabelsAtMidnight())
    }
}

struct EmailListRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.deviceIsEnrolled) private var deviceIsEnrolled
    @Environment(\.inboxToday) private var today

    let email: Email

    /// The PGP marker's spelled-out label when there is one, plus the
    /// paperclip's — VoiceOver announces neither glyph reliably on its own.
    private var rowAccessibilityLabel: String {
        var base = pgpRowAccessibilityLabel(
            state: rowPgpState,
            subject: email.subject,
            deviceIsEnrolled: deviceIsEnrolled
        ) ?? email.subject
        if isPhishing {
            base = "Suspected impersonation of KyPost: \(base)"
        }
        return email.hasAttachments ? "\(base), has attachments" : base
    }

    /// User-facing labels only — IMAP system keywords like `$Phishing` drive
    /// the warning, not a chip.
    private var labelChips: [String] {
        email.keywords.filter { !isSystemKeyword($0) }.sorted()
    }

    private var isPhishing: Bool { isFlaggedPhishing(email.keywords) }

    private var rowPgpState: PgpMessageState {
        pgpMessageState(
            pgpEncrypted: email.pgpEncrypted,
            pgpDecryptError: email.pgpDecryptError,
            body: email.body
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: email.senderName.isEmpty ? email.senderEmail : email.senderName)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(email.senderName.isEmpty ? email.senderEmail : email.senderName)
                        .font(AppFont.ui(15, weight: email.read ? .regular : .semibold))
                        .foregroundStyle(theme.inkStrong)
                        .lineLimit(1)
                    Spacer()
                    if email.wokenAt != nil {
                        chip(Text("Snoozed"))
                    }
                    // Time for today, a medium date otherwise, blank when the
                    // relay sent none — in the device's zone.
                    Text(InboxRules.rowDate(email.receivedAt, now: today))
                        .font(AppFont.ui(12))
                        .foregroundStyle(theme.ink.opacity(0.7))
                }
                HStack(spacing: 5) {
                    if isPhishing {
                        // Outranks the PGP marker: a message impersonating
                        // KyPost is the more urgent thing to say about it.
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(AppFont.ui(12))
                            .foregroundStyle(SemanticColors.danger)
                    }
                    if let symbol = pgpRowSymbol(rowPgpState) {
                        Image(systemName: symbol)
                            .font(AppFont.ui(12))
                            .foregroundStyle(theme.ink.opacity(0.8))
                    }
                    Text(email.subject)
                        .font(AppFont.ui(14, weight: email.read ? .regular : .medium))
                        .foregroundStyle(email.read ? theme.ink : theme.inkStrong)
                        .lineLimit(1)
                    if email.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(AppFont.ui(11))
                            .foregroundStyle(theme.ink.opacity(0.7))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(rowAccessibilityLabel)
                if !labelChips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(labelChips, id: \.self) { keyword in
                            chip(Text(keyword))
                        }
                    }
                }
            }

            if !email.read {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func chip(_ label: Text) -> some View {
        label
            .font(AppFont.ui(11, weight: .medium))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(theme.line, lineWidth: 1))
    }
}
