//
//  SecuritySettingsView.swift
//  KyPost
//
//  Security settings (security-hardening plan, Task 3): the three toggles
//  with Android's order and dependency rules, plus the certificate-pin
//  status row. Shared row content feeds both the iOS screen here and
//  MacPreferencesView's Security pane.
//
//  Every *off* path re-authenticates. Turning a protection off is the
//  destructive direction, and the pane is reachable from the macOS menu bar.
//

import SwiftUI

/// The section rows, shared by the iOS Form screen and the macOS pane.
struct SecuritySettingsContent: View {
    @Environment(\.theme) private var theme

    private var lockManager: AppLockManager { SingletonGraph.shared.appLockManager }
    @State private var lockToggleMessage: String?
    @State private var enrollmentShown = false
    @State private var hostileConfirmationShown = false
    @State private var hostileProtectionMessage: String?
    private var gateService: CredentialGateService { SingletonGraph.shared.credentialGateService }
    /// Whether a certificate pin is actually stored for the paired relay.
    private var isRelayPinned: Bool {
        !(SingletonGraph.shared.securePairingStore.pinnedSpkiHash ?? "").isEmpty
    }
    @State private var credentialGateConfirmationShown = false
    @State private var credentialGateMessage: String?
    @State private var pinSheet: PinSheet?
    @State private var pinMessage: String?

    /// One value for both actions so they cannot be presented at once.
    enum PinSheet: String, Identifiable {
        case set, change
        var id: String { rawValue }
    }

    var body: some View {
        Section {
            Toggle("Require Unlock to Open", isOn: lockEnabledBinding)
            Picker("Lock", selection: graceBinding) {
                ForEach(LockGracePeriod.options, id: \.self) { seconds in
                    Text(Self.graceLabel(seconds)).tag(seconds)
                }
            }
            .disabled(!lockManager.isLockEnabled)
            if let lockToggleMessage {
                Text(lockToggleMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
            }
        } footer: {
            Text("Unlocks with Face ID, Touch ID, or this device's passcode. KyPost locks when it goes to the background (iOS) or the screen locks (Mac), after the delay chosen above. Choosing a longer delay asks you to authenticate.")
        }

        Section {
            if lockManager.hasPin {
                Button("Change PIN…") { pinSheet = .change }
                Button("Remove PIN", role: .destructive) { removePin() }
                Picker("Erase Data After", selection: wipeThresholdBinding) {
                    ForEach(WipeThreshold.choices, id: \.self) { threshold in
                        Text(Self.thresholdLabel(threshold)).tag(threshold)
                    }
                }
            } else {
                Button("Set a PIN…") { pinSheet = .set }
                    .disabled(!lockManager.isLockEnabled)
            }
            if let pinMessage {
                Text(pinMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
            }
        } header: {
            Text("App PIN")
        } footer: {
            // The erasure is stated here as well as in the sheet. This is the
            // screen someone reads while deciding, and a consequence that only
            // appears once they have already decided is not a disclosure.
            Text(pinFooter)
        }
        .sheet(item: $pinSheet) { sheet in
            AppPinSetupView(manager: lockManager, isChange: sheet == .change)
                .environment(\.theme, theme)
        }

        Section {
            Toggle("Hostile Location Protection", isOn: hostileProtectionBinding)
                .disabled(!lockManager.isLockEnabled)
            if let hostileProtectionMessage {
                Text(hostileProtectionMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
            }
        } footer: {
            // The limitation leads. This feature's stated use case is border
            // crossings, and that is the one context where "removed from the
            // file system" and "unrecoverable" are not the same claim — the
            // blocks survive on APFS until something overwrites them.
            Text("Important: this removes files, it does not overwrite them. Someone with forensic tools and physical possession of an unlocked device may still recover data that was cached before you turned this on. Turn it on before you have anything worth finding, not after.\n\nWhile on, KyPost keeps no mail, contacts, or attachments on this device — everything reloads from your server. Requires Require Unlock to Open.\n\nAlso still on this device: attachment previews use temporary storage briefly while open; new-mail notifications you've already received stay in Notification Center; and if \"Sync with Apple Contacts\" is on, your contacts remain in the system Contacts app until you turn that off and remove them.")
        }
        .confirmationDialog(
            "Enable Hostile Location Protection?",
            isPresented: $hostileConfirmationShown,
            titleVisibility: .visible
        ) {
            Button("Remove Local Cache & Enable", role: .destructive) {
                applyHostileProtection(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes mail, contacts, contact photos, attachments, and saved drafts cached on this device, and closes open compose windows. This is a normal delete, not a forensic wipe — previously cached data may still be recoverable from the disk. Your mail stays on the server. Cards already exported to Apple Contacts are not removed — use \"Remove Exported Contacts\" for those.")
        }

        Section {
            Button("Set Up Encrypted Mail on This Device…") { enrollmentShown = true }
                .sheet(isPresented: $enrollmentShown) {
                    DeviceEnrollmentView(
                        viewModel: DeviceEnrollmentViewModel { onState in
                            SingletonGraph.shared.makeEnrollmentCeremony(onState: onState)
                        }
                    )
                    .environment(\.theme, theme)
                }
                .disabled(SingletonGraph.shared.hostileLocationProtectionStore.enabled)
        } header: {
            Text("Encrypted mail")
        } footer: {
            // States the trade rather than burying it. Enrolling is the one
            // action here that moves the account's private key onto this
            // device, and the user is choosing that, not just enabling a
            // convenience.
            Text(SingletonGraph.shared.hostileLocationProtectionStore.enabled
                ? "Unavailable while Hostile Location Protection is on — that's the mode where this device holds nothing. Turning protection on also erases a key already set up here."
                : "Lets this device read and send mail encrypted to a key only your browser holds, instead of handing off to webmail. Your PGP private key is stored on this device, protected by your lock screen. Turning on Hostile Location Protection erases it.")
        }

        Section {
            Toggle("Require unlock for notifications & MFA", isOn: credentialGateBinding)
                .disabled(!lockManager.isLockEnabled)
            if let credentialGateMessage {
                Text(credentialGateMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
            }
            pushMetadataWarning
        } footer: {
            Text("Blocks background mail checks and MFA approvals until you open and unlock KyPost. On iPhone this covers all background delivery; on a Mac it applies while the screen is locked. Requires Require Unlock to Open.")
        }
        .confirmationDialog(
            "Delay notifications until unlocked?",
            isPresented: $credentialGateConfirmationShown,
            titleVisibility: .visible
        ) {
            Button("Require Unlock for Delivery") {
                if !gateService.enable() {
                    credentialGateMessage = String(
                        localized: "Nothing to protect yet — pair this device first."
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New-mail notifications and MFA approval requests will only be delivered after you open and unlock KyPost.")
        }

        Section {
            LabeledContent("Certificate pin") {
                Text(isRelayPinned ? "Pinned" : "Not pinned")
                    .foregroundStyle(isRelayPinned ? SemanticColors.successText : SemanticColors.warning)
            }
        } footer: {
            // Arming the pin can fail silently — an unusual server key shape
            // leaves nothing to hash — and until this row existed there was no
            // way to tell a pinned device from an unpinned one.
            Text(isRelayPinned
                 ? "This device remembers your server's certificate and refuses connections that don't match it."
                 : "This device could not pin your server's certificate, so the connection relies on your device's standard certificate trust. Removing and re-adding the pairing will try again.")
        }
    }

    /// Enabling confirms first (it erases the local cache); disabling
    /// applies directly — the in-memory data is simply dropped. Both paths
    /// end in a graph rebuild, which recreates this whole view, so the
    /// toggle re-reads the store rather than mirroring it in state.
    private var hostileProtectionBinding: Binding<Bool> {
        Binding(
            get: { SingletonGraph.shared.hostileLocationProtectionStore.enabled },
            set: { enabled in
                if enabled {
                    hostileConfirmationShown = true
                } else {
                    // Turning this off silently returns a device the user
                    // configured for a hostile location to on-disk caching, so
                    // it gets the same re-auth as turning the lock off. Reachable
                    // from Preferences, which the menu bar opens while locked.
                    Task {
                        guard await lockManager.confirmWithDeviceAuth(
                            reason: String(localized: "Turn off Hostile Location Protection")
                        ) else {
                            hostileProtectionMessage = String(
                                localized: "Authentication is required to turn this off."
                            )
                            return
                        }
                        hostileProtectionMessage = nil
                        applyHostileProtection(false)
                    }
                }
            }
        )
    }

    /// Enabling confirms first (delivery stops while locked); disabling
    /// re-authenticates, then restores the plain secret.
    ///
    /// The re-auth is not incidental. `disable()` writes the device secret back
    /// out of the user-presence Keychain item and into the plain one — a bigger
    /// downgrade than "Remove Exported Contacts", which already prompts. It
    /// used to prompt for nothing at all whenever the in-memory copy was warm,
    /// which is precisely the state an unlocked, unattended Mac is in.

    /// Sits inside the section rather than in its footer, and reads as a
    /// warning rather than a note.
    ///
    /// The previous wording was a footnote saying notifications "carry the
    /// sender and subject" — true, but placed directly under a toggle whose
    /// name promises to protect notifications, which invites exactly the wrong
    /// conclusion. The toggle gates *this device's* credential and delivery;
    /// it does nothing about what already travelled through Apple and the
    /// relay to get here. Say that, and name the one setting that does fix it.
    private var pushMetadataWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SemanticColors.warning)
            Text("Push always sends the sender and subject through Apple's push service and your KyPost relay — even with this on. For zero metadata leakage, switch this device to Pull mode on your server's Notifications page.")
                .font(AppFont.ui(12))
                .foregroundStyle(theme.inkStrong)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Shape.field)
                .fill(SemanticColors.warning.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }
    private var credentialGateBinding: Binding<Bool> {
        Binding(
            get: { gateService.isEnabled },
            set: { enabled in
                if enabled {
                    credentialGateConfirmationShown = true
                    return
                }
                Task {
                    guard await lockManager.confirmWithDeviceAuth(
                        reason: String(localized: "Turn off Require Unlock for Notifications & MFA")
                    ) else {
                        credentialGateMessage = String(
                            localized: "Authentication is required to turn this off."
                        )
                        return
                    }
                    if gateService.disable() {
                        credentialGateMessage = nil
                    } else {
                        credentialGateMessage = String(
                            localized: "Could not restore the credential — try again."
                        )
                    }
                }
            }
        )
    }

    private var pinFooter: String {
        let ladder = String(localized: "An optional PIN, separate from your Mac's password. The first two wrong attempts are free; after that each one adds a wait, from 30 seconds up to 30 minutes.")
        let consequence: String
        if let attempts = lockManager.wipeThresholdSetting.attempts {
            consequence = String(localized: "\(attempts) wrong attempts in a row erase the pairing and everything KyPost has stored on this device. Your mail stays on your server.")
        } else {
            consequence = String(localized: "Wrong attempts never erase this device; only the waits above slow guessing down.")
        }
        let tail = String(localized: "Choosing a larger number, or Never, asks you to authenticate. Requires Require Unlock to Open.")
        return [ladder, consequence, tail].joined(separator: " ")
    }

    static func graceLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return String(localized: "Immediately")
        case 60: return String(localized: "After 1 minute")
        case let s where s % 60 == 0: return String(localized: "After \(s / 60) minutes")
        default: return String(localized: "After \(seconds) seconds")
        }
    }

    static func thresholdLabel(_ threshold: WipeThreshold) -> String {
        guard let attempts = threshold.attempts else { return String(localized: "Never") }
        return String(localized: "\(attempts) Failed Attempts")
    }

    /// Shortening the delay applies directly; lengthening it is the downgrade
    /// direction and re-authenticates first, like every *off* path here.
    private var graceBinding: Binding<Int> {
        Binding(
            get: { lockManager.lockGraceSeconds },
            set: { seconds in
                Task {
                    if seconds > lockManager.lockGraceSeconds {
                        guard await lockManager.confirmWithDeviceAuth(
                            reason: String(localized: "Lengthen the delay before KyPost locks")
                        ) else {
                            lockToggleMessage = String(
                                localized: "Authentication is required to lengthen the delay."
                            )
                            return
                        }
                    }
                    do {
                        try lockManager.setLockGraceSeconds(seconds)
                        lockToggleMessage = nil
                    } catch {
                        lockToggleMessage = String(localized: "Could not save the change — try again.")
                    }
                }
            }
        )
    }

    /// Lowering the threshold applies directly; raising it or choosing Never
    /// gives an attacker more guesses, so it re-authenticates first.
    private var wipeThresholdBinding: Binding<WipeThreshold> {
        Binding(
            get: { lockManager.wipeThresholdSetting },
            set: { threshold in
                Task {
                    if threshold.isLooser(than: lockManager.wipeThreshold) {
                        guard await lockManager.confirmWithDeviceAuth(
                            reason: String(localized: "Allow more wrong PIN attempts before erasing")
                        ) else {
                            pinMessage = String(
                                localized: "Authentication is required to allow more attempts."
                            )
                            return
                        }
                    }
                    do {
                        try lockManager.setWipeThreshold(threshold)
                        pinMessage = nil
                    } catch {
                        pinMessage = String(localized: "Could not save the change — try again.")
                    }
                }
            }
        )
    }

    /// Removing the PIN is a downgrade, so it re-authenticates first — the same
    /// rule every other *off* path on this screen follows.
    private func removePin() {
        Task {
            guard await lockManager.confirmWithDeviceAuth(
                reason: String(localized: "Remove the KyPost PIN")
            ) else {
                pinMessage = "Authentication was cancelled, so the PIN is unchanged."
                return
            }
            do {
                try lockManager.clearPin()
                pinMessage = nil
            } catch {
                pinMessage = "Could not remove the PIN: \(error.localizedDescription)"
            }
        }
    }

    private func applyHostileProtection(_ enabled: Bool) {
        do {
            try AppEnvironment.shared.setHostileLocationProtection(enabled)
            hostileProtectionMessage = nil
        } catch {
            hostileProtectionMessage = "Could not switch modes: \(error.localizedDescription)"
        }
    }

    /// Dependency rule: toggles 2 and 3 require the lock, so dropping the lock
    /// drops them too. The credential gate has to come off *first* and its
    /// failure has to abort the whole change: its toggle is disabled while the
    /// lock is off, and once the lock is off `requestUnlock` can no longer
    /// repopulate the in-memory secret, so turning the lock off over a failed
    /// `disable()` strands the device secret behind a prompt the user can no
    /// longer reach — silently, since the app just stops syncing.
    ///
    /// Hostile Location Protection stays *after* the lock flag is persisted:
    /// it rebuilds the graph, and a rebuild while `lockEnabled` is still true
    /// comes up with a fresh AppLockManager in the locked state.
    ///
    /// Authentication comes before *any* of it. Going gate-first was right, but
    /// it used to run `disable()` — which writes the device secret back into
    /// the plain Keychain item — and only then prompt for the lock, so
    /// declining the prompt still left the downgrade applied. One prompt now
    /// covers both changes, via `disableLockAfterAuthentication`.
    private var lockEnabledBinding: Binding<Bool> {
        Binding(
            get: { lockManager.isLockEnabled },
            set: { enabled in
                Task {
                    guard !enabled else {
                        if await lockManager.setLockEnabled(true) {
                            lockToggleMessage = nil
                        } else {
                            lockToggleMessage = String(
                                localized: "Set a device passcode or login password first."
                            )
                        }
                        return
                    }
                    guard await lockManager.confirmWithDeviceAuth(
                        reason: String(localized: "Turn off Require Unlock to Open")
                    ) else {
                        lockToggleMessage = String(
                            localized: "Authentication is required to turn this off."
                        )
                        return
                    }
                    if gateService.isEnabled, !gateService.disable() {
                        lockToggleMessage = String(
                            localized: "Could not restore the credential for \"Require unlock for notifications & MFA\" — turn that off first, then try again."
                        )
                        return
                    }
                    guard lockManager.disableLockAfterAuthentication() else {
                        lockToggleMessage = String(
                            localized: "Could not save the change — try again."
                        )
                        return
                    }
                    lockToggleMessage = nil
                    if SingletonGraph.shared.hostileLocationProtectionStore.enabled {
                        applyHostileProtection(false)
                    }
                }
            }
        )
    }
}

/// iOS screen, pushed from Settings. macOS uses SecurityPane instead.
struct SecuritySettingsView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            SecuritySettingsContent()
                .listRowBackground(theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Security")
    }
}
