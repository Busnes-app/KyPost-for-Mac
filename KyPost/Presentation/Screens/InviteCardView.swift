//
//  InviteCardView.swift
//  KyPost
//
//  The invite card above a message body: what, when, where, who organises
//  it, the notices that qualify any of that, Join meeting, Add to Calendar,
//  and RSVP.
//

import SwiftUI

struct InviteCardView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    let model: InviteCardModel
    let invite: CalendarInvite
    /// The sender's address as the reader shows it, for the organizer check.
    let senderEmail: String
    let phishing: Bool

    var body: some View {
        let event = invite.primary
        VStack(alignment: .leading, spacing: 8) {
            Text(invite.method.isEmpty
                 ? String(localized: "Calendar invite")
                 : String(localized: "Calendar invite · \(invite.method)"))
                .font(AppFont.ui(11, weight: .semibold))
                .foregroundStyle(theme.secondaryInk)
                .textCase(.uppercase)

            Text(event.summary.isEmpty ? String(localized: "Untitled event") : event.summary)
                .font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
                .fixedSize(horizontal: false, vertical: true)

            if invite.isCancelled {
                Text("Cancelled")
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(theme.danger)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(inviteWhenText(event, zone: .current, locale: .current))
                if !event.rrule.isEmpty {
                    Text("Repeats")
                }
                if !event.location.isEmpty {
                    Text("Where: \(event.location)")
                }
                if !event.organizer.isEmpty {
                    // The bare address, never the sender-chosen CN.
                    (Text("Organizer: ") + Text(event.organizer).font(AppFont.mono(12)))
                }
            }
            .font(AppFont.ui(12))
            .foregroundStyle(theme.ink)
            .textSelection(.enabled)

            let notices = inviteNotices(invite, senderEmail: senderEmail, phishing: phishing, prior: model.prior)
            if !notices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notices, id: \.self) { notice in
                        Text(notice)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(AppFont.ui(12))
                .foregroundStyle(theme.inkStrong)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.dangerSoft, in: RoundedRectangle(cornerRadius: Shape.field))
            }

            // https only (parser); opens in the system browser.
            if let url = invite.joinURL, let host = url.host() {
                Button {
                    openURL(url)
                } label: {
                    Text("Join meeting (\(host))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 320)
            }

            HStack(spacing: 8) {
                if invite.offersAdd {
                    Button {
                        Task {
                            await model.requestAdd(
                                hostileLocationProtection: SingletonGraph.shared.hostileLocationProtectionStore.enabled
                            )
                        }
                    } label: {
                        if model.isAdding {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Add to Calendar")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(width: 160)
                    .disabled(model.isAdding)
                }
                if model.offersRsvp {
                    ForEach(Rsvp.allCases, id: \.self) { answer in
                        Button(rsvpButtonTitle(answer)) {
                            Task { await model.requestRsvp(answer, senderEmail: senderEmail) }
                        }
                        .font(AppFont.ui(12, weight: .medium))
                        .buttonStyle(.bordered)
                        .disabled(!model.canAnswer)
                    }
                }
                Spacer(minLength: 0)
            }

            ForEach([priorNote, model.rsvpProblem, model.rsvpMessage, model.handoffMessage].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.needsReload {
                Button("Reload invitation") {
                    Task { await model.reload() }
                }
                .font(AppFont.ui(12, weight: .medium))
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.panel))
        .alert(
            "Send RSVP unencrypted?",
            isPresented: Binding(
                get: { model.presentedRsvp != nil },
                set: { if !$0, let pending = model.pendingRsvp { model.rsvpPromptDismissed(pending) } }
            ),
            presenting: model.presentedRsvp
        ) { pending in
            Button("Send unencrypted") { model.confirmRsvp(pending) }
            Button("Cancel", role: .cancel) { model.cancelRsvp(pending) }
        } message: { pending in
            Text(pending.message)
        }
        .alert(
            "Hand off to your calendar?",
            isPresented: Binding(
                get: { model.presentedHandoff != nil },
                set: { if !$0 { model.pendingHandoff = nil } }
            ),
            presenting: model.presentedHandoff
        ) { pending in
            Button("Add to Calendar") { Task { await model.add(pending) } }
            Button("Cancel", role: .cancel) { model.pendingHandoff = nil }
        } message: { _ in
            Text("Hostile Location Protection is on. Your calendar will store this event outside KyPost, where a wipe can't remove it.")
        }
        // An alert sits above the lock cover on macOS, so the lock withdraws
        // both prompts rather than leaving them answerable behind it.
        .onChange(of: SingletonGraph.shared.appLockManager.isLocked) { _, locked in
            if locked { model.lockEngaged() }
        }
    }

    /// "You accepted." for a revision already answered.
    private var priorNote: String? {
        guard invite.method == "REQUEST", case .same(let answer) = model.prior else { return nil }
        return String(localized: "You \(answeredText(answer)).")
    }

    private func rsvpButtonTitle(_ answer: Rsvp) -> String {
        switch answer {
        case .accepted: String(localized: "Accept")
        case .tentative: String(localized: "Maybe")
        case .declined: String(localized: "Decline")
        }
    }
}
