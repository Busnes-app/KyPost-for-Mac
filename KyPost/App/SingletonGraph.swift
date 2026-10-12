//
//  SingletonGraph.swift
//  KyPost
//
//  Dependency injection container (spec §Architecture). The app uses `.shared`;
//  tests build their own instance with an in-memory database and scratch
//  UserDefaults suite.
//

import Foundation
import os

@MainActor
final class SingletonGraph {
    /// The current graph. An alias into AppEnvironment so Hostile Location
    /// Protection can swap the graph wholesale — re-read this per use;
    /// never capture it (or a child) into long-lived state outside the
    /// .id(generation)-scoped view trees.
    static var shared: SingletonGraph { AppEnvironment.shared.graph }

    // MARK: - Data

    let database: AppDatabase
    let keychain: KeychainStorage

    // MARK: - Storage

    let appLockStore: AppLockStore
    let hostileLocationProtectionStore: HostileLocationProtectionStore
    let securePairingStore: SecurePairingStore
    let keywordSettingsStore: KeywordSettingsStore
    let notificationCursorStore: NotificationCursorStore
    let contactCursorStore: ContactCursorStore
    let verifiedPgpKeyStore: VerifiedPgpKeyStore
    let contactPendingDeletesStore: ContactPendingDeletesStore
    let contactsSettingsStore: ContactsSettingsStore
    let systemContactsLinkStore: SystemContactsLinkStore
    let systemContactsBaselineStore: SystemContactsBaselineStore
    let pushSettingsStore: PushSettingsStore
    let desktopSessionStore: DesktopSessionStore

    // MARK: - DAOs

    lazy var emailDAO = EmailDAO(modelContainer: database.container)
    lazy var contactDAO = ContactDAO(modelContainer: database.container)
    lazy var pushNotificationDAO = PushNotificationDAO(modelContainer: database.container)

    // MARK: - Networking

    /// TOFU pinning (security-hardening plan, Task 9): enforce the pinned
    /// SPKI only for the paired relay's host — scanned foreign key-exchange
    /// URLs keep default TLS handling. Reads go straight to KeychainStorage
    /// because the delegate runs off the main actor.
    lazy var pinnedSessionDelegate = PinnedSessionDelegate { [keychain] host in
        guard
            let pin = try? keychain.string(forKey: SecurePairingStore.pinnedSpkiHashKey),
            !pin.isEmpty,
            let srv = try? keychain.string(forKey: SecurePairingStore.srvKey),
            let relayHost = URL(string: srv)?.host(),
            relayHost.caseInsensitiveCompare(host) == .orderedSame
        else { return nil }
        return pin
    }
    /// Held rather than captured so `shutdown()` can invalidate it: a
    /// delegate-backed URLSession retains its delegate and its connection pool
    /// until invalidated, so without this a superseded graph would keep live
    /// TLS connections to the relay open — exactly what enabling Hostile
    /// Location Protection is asking us to tear down.
    lazy var relaySession = URLSession(
        configuration: .default, delegate: pinnedSessionDelegate, delegateQueue: nil
    )
    lazy var httpClient: HTTPClient = {
        let delegate = pinnedSessionDelegate
        let session = relaySession
        // Scoped to this request's host: an unrelated cancellation must not
        // inherit another host's mismatch (and vice versa).
        let mapPinFailure: @Sendable (URLRequest, Error) -> Error = { request, error in
            guard let urlError = error as? URLError, urlError.code == .cancelled,
                  delegate.pinFailed(forHost: request.url?.host() ?? "")
            else { return error }
            return NetworkError.certificateMismatch
        }
        // Both seams, not just the buffering one: attachment downloads go
        // through the streaming transport, and building this from the
        // single-transport initializer left them on the uncapped fallback.
        let streaming = HTTPClient.streamTransport(session: session)
        return HTTPClient(
            transport: { request in
                do {
                    return try await session.data(for: request)
                } catch {
                    throw mapPinFailure(request, error)
                }
            },
            streamTransport: { request, limit in
                do {
                    return try await streaming(request, limit)
                } catch {
                    throw mapPinFailure(request, error)
                }
            }
        )
    }()
    lazy var nativeRegistrationClient = NativeRegistrationClient(httpClient: httpClient)
    lazy var desktopRegistrationClient = DesktopRegistrationClient(httpClient: httpClient)
    lazy var pushNotificationClient = PushNotificationClient(httpClient: httpClient)
    lazy var mfaResponseClient = MfaResponseClient(httpClient: httpClient)
    lazy var deregisterClient = DeregisterClient(httpClient: httpClient)
    lazy var contactSyncClient = ContactSyncClient(httpClient: httpClient)
    lazy var pgpQrClient = PgpQrClient(httpClient: httpClient)
    lazy var pgpSendClient = PgpSendClient(httpClient: httpClient)

    // MARK: - Repositories & Use Cases

    lazy var enrollmentVault = EnrollmentVault(keychain: keychain, keyTag: enrollmentKeyTag)

    /// The OpenPGP implementation. One instance, because it is stateless and
    /// every call site must reach the library through this seam.
    lazy var pgpCrypto = GopenPGPCrypto()

    /// Builds a reader for one client-protected message, or nil when unpaired.
    ///
    /// Rebuilt per message rather than cached, for the same reason the
    /// enrollment ceremony is: a re-pair between reads must not be able to
    /// reuse stale credentials.
    func makeEncryptedMessageReader() -> EncryptedMessageReader? {
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        return EncryptedMessageReader(
            opener: DeviceVaultOpener(vault: enrollmentVault),
            payloads: PgpPayloadClient(
                httpClient: httpClient,
                serverUrl: pairing.srv,
                auth: RelayAuth(pairing: pairing)
            ),
            crypto: pgpCrypto
        )
    }

    /// Builds a client-encrypted sender, or nil when unpaired.
    ///
    /// Per send rather than cached, for the same reason as the reader: a
    /// re-pair between attempts must not reuse stale credentials.
    func makeClientEncryptedSender(accountAddress: String) -> ClientEncryptedSender? {
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        let auth = RelayAuth(pairing: pairing)
        return ClientEncryptedSender(
            opener: DeviceVaultOpener(vault: enrollmentVault),
            resolver: RecipientResolveClient(
                httpClient: httpClient, serverUrl: pairing.srv, auth: auth
            ),
            transport: ClientEncryptedSendClient(
                httpClient: httpClient, serverUrl: pairing.srv, auth: auth
            ),
            crypto: pgpCrypto,
            accountAddress: accountAddress
        )
    }

    /// Builds a ceremony against the current pairing, or nil when unpaired.
    /// Rebuilt per attempt so a re-pair between attempts cannot reuse stale
    /// credentials.
    func makeEnrollmentCeremony(
        onState: @escaping @Sendable (EnrollmentState) -> Void
    ) -> EnrollmentCeremony? {
        guard let pairing = try? securePairingStore.loadPairing(),
              let deviceId = pairing.lastDeviceId, !deviceId.isEmpty
        else { return nil }
        let auth = RelayAuth(pairing: pairing)
        let vault = enrollmentVault
        let hostileStore = hostileLocationProtectionStore
        return EnrollmentCeremony(
            transport: EnrollmentClient(
                httpClient: httpClient,
                bootstrapClient: pgpSendClient,
                serverUrl: pairing.srv,
                auth: auth
            ),
            sealer: VaultSealer(vault: vault, deviceId: deviceId),
            deviceId: deviceId,
            hostileLocationEnabled: { hostileStore.enabled },
            hasDeviceCredential: { vault.hasDeviceCredential },
            onState: onState
        )
    }
    lazy var mailCursorStore = MailCursorStore(
        defaults: userDefaults,
        hostileLocation: hostileLocationProtectionStore
    )
    lazy var mailRepository = MailRepository(
        securePairingStore: securePairingStore,
        emailDAO: emailDAO,
        httpClient: httpClient,
        cursorStore: mailCursorStore,
        overrideSource: demoMailSource
    )

    /// The screenshot build's stand-in relay; nil in every other build.
    private var demoMailSource: (any MailSource)? {
#if DEBUG
        isDemo ? DemoMailSource() : nil
#else
        nil
#endif
    }

    /// True only when the DEBUG process was launched with `-KyPostDemo`.
    /// The launch default for `init(isDemo:)`; read `isDemo` on a graph.
    nonisolated static var launchIsDemo: Bool {
#if DEBUG
        DemoContent.isEnabled
#else
        false
#endif
    }

    /// The defaults domain app-level state outside the graph (the theme)
    /// reads, so a demo launch leaves the real one untouched too.
    static var launchUserDefaults: UserDefaults {
#if DEBUG
        launchIsDemo ? DemoContent.isolatedDefaults : .standard
#else
        .standard
#endif
    }

    /// True only for the DEBUG screenshot build's graph. One switch read by
    /// the stores, the database, the mail source, the Contacts adapter, the
    /// push wiring and the startup seed. Never true in a Release build.
    let isDemo: Bool
    private let enrollmentKeyTag: String
    private let gatedCredentialStore: any GatedCredentialStoring
    private let systemContactStoreOverride: (any SystemContactStoring)?
    lazy var keywordRepository = KeywordRepository(settingsStore: keywordSettingsStore)
    lazy var sendEmailUseCase = SendEmailUseCase(repository: mailRepository)
    lazy var pgpSendService = PgpSendService(
        client: pgpSendClient,
        securePairingStore: securePairingStore
    )
    let contactPhotoCache: ContactPhotoCache
    lazy var systemContactGroupLinkStore = SystemContactGroupLinkStore(defaults: userDefaults)
    lazy var systemContactsExporter: SystemContactsExporter = {
        // The demo graph never reaches the real address book, whatever was
        // injected: its contacts are fabricated and its links are not the
        // app's.
        let store: any SystemContactStoring = isDemo
            ? NoopSystemContactStore()
            : (systemContactStoreOverride ?? LiveSystemContactStore())
        return SystemContactsExporter(
            store: store,
            linkStore: systemContactsLinkStore,
            baselineStore: systemContactsBaselineStore,
            settings: contactsSettingsStore,
            contactDAO: contactDAO,
            photoCache: contactPhotoCache,
            groupLinker: SystemContactGroupLinker(
                store: store,
                linkStore: systemContactGroupLinkStore
            ),
            groupDAO: groupDAO
        )
    }()
    lazy var systemContactsChangeMonitor = SystemContactsChangeMonitor(
        exporter: systemContactsExporter,
        repository: contactSyncRepository
    )
    lazy var contactSyncRepository = ContactSyncRepository(
        client: contactSyncClient,
        contactDAO: contactDAO,
        cursorStore: contactCursorStore,
        pendingDeletesStore: contactPendingDeletesStore,
        securePairingStore: securePairingStore,
        systemContactsExporter: systemContactsExporter,
        photoCache: contactPhotoCache,
        verifiedKeyStore: verifiedPgpKeyStore,
        groupsClient: groupsSyncClient,
        groupDAO: groupDAO
    )
    lazy var groupsSyncClient = GroupsSyncClient(httpClient: httpClient)
    lazy var groupDAO = GroupDAO(modelContainer: database.container)
    lazy var pushRepository = PushRepository(
        dao: pushNotificationDAO,
        cursorStore: notificationCursorStore,
        client: pushNotificationClient,
        securePairingStore: securePairingStore,
        pushSettingsStore: pushSettingsStore
    )
    lazy var approveMfaChallengeUseCase = ApproveMfaChallengeUseCase(
        client: mfaResponseClient,
        securePairingStore: securePairingStore
    )
    lazy var deregisterDeviceUseCase = DeregisterDeviceUseCase(
        client: deregisterClient,
        securePairingStore: securePairingStore
    )
    lazy var deviceRegistrationService: DeviceRegistrationService = {
        let service = DeviceRegistrationService(
            client: nativeRegistrationClient,
            securePairingStore: securePairingStore,
            pushSettingsStore: pushSettingsStore
        )
        // TOFU: a successful pairing persists the SPKI hash its handshake
        // presented (see PinnedSessionDelegate).
        service.observedSpkiHash = { [pinnedSessionDelegate] host in
            pinnedSessionDelegate.lastSeenHash(forHost: host)
        }
        // …and when the registration rode a pooled or resumed connection so no
        // handshake was ever observed, force one rather than leaving the pin
        // silently unarmed.
        service.probeSpkiHash = { [pinnedSessionDelegate] url in
            await PinnedSessionDelegate.probeHash(url: url, delegate: pinnedSessionDelegate)
        }
        // A pin carried by the pairing link is enforced on the registration
        // handshake itself, before the pairing exists to read one from.
        service.setPendingPin = { [pinnedSessionDelegate] pin, host in
            pinnedSessionDelegate.setPendingPin(pin, forHost: host)
        }
        return service
    }()
    lazy var desktopPairingService = DesktopPairingService(
        client: desktopRegistrationClient,
        sessionStore: desktopSessionStore
    )

    // MARK: - Notifications

    lazy var pushNotificationDispatcher = PushNotificationDispatcher(
        pushRepository: pushRepository,
        approveMfaChallenge: approveMfaChallengeUseCase,
        pushSettingsStore: pushSettingsStore
    )
    lazy var pullPollingScheduler = PullPollingScheduler(
        pushRepository: pushRepository,
        pushSettingsStore: pushSettingsStore,
        dispatcher: pushNotificationDispatcher
    )

    // MARK: - View Models (shared so menu commands and views stay in sync)

    lazy var inboxViewModel = InboxViewModel(
        mailRepository: mailRepository,
        keywordRepository: keywordRepository
    )
    lazy var contactsViewModel = ContactsViewModel(repository: contactSyncRepository, settingsStore: contactsSettingsStore)

    // MARK: - Security

    lazy var wipeStateStore = WipeStateStore(defaults: userDefaults)
    lazy var securityWipe = SecurityWipe(state: wipeStateStore)

    lazy var appLockManager = AppLockManager(store: appLockStore)
    lazy var credentialGateService = CredentialGateService(
        appLockStore: appLockStore,
        securePairingStore: securePairingStore,
        gatedStore: gatedCredentialStore,
        lockManager: appLockManager
    )

    // MARK: - Lifecycle

    /// Stops every long-lived task this graph owns, so a superseded graph
    /// can't keep polling or writing to its database after
    /// AppEnvironment.rebuild swaps it out. Touching the lazy vars may
    /// construct them first — harmless, a freshly built scheduler/monitor
    /// stops as a no-op.
    func shutdown() {
        pullPollingScheduler.stopForegroundPolling()
        systemContactsChangeMonitor.stop()
        inboxViewModel.stopAutoRefresh()
        // Drops in-flight requests, the connection pool, and the session's
        // strong reference to its delegate. Not `finishTasksAndInvalidate`:
        // a superseded graph's requests write to a database that is going
        // away, and the Hostile Location Protection case wants them gone now.
        relaySession.invalidateAndCancel()
    }

    // MARK: - Startup migrations

    private static let legacyContactFieldsMigratedKey = "contacts.legacyFieldsMigrated"
    private static let reconciliationRepairKey = "contacts.reconciliationRepair.v1"
    private static let systemImportDupeRepairKey = "contacts.systemImportDupeRepair.v1"
    /// Exposed so the security wipe can sweep the same domain the
    /// UserDefaults-backed stores were built against — the app's in production,
    /// a scratch suite in tests.
    let userDefaults: UserDefaults

    /// One-time data backfills after schema migrations (the V1→V2 legacy
    /// email/phone → arrays copy, and the cleanup of rows duplicated by the
    /// old order-based reconciler). Safe to call every launch.
    func runStartupMigrationsIfNeeded() async {
#if DEBUG
        if isDemo {
            await DemoContent.seedContacts(into: contactDAO)
            // Compose asks the relay who holds the account's key before it
            // offers Encrypt/Sign. The demo account is server-custody.
            pgpSendService.preload(
                hasIdentity: true,
                protection: pgpProtectionServer,
                accountAddress: DemoContent.accountAddress
            )
            // The repairs below are for real stores; marking them done
            // against demo data would skip them on the real database.
            return
        }
#endif
        if !userDefaults.bool(forKey: Self.legacyContactFieldsMigratedKey) {
            do {
                try await contactDAO.migrateLegacyFields()
                userDefaults.set(true, forKey: Self.legacyContactFieldsMigratedKey)
            } catch {
                Log.sync.error("Contact legacy-field backfill failed: \(error.localizedDescription)")
            }
        }
        if !userDefaults.bool(forKey: Self.reconciliationRepairKey) {
            do {
                try await contactDAO.repairReconciliationArtifacts()
                userDefaults.set(true, forKey: Self.reconciliationRepairKey)
            } catch {
                Log.sync.error("Contact reconciliation repair failed: \(error.localizedDescription)")
            }
        }
        if !userDefaults.bool(forKey: Self.systemImportDupeRepairKey) {
            do {
                let removed = try await contactDAO.repairImportedDuplicates()
                // The links and baseline reference drifted card identifiers;
                // forgetting both makes the next reconcile recapture the
                // baseline and re-adopt cards by identity instead of
                // re-importing or deleting anything.
                systemContactsLinkStore.clear()
                systemContactsBaselineStore.clear()
                userDefaults.set(true, forKey: Self.systemImportDupeRepairKey)
                if removed > 0 {
                    Log.sync.info("Removed \(removed) duplicate imported contacts")
                }
            } catch {
                Log.sync.error("Contact import-dupe repair failed: \(error.localizedDescription)")
            }
        }
    }

    /// `isDemo` replaces `userDefaults`, `keychain`, the gated credential,
    /// the device key and the Contacts adapter with isolated stand-ins
    /// (DemoContent), ignoring what was passed: the demo build must never
    /// read or modify the real pairing, settings or credentials. Release
    /// builds ignore `isDemo` entirely.
    init(
        userDefaults: UserDefaults = .standard,
        keychain: KeychainStorage = KeychainStorage(),
        database: AppDatabase? = nil,
        isDemo: Bool = SingletonGraph.launchIsDemo,
        systemContactStore: (any SystemContactStoring)? = nil
    ) throws {
        var userDefaults = userDefaults
        var keychain = keychain
        var gatedStore: any GatedCredentialStoring = GatedCredentialStore()
        var keyTag = EnrollmentVault.defaultKeyTag
#if DEBUG
        self.isDemo = isDemo
        if isDemo {
            userDefaults = DemoContent.isolatedDefaults
            keychain = DemoContent.isolatedKeychain
            gatedStore = DemoContent.isolatedGatedStore
            keyTag = DemoContent.isolatedVaultKeyTag
        }
#else
        self.isDemo = false
#endif
        gatedCredentialStore = gatedStore
        enrollmentKeyTag = keyTag
        systemContactStoreOverride = systemContactStore

        self.userDefaults = userDefaults
        hostileLocationProtectionStore = HostileLocationProtectionStore(defaults: userDefaults)
        let hostileLocation = hostileLocationProtectionStore.enabled

        // Hostile Location Protection keeps the whole cache in memory; the
        // screenshot build does too, so a demo mailbox never lands on disk
        // beside — or on top of — real mail.
        let inMemory = hostileLocation || self.isDemo
        self.database = try database ?? AppDatabase(inMemory: inMemory)
        contactPhotoCache = ContactPhotoCache(inMemory: inMemory)
        if !self.database.isInMemory {
            do {
                try AppDatabase.excludeStoreFromBackup()
            } catch {
                Log.storage.error("Could not exclude the store from backup: \(error.localizedDescription)")
            }
        }
        self.keychain = keychain
        appLockStore = AppLockStore(keychain: keychain, defaults: userDefaults)
        securePairingStore = SecurePairingStore(keychain: keychain)
        keywordSettingsStore = KeywordSettingsStore(defaults: userDefaults)
        notificationCursorStore = NotificationCursorStore(defaults: userDefaults)
        contactCursorStore = ContactCursorStore(defaults: userDefaults)
        contactPendingDeletesStore = ContactPendingDeletesStore(defaults: userDefaults)
        verifiedPgpKeyStore = VerifiedPgpKeyStore(defaults: userDefaults)
        contactsSettingsStore = ContactsSettingsStore(defaults: userDefaults)
        systemContactsLinkStore = SystemContactsLinkStore(defaults: userDefaults)
        systemContactsBaselineStore = SystemContactsBaselineStore(defaults: userDefaults)
        pushSettingsStore = PushSettingsStore(defaults: userDefaults)
        desktopSessionStore = DesktopSessionStore(keychain: keychain)
    }
}
