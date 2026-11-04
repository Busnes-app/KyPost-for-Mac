//
//  PushPairingViewModel.swift
//  KyPost
//
//  Pairing flow state (spec §1). Links arrive via deep link or pasted text;
//  ponytail: camera QR scanning is v2 — deep links and paste cover pairing
//  until AVFoundation scanning is added.
//

import Foundation
import Observation

/// What an unpaired device tells the user. The macOS wording follows the web
/// app's pairing page (KyPost-Server `frontend/src/pages/security/
/// PairingPanel.tsx`): Settings → Security → Devices → "Pair a new device",
/// whose "Pair this device" button opens a `kypost://native-pair` link and,
/// when nothing takes it, shows the link to paste.
enum PairingInstructions {
    /// The inbox's not-paired state.
    static var inbox: String {
        #if os(macOS)
        String(localized: "This Mac isn't paired. In KyPost on the web, open Settings → Security → Devices, choose Pair a new device, then Pair this device. Your browser opens a kypost://native-pair link in this app.")
        #else
        String(localized: "Pair this device (Settings → Connection) to load mail.")
        #endif
    }

    /// Settings → Connection on macOS while unpaired.
    static let macConnection = String(localized: "To pair this Mac, sign in to KyPost on the web and open Settings → Security → Devices. Choose Pair a new device, then Pair this device: your browser opens a kypost://native-pair link and KyPost asks you to confirm the server. If nothing opens, the web page shows the link instead; copy it and use Paste Pairing Link.")
}

/// A parsed pairing link/QR code awaiting the user's explicit confirmation
/// before any network call fires. `existingHost` is set when accepting would
/// replace an already-paired device, so the confirmation screen can warn
/// about it.
struct PendingPairingConfirmation: Equatable, Sendable {
    let params: PairingParams
    let existingHost: String?
    /// Pairing would re-pin the account already paired to a new certificate
    /// key (`DeviceRegistrationService.linkRepinsStoredPin`). The screen
    /// warns, and only Pair on that screen allows the re-pin.
    var repinsCertificate = false
}

@Observable
@MainActor
final class PushPairingViewModel {
    enum State: Equatable {
        case idle
        /// Destination host shown; the network call fires only once the
        /// user taps through (see `pair(params:)`).
        case confirming(PendingPairingConfirmation)
        case working
        /// The server created the device pending (202): the code is on
        /// screen and `pair` is polling until the user approves it on the web.
        case awaitingApproval(PendingApproval)
        case paired(deviceId: String?)
        case failed(String)
    }

    private let registrationService: DeviceRegistrationService
    private let pushSettingsStore: PushSettingsStore
    private let securePairingStore: SecurePairingStore

    private(set) var state: State = .idle
    /// Shown above the scan/paste screen after a wait ended without approval.
    private(set) var notice: String?
    var pastedLink = ""
    /// Moves on with every pairing attempt and cancel, so a wait that ends
    /// after the user moved on changes nothing.
    private var attempt = 0

    static let notApprovedMessage = String(localized: "Not approved: denied or timed out. Scan a new code.")

    init(
        registrationService: DeviceRegistrationService,
        pushSettingsStore: PushSettingsStore,
        securePairingStore: SecurePairingStore
    ) {
        self.registrationService = registrationService
        self.pushSettingsStore = pushSettingsStore
        self.securePairingStore = securePairingStore
    }

    /// Shows the destination host and waits for explicit confirmation —
    /// called instead of pairing immediately for every entry point (deep
    /// link, scanned QR, pasted link), since a crafted link/QR could
    /// otherwise silently repoint the pairing at an attacker server with no
    /// warning at all.
    func present(params: PairingParams) {
        // A new link replaces a pairing still registering or waiting.
        cancelPairing()
        notice = nil
        state = .confirming(PendingPairingConfirmation(
            params: params,
            existingHost: currentPairedHost,
            repinsCertificate: registrationService.linkRepinsStoredPin(params)
        ))
    }

    private var currentPairedHost: String? {
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        return URL(string: pairing.srv)?.host
    }

    func pair(params: PairingParams, allowingRepin: Bool = false) async {
        attempt += 1
        let attempt = attempt
        notice = nil
        state = .working
        // Simulators never receive an APNs token; register with a placeholder
        // so pairing still completes (pull mode works without APNs).
        let token = pushSettingsStore.lastDeviceToken ?? "no-apns-token"
        var outcome = await registrationService.pair(
            params: params, deviceToken: token, allowingRepin: allowingRepin
        )
        if case .awaitingApproval(let approval) = outcome {
            guard attempt == self.attempt else { return }
            state = .awaitingApproval(approval)
            outcome = await registrationService.awaitApproval()
        }
        guard attempt == self.attempt else { return }
        switch outcome {
        case .success(let response):
            state = .paired(deviceId: response.deviceId)
        case .unauthorized:
            state = .failed("The server rejected the pairing — re-scan the QR code.")
        case .backendMisconfigured:
            state = .failed("The server is not configured for native pairing (503).")
        case .failure(let message):
            state = .failed(message)
        case .notApproved:
            // Back to the start, where a new code can be scanned.
            pastedLink = ""
            notice = Self.notApprovedMessage
            state = .idle
        case .approvalRequired, .awaitingApproval:
            // The service never returns these from a wait.
            state = .failed(Self.notApprovedMessage)
        }
    }

    /// Cancel on the waiting screen, or the screen closing: ends the
    /// attempt whether it is still registering or waiting on approval, so a
    /// late answer stores nothing and starts no polls. No-op in any other
    /// state.
    func cancelPairing() {
        switch state {
        case .working, .awaitingApproval: break
        default: return
        }
        attempt += 1
        registrationService.cancelPairing()
        state = .idle
    }

    /// Parses a pasted kypost://native-pair link and asks for confirmation.
    func pairFromPastedLink() async {
        guard let url = URL(string: pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .failed("That doesn't look like a valid pairing link.")
            return
        }
        do {
            present(params: try PairingLinkParser.parse(url))
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Parses a scanned QR code containing a kypost://native-pair link and
    /// asks for confirmation.
    func pairFromScannedCode(_ payload: String) async {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .failed("That QR code isn't a KyPost pairing code.")
            return
        }
        do {
            present(params: try PairingLinkParser.parse(url))
        } catch {
            state = .failed(Self.message(for: error, scanned: true))
        }
    }

    /// A refused link is not the same as an unrecognised one, and the
    /// certificate-pin case in particular must not read as "try again" —
    /// retrying is exactly the wrong response to it.
    static func message(for error: Error, scanned: Bool = false) -> String {
        switch error {
        case PairingLinkError.malformedCertificatePin:
            return "This pairing link carries a damaged certificate pin, so KyPost stopped rather than pairing without one. Generate a fresh link on your server's Security page. If a new link does the same thing, something is altering it in transit — do not pair on this network."
        case PairingLinkError.registrationHostMismatch:
            return "This pairing link names one server but registers with another. KyPost refused it."
        case PairingLinkError.insecureServerURL:
            return "This pairing link points at a server over plain http. KyPost refused it."
        default:
            return scanned
                ? "That QR code isn't a KyPost pairing code."
                : "That doesn't look like a valid pairing link."
        }
    }

#if DEBUG
    /// Screenshot runs only (`DemoContent.pairingApprovalScreen`).
    func showDemo(_ screen: DemoContent.PairingScreen) {
        switch screen {
        case .awaiting(let approval):
            state = .awaitingApproval(approval)
        case .notApproved:
            notice = Self.notApprovedMessage
            state = .idle
        }
    }
#endif

    /// Back to the scan/paste screen after a failure.
    func reset() {
        notice = nil
        pastedLink = ""
        state = .idle
    }
}
