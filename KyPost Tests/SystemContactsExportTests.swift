//
//  SystemContactsExportTests.swift
//  KyPost Tests
//
//  Apple Contacts export: field mapping, the link-based diff (including
//  re-link after a tooOld wipe), and the exporter's guard rails and
//  failure handling through a mock contact store.
//

import Contacts
import Foundation
import Testing
@testable import KyPost

// MARK: - Helpers

/// Not private: `UnpairTeardownTests` builds a `SettingsViewModel`, which needs
/// an exporter, and an exporter built on the live store reaches the real
/// Contacts database from a test process.
@MainActor
final class MockSystemContactStore: SystemContactStoring {
    struct StubError: Error {}

    var authorizationStatus: CNAuthorizationStatus = .authorized
    var accessGranted = true
    var failNextAdd = false
    var failingIdentifiers: Set<String> = []

    private(set) var cards: [String: CNContact] = [:]
    private(set) var addCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0

    func requestAccess() async throws -> Bool { accessGranted }

    func fetch(identifier: String) async throws -> CNContact? { cards[identifier] }

    var failListAll = false

    func listAll() async throws -> [CNContact] {
        if failListAll { throw StubError() }
        return Array(cards.values)
    }

    func add(_ contact: CNMutableContact) async throws {
        addCount += 1
        if failNextAdd {
            failNextAdd = false
            throw StubError()
        }
        cards[contact.identifier] = contact.copy() as? CNContact
    }

    func update(_ contact: CNMutableContact) async throws {
        updateCount += 1
        if failingIdentifiers.contains(contact.identifier) { throw StubError() }
        cards[contact.identifier] = contact.copy() as? CNContact
    }

    func delete(identifier: String) async throws {
        deleteCount += 1
        if failingIdentifiers.contains(identifier) { throw StubError() }
        cards[identifier] = nil
    }

    // MARK: - Groups

    private(set) var groups: [String: CNMutableGroup] = [:]
    /// group identifier -> card identifiers
    private(set) var members: [String: Set<String>] = [:]
    private(set) var groupAddCount = 0
    var failNextGroupAdd = false

    func listGroups() async throws -> [CNGroup] {
        groups.values.compactMap { $0.copy() as? CNGroup }
    }

    func addGroup(_ group: CNMutableGroup) async throws {
        groupAddCount += 1
        if failNextGroupAdd {
            failNextGroupAdd = false
            throw StubError()
        }
        groups[group.identifier] = group
    }

    func renameGroup(identifier: String, to name: String) async throws {
        groups[identifier]?.name = name
    }

    func memberIdentifiers(ofGroup identifier: String) async throws -> [String] {
        Array(members[identifier] ?? [])
    }

    func addMember(contactIdentifier: String, toGroup groupIdentifier: String) async throws {
        members[groupIdentifier, default: []].insert(contactIdentifier)
    }

    func removeMember(contactIdentifier: String, fromGroup groupIdentifier: String) async throws {
        members[groupIdentifier]?.remove(contactIdentifier)
    }

    func removeGroup(identifier: String) {
        groups[identifier] = nil
        members[identifier] = nil
    }

    /// Seeds a group the user already had, without touching the counters.
    func seedGroup(name: String) -> CNMutableGroup {
        let group = CNMutableGroup()
        group.name = name
        groups[group.identifier] = group
        return group
    }

    /// Test seeding without touching the add/fail counters.
    func seed(_ contact: CNContact) {
        cards[contact.identifier] = contact.copy() as? CNContact
    }
}

private func makeContact(
    localId: UUID = UUID(),
    uid: String? = nil,
    name: String = "Ada Lovelace",
    email: String = "ada@example.com",
    phone: String = "",
    avatarUrl: String? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> Contact {
    var contact = Contact(
        localId: localId,
        uid: uid,
        name: name,
        avatarUrl: avatarUrl,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        needsSync: false
    )
    if !email.isEmpty {
        contact.emails = [ContactLabeledValue(label: nil, value: email)]
    }
    if !phone.isEmpty {
        contact.phones = [ContactLabeledValue(label: nil, value: phone)]
    }
    return contact
}

private func makeLink(
    localId: UUID = UUID(),
    uid: String? = nil,
    cnIdentifier: String = UUID().uuidString,
    exportedUpdatedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> SystemContactLink {
    SystemContactLink(
        localId: localId,
        uid: uid,
        cnIdentifier: cnIdentifier,
        exportedUpdatedAt: exportedUpdatedAt
    )
}

private struct ExporterEnvironment {
    let exporter: SystemContactsExporter
    let mock: MockSystemContactStore
    let linkStore: SystemContactsLinkStore
    let baselineStore: SystemContactsBaselineStore
    let settings: ContactsSettingsStore
    let dao: ContactDAO
}

@MainActor
private func makeEnvironment(
    enabled: Bool = true,
    status: CNAuthorizationStatus = .authorized
) throws -> ExporterEnvironment {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let mock = MockSystemContactStore()
    mock.authorizationStatus = status
    let linkStore = SystemContactsLinkStore(defaults: defaults)
    let baselineStore = SystemContactsBaselineStore(defaults: defaults)
    let settings = ContactsSettingsStore(defaults: defaults)
    settings.exportToSystemContactsEnabled = enabled
    let database = try AppDatabase(inMemory: true)
    let dao = ContactDAO(modelContainer: database.container)
    let exporter = SystemContactsExporter(
        store: mock,
        linkStore: linkStore,
        baselineStore: baselineStore,
        settings: settings,
        contactDAO: dao
    )
    return ExporterEnvironment(
        exporter: exporter,
        mock: mock,
        linkStore: linkStore,
        baselineStore: baselineStore,
        settings: settings,
        dao: dao
    )
}

/// A card as the user would create it in Contacts.app.
private func makeCard(
    given: String = "Grace",
    family: String = "Hopper",
    email: String? = "grace@example.com"
) -> CNMutableContact {
    let card = CNMutableContact()
    card.givenName = given
    card.familyName = family
    if let email {
        card.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
    }
    return card
}

// MARK: - Mapper

@MainActor
@Suite struct SystemContactMapperTests {
    @Test func splitsNameOnLastWhitespace() {
        let (given, family) = SystemContactMapper.nameComponents(
            from: "Ada M. Lovelace",
            fallbackEmail: ""
        )
        #expect(given == "Ada M.")
        #expect(family == "Lovelace")
    }

    @Test func singleTokenNameIsGivenNameOnly() {
        let (given, family) = SystemContactMapper.nameComponents(
            from: "Cher",
            fallbackEmail: ""
        )
        #expect(given == "Cher")
        #expect(family.isEmpty)
    }

    @Test func emptyNameFallsBackToEmailLocalPart() {
        let (given, family) = SystemContactMapper.nameComponents(
            from: "  ",
            fallbackEmail: "grace@example.com"
        )
        #expect(given == "grace")
        #expect(family.isEmpty)
    }

    @Test func mapsLabeledFields() {
        let contact = makeContact(
            name: "Ada Lovelace",
            email: "ada@example.com",
            phone: "+1 555 0100",
            avatarUrl: "https://example.com/ada.png"
        )
        let cn = SystemContactMapper.makeContact(from: contact)
        #expect(cn.givenName == "Ada")
        #expect(cn.familyName == "Lovelace")
        #expect(cn.emailAddresses.first?.value as String? == "ada@example.com")
        #expect(cn.emailAddresses.first?.label == CNLabelHome)
        #expect(cn.phoneNumbers.first?.value.stringValue == "+1 555 0100")
        #expect(cn.urlAddresses.first?.value as String? == "https://example.com/ada.png")
    }

    @Test func emptyFieldsProduceEmptyArrays() {
        let contact = makeContact(email: "", phone: "", avatarUrl: nil)
        let cn = SystemContactMapper.makeContact(from: contact)
        #expect(cn.emailAddresses.isEmpty)
        #expect(cn.phoneNumbers.isEmpty)
        #expect(cn.urlAddresses.isEmpty)
    }

    @Test func applyPreservesUnmappedFields() {
        // note stays unmapped (restricted entitlement); a photo set by the
        // user in Contacts.app survives when the app has no bytes to write.
        let cn = CNMutableContact()
        cn.note = "met at the salon"
        cn.imageData = Data([0xFF])
        SystemContactMapper.apply(makeContact(), to: cn)
        #expect(cn.note == "met at the salon")
        #expect(cn.imageData == Data([0xFF]))
    }

    @Test func mapsExtendedFieldsToCNProperties() {
        var contact = makeContact(name: "Ada Lovelace", avatarUrl: "https://example.com/a.png")
        contact.givenName = "Ada"
        contact.familyName = "Lovelace"
        contact.middleName = "M."
        contact.prefix = "Dr."
        contact.suffix = "PhD"
        contact.nickname = "Addie"
        contact.phoneticGivenName = "AY-duh"
        contact.phoneticFamilyName = "LUV-lace"
        contact.org = "Analytical Engines Ltd"
        contact.title = "Chief Mathematician"
        contact.department = "Research"
        contact.emails = [
            ContactLabeledValue(label: "home", value: "ada@example.com"),
            ContactLabeledValue(label: "work", value: "ada@engines.example"),
        ]
        contact.phones = [ContactLabeledValue(label: "mobile", value: "+44 555 0100")]
        contact.addresses = [ContactPostalAddress(
            label: "home", street: "1 Byron Row", city: "London",
            region: "LDN", postalCode: "E1 1AA", country: "UK"
        )]
        contact.birthday = "1815-12-10"
        contact.events = [ContactEvent(label: "anniversary", date: "1835-07-08")]
        contact.ims = [
            ContactIM(service: "signal", label: nil, value: "+445550100"),
            ContactIM(service: "linkedin", label: nil, value: "ada-lovelace"),
            ContactIM(service: "x", label: nil, value: "@ada"),
        ]
        contact.websites = [ContactLabeledValue(label: "homepage", value: "https://ada.example")]
        contact.relations = [ContactRelation(label: "spouse", name: "William King")]
        // App-only fields must not leak into the card.
        contact.pgpKey = "-----BEGIN PGP PUBLIC KEY BLOCK-----"
        contact.pronouns = "she/her"
        contact.customFields = [ContactCustomField(label: "Callsign", value: "Enchantress")]

        let photoBytes = Data([0x01, 0x02])
        let cn = SystemContactMapper.makeContact(from: contact, photoData: photoBytes)

        #expect(cn.givenName == "Ada")
        #expect(cn.familyName == "Lovelace")
        #expect(cn.middleName == "M.")
        #expect(cn.namePrefix == "Dr.")
        #expect(cn.nameSuffix == "PhD")
        #expect(cn.nickname == "Addie")
        #expect(cn.phoneticGivenName == "AY-duh")
        #expect(cn.phoneticFamilyName == "LUV-lace")
        #expect(cn.organizationName == "Analytical Engines Ltd")
        #expect(cn.jobTitle == "Chief Mathematician")
        #expect(cn.departmentName == "Research")
        #expect(cn.emailAddresses.count == 2)
        #expect(cn.emailAddresses[0].label == CNLabelHome)
        #expect(cn.emailAddresses[1].label == CNLabelWork)
        #expect(cn.phoneNumbers.first?.label == CNLabelPhoneNumberMobile)
        #expect(cn.postalAddresses.first?.value.street == "1 Byron Row")
        #expect(cn.postalAddresses.first?.value.state == "LDN")
        #expect(cn.birthday == DateComponents(year: 1815, month: 12, day: 10))
        #expect(cn.dates.first?.label == CNLabelDateAnniversary)
        #expect(cn.dates.first?.value as? NSDateComponents
            == DateComponents(year: 1835, month: 7, day: 8) as NSDateComponents)
        // Messaging services land in IM addresses, social ones in profiles.
        #expect(cn.instantMessageAddresses.count == 1)
        #expect(cn.instantMessageAddresses.first?.value.service == "Signal")
        #expect(cn.socialProfiles.count == 2)
        #expect(cn.socialProfiles.first?.value.service == CNSocialProfileServiceLinkedIn)
        #expect(cn.socialProfiles.last?.value.service == "X")
        // Avatar entry keeps its slot ahead of real websites.
        #expect(cn.urlAddresses.count == 2)
        #expect(cn.urlAddresses[0].label == SystemContactMapper.avatarUrlLabel)
        #expect(cn.urlAddresses[1].value as String == "https://ada.example")
        #expect(cn.contactRelations.first?.label == CNLabelContactRelationSpouse)
        #expect(cn.contactRelations.first?.value.name == "William King")
        #expect(cn.imageData == photoBytes)
        #expect(cn.note.isEmpty)
    }

    @Test func skipsUnparseableDatesInsteadOfCrashing() {
        var contact = makeContact()
        contact.birthday = "not-a-date"
        contact.events = [ContactEvent(label: "anniversary", date: "1835-99-99")]
        let cn = SystemContactMapper.makeContact(from: contact)
        #expect(cn.birthday == nil)
        #expect(cn.dates.isEmpty)
    }

    @Test func importReverseMapsExtendedFields() {
        let card = CNMutableContact()
        card.givenName = "Grace"
        card.familyName = "Hopper"
        card.middleName = "Brewster"
        card.nickname = "Amazing Grace"
        card.organizationName = "US Navy"
        card.jobTitle = "Rear Admiral"
        card.departmentName = "Computation"
        card.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "grace@navy.example" as NSString)
        ]
        card.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "555"))
        ]
        let postal = CNMutablePostalAddress()
        postal.street = "1 Pier Rd"
        postal.state = "VA"
        card.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: postal)]
        card.birthday = DateComponents(year: 1906, month: 12, day: 9)
        card.dates = [CNLabeledValue(
            label: CNLabelDateAnniversary,
            value: DateComponents(year: 1944, month: 1, day: 1) as NSDateComponents
        )]
        card.urlAddresses = [
            CNLabeledValue(label: SystemContactMapper.avatarUrlLabel, value: "https://x/a.png"),
            CNLabeledValue(label: CNLabelHome, value: "https://grace.example" as NSString),
        ]
        card.instantMessageAddresses = [CNLabeledValue(
            label: nil,
            value: CNInstantMessageAddress(username: "grace.55", service: "Signal")
        )]
        card.socialProfiles = [CNLabeledValue(
            label: nil,
            value: CNSocialProfile(
                urlString: nil, username: "grace", userIdentifier: nil,
                service: CNSocialProfileServiceLinkedIn
            )
        )]
        card.contactRelations = [CNLabeledValue(
            label: CNLabelContactRelationSpouse,
            value: CNContactRelation(name: "Vincent")
        )]

        let contact = SystemContactMapper.contact(from: card)
        #expect(contact.name == "Grace Hopper")
        #expect(contact.givenName == "Grace")
        #expect(contact.middleName == "Brewster")
        #expect(contact.nickname == "Amazing Grace")
        #expect(contact.org == "US Navy")
        #expect(contact.title == "Rear Admiral")
        #expect(contact.department == "Computation")
        #expect(contact.emails == [ContactLabeledValue(label: "work", value: "grace@navy.example")])
        #expect(contact.phones == [ContactLabeledValue(label: "mobile", value: "555")])
        #expect(contact.addresses.first?.street == "1 Pier Rd")
        #expect(contact.addresses.first?.region == "VA")
        #expect(contact.birthday == "1906-12-09")
        #expect(contact.events == [ContactEvent(label: "anniversary", date: "1944-01-01")])
        // The avatar entry is app metadata, not a website.
        #expect(contact.websites == [
            ContactLabeledValue(label: "home", value: "https://grace.example")
        ])
        #expect(contact.ims == [
            ContactIM(service: "signal", label: nil, value: "grace.55"),
            ContactIM(service: "linkedin", label: nil, value: "grace"),
        ])
        #expect(contact.relations == [ContactRelation(label: "spouse", name: "Vincent")])
        #expect(contact.needsSync == true)
    }

    @Test func companyOnlyCardImportsWithOrgAsName() {
        // Contacts.app allows cards without a personal name; the server
        // silently drops creates without an fn, so the import derives one.
        let card = CNMutableContact()
        card.organizationName = "Acme Corp"
        card.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "info@acme.example" as NSString)
        ]
        let contact = SystemContactMapper.contact(from: card)
        #expect(contact.name == "Acme Corp")
        #expect(contact.org == "Acme Corp")
    }

    @Test func namelessCardFallsBackToEmailLocalPartName() {
        let card = CNMutableContact()
        card.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "grace@example.com" as NSString)
        ]
        let contact = SystemContactMapper.contact(from: card)
        #expect(contact.name == "grace")
    }

    @Test func matchKeyPrefersCaseInsensitiveEmail() {
        let a = SystemContactMapper.matchKey(name: "Ada", email: " Ada@Example.com ", phone: "")
        let b = SystemContactMapper.matchKey(name: "Someone Else", email: "ada@example.com", phone: "123")
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func matchKeyFallsBackToNamePlusPhoneDigits() {
        let a = SystemContactMapper.matchKey(name: "Ada Lovelace", email: "", phone: "+1 (555) 010-0")
        let b = SystemContactMapper.matchKey(name: "ada lovelace", email: "", phone: "1 555 0100")
        #expect(a != nil)
        #expect(a == b)
        // Not enough signal to match safely.
        #expect(SystemContactMapper.matchKey(name: "Ada", email: "", phone: "") == nil)
        #expect(SystemContactMapper.matchKey(name: "", email: "", phone: "555") == nil)
    }
}

// MARK: - Diff

@MainActor
@Suite struct SystemContactsDiffTests {
    @Test func unlinkedContactsBecomeCreates() {
        let contacts = [makeContact(name: "Ada"), makeContact(name: "Grace")]
        let plan = SystemContactsDiff.plan(
            contacts: contacts,
            links: [],
            existingCardIdentifiers: []
        )
        #expect(plan.creates.count == 2)
        #expect(plan.updates.isEmpty)
        #expect(plan.deletes.isEmpty)
        #expect(plan.relinks.isEmpty)
    }

    @Test func editedLinkedContactBecomesUpdate() {
        let contact = makeContact(updatedAt: Date(timeIntervalSince1970: 2_000))
        let link = makeLink(
            localId: contact.localId,
            exportedUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let plan = SystemContactsDiff.plan(
            contacts: [contact],
            links: [link],
            existingCardIdentifiers: [link.cnIdentifier]
        )
        #expect(plan.updates.map(\.cnIdentifier) == [link.cnIdentifier])
        #expect(plan.creates.isEmpty)
    }

    @Test func missingCardIsReexportedEvenWhenUnchanged() {
        // The card was deleted in Contacts.app (or its account was removed);
        // the unchanged timestamps alone must not mask the loss.
        let exportedAt = Date(timeIntervalSince1970: 1_000)
        let contact = makeContact(updatedAt: exportedAt)
        let link = makeLink(localId: contact.localId, exportedUpdatedAt: exportedAt)
        let plan = SystemContactsDiff.plan(
            contacts: [contact],
            links: [link],
            existingCardIdentifiers: []
        )
        #expect(plan.updates.map(\.cnIdentifier) == [link.cnIdentifier])
        #expect(plan.creates.isEmpty)
        #expect(plan.deletes.isEmpty)
    }

    @Test func unchangedLinkedContactIsSkipped() {
        let exportedAt = Date(timeIntervalSince1970: 1_000)
        let contact = makeContact(updatedAt: exportedAt)
        let link = makeLink(localId: contact.localId, exportedUpdatedAt: exportedAt)
        let plan = SystemContactsDiff.plan(
            contacts: [contact],
            links: [link],
            existingCardIdentifiers: [link.cnIdentifier]
        )
        #expect(plan == SystemContactsExportPlan())
    }

    @Test func orphanedLinkBecomesDelete() {
        let link = makeLink()
        let plan = SystemContactsDiff.plan(
            contacts: [],
            links: [link],
            existingCardIdentifiers: [link.cnIdentifier]
        )
        #expect(plan.deletes == [link])
    }

    @Test func relinksByUidAfterTooOldWipe() {
        // A tooOld re-pull keeps the server contact but assigns a new localId.
        let repulled = makeContact(uid: "srv-1")
        let staleLink = makeLink(localId: UUID(), uid: "srv-1")
        let plan = SystemContactsDiff.plan(
            contacts: [repulled],
            links: [staleLink],
            existingCardIdentifiers: [staleLink.cnIdentifier]
        )
        #expect(plan.relinks.count == 1)
        #expect(plan.relinks.first?.contact.localId == repulled.localId)
        #expect(plan.relinks.first?.link == staleLink)
        #expect(plan.deletes.isEmpty)
        #expect(plan.creates.isEmpty)
    }

    @Test func duplicateEmailsCreateIndependentCards() {
        let contacts = [
            makeContact(name: "Ada Work", email: "shared@example.com"),
            makeContact(name: "Ada Home", email: "shared@example.com"),
        ]
        let plan = SystemContactsDiff.plan(
            contacts: contacts,
            links: [],
            existingCardIdentifiers: []
        )
        #expect(plan.creates.count == 2)
    }
}

// MARK: - Link store

@MainActor
@Suite struct SystemContactsLinkStoreTests {
    private func makeStore() -> SystemContactsLinkStore {
        SystemContactsLinkStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    @Test func roundTripsLinks() {
        let store = makeStore()
        let link = makeLink(uid: "srv-1")
        store.upsert(link)
        #expect(store.all() == [link])
        #expect(store.link(localId: link.localId) == link)
    }

    @Test func upsertReplacesByLocalId() {
        let store = makeStore()
        var link = makeLink()
        store.upsert(link)
        link.cnIdentifier = "replacement"
        store.upsert(link)
        #expect(store.all() == [link])
    }

    @Test func removesAndClears() {
        let store = makeStore()
        let first = makeLink()
        let second = makeLink()
        store.upsert(first)
        store.upsert(second)
        store.remove(localId: first.localId)
        #expect(store.all() == [second])
        store.clear()
        #expect(store.all().isEmpty)
    }
}

// MARK: - Exporter

@MainActor
@Suite struct SystemContactsExporterTests {
    @Test func disabledTogglePerformsNoStoreCalls() async throws {
        let env = try makeEnvironment(enabled: false)
        try await env.dao.upsert(contacts: [makeContact()])
        let summary = await env.exporter.reconcileAll()
        #expect(summary == SystemContactsExporter.Summary())
        #expect(env.mock.addCount == 0)
    }

    @Test func deniedAuthorizationPerformsNoStoreCalls() async throws {
        let env = try makeEnvironment(status: .denied)
        try await env.dao.upsert(contacts: [makeContact()])
        let summary = await env.exporter.reconcileAll()
        #expect(summary == SystemContactsExporter.Summary())
        #expect(env.mock.addCount == 0)
        #expect(env.exporter.isDenied)
    }

    @Test func requestAccessPromptsOnlyWhenUndetermined() async throws {
        let env = try makeEnvironment(status: .notDetermined)
        #expect(await env.exporter.requestAccessIfNeeded())

        // Already authorized: returns true without prompting again.
        env.mock.authorizationStatus = .authorized
        env.mock.accessGranted = false
        #expect(await env.exporter.requestAccessIfNeeded())

        let denied = try makeEnvironment(status: .denied)
        #expect(await !denied.exporter.requestAccessIfNeeded())
    }

    @Test func reconcileCreatesCardsAndLinks() async throws {
        let env = try makeEnvironment()
        try await env.dao.upsert(contacts: [makeContact(name: "Ada Lovelace")])
        let summary = await env.exporter.reconcileAll()
        #expect(summary.created == 1)
        let links = env.linkStore.all()
        #expect(links.count == 1)
        #expect(env.mock.cards[links[0].cnIdentifier]?.givenName == "Ada")
    }

    @Test func reconcileSkipsUnchangedOnSecondPass() async throws {
        let env = try makeEnvironment()
        try await env.dao.upsert(contacts: [makeContact()])
        await env.exporter.reconcileAll()
        let second = await env.exporter.reconcileAll()
        #expect(second == SystemContactsExporter.Summary())
        #expect(env.mock.addCount == 1)
        #expect(env.mock.updateCount == 0)
    }

    @Test func updateOnUserDeletedCardFallsBackToAdd() async throws {
        let env = try makeEnvironment()
        let contact = makeContact(updatedAt: Date(timeIntervalSince1970: 2_000))
        try await env.dao.upsert(contacts: [contact])
        // Link points at a card that no longer exists in the system store.
        env.linkStore.upsert(makeLink(
            localId: contact.localId,
            cnIdentifier: "gone",
            exportedUpdatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        let summary = await env.exporter.reconcileAll()
        #expect(summary.created == 1)
        #expect(summary.failed == 0)
        let link = try #require(env.linkStore.link(localId: contact.localId))
        #expect(link.cnIdentifier != "gone")
        #expect(env.mock.cards[link.cnIdentifier] != nil)
    }

    @Test func recreatesCardsDeletedOutsideTheApp() async throws {
        let env = try makeEnvironment()
        try await env.dao.upsert(contacts: [makeContact()])
        await env.exporter.reconcileAll()
        let original = try #require(env.linkStore.all().first)

        // The card vanishes without the contact changing (deleted in
        // Contacts.app, or its account was removed from the device).
        try await env.mock.delete(identifier: original.cnIdentifier)

        let summary = await env.exporter.reconcileAll()
        #expect(summary.created == 1)
        #expect(summary.failed == 0)
        let repaired = try #require(env.linkStore.all().first)
        #expect(repaired.cnIdentifier != original.cnIdentifier)
        #expect(env.mock.cards[repaired.cnIdentifier] != nil)
    }

    @Test func partialFailureLeavesOtherCardsAppliedAndRetriable() async throws {
        let env = try makeEnvironment()
        try await env.dao.upsert(contacts: [
            makeContact(name: "Alpha One", email: "alpha@example.com"),
            makeContact(name: "Beta Two", email: "beta@example.com"),
        ])
        env.mock.failNextAdd = true
        let first = await env.exporter.reconcileAll()
        #expect(first.created == 1)
        #expect(first.failed == 1)
        #expect(env.linkStore.all().count == 1)

        // The failed contact has no link, so it retries as a create.
        let second = await env.exporter.reconcileAll()
        #expect(second.created == 1)
        #expect(env.linkStore.all().count == 2)
        #expect(env.mock.cards.count == 2)
    }

    @Test func incrementalUpsertAndDeleteMaintainLinks() async throws {
        let env = try makeEnvironment()
        let contact = makeContact()
        await env.exporter.exportUpsert(contact)
        #expect(env.mock.cards.count == 1)
        #expect(env.linkStore.all().count == 1)

        await env.exporter.exportDelete(localId: contact.localId)
        #expect(env.mock.cards.isEmpty)
        #expect(env.linkStore.all().isEmpty)
    }

    @Test func deleteOfUnlinkedContactTouchesNothing() async throws {
        let env = try makeEnvironment()
        await env.exporter.exportDelete(localId: UUID())
        #expect(env.mock.deleteCount == 0)
    }

    // MARK: De-duplication (adoption)

    @Test func firstReconcileAdoptsMatchingDeviceCardInsteadOfDuplicating() async throws {
        let env = try makeEnvironment()
        // Same person known to both the device and the relay before first sync.
        try await env.mock.add(makeCard()) // Grace Hopper, grace@example.com
        try await env.dao.upsert(contacts: [
            makeContact(name: "Grace Hopper", email: "grace@example.com"),
        ])

        let summary = await env.exporter.reconcileAll()
        #expect(summary.adopted == 1)
        #expect(summary.created == 0)
        #expect(summary.imported == 0)
        // The card was the user's before we ever looked, so adoption links it
        // for de-duplication only and leaves its contents alone. Refreshing it
        // from app fields let a sparse relay contact strip a real card's
        // phones, addresses and birthday.
        #expect(summary.updated == 0)
        #expect(env.linkStore.all().first?.userOwned == true)
        #expect(env.mock.cards.count == 1) // no junk duplicate card
        #expect(env.linkStore.all().count == 1)
        let contacts = try await env.dao.listAll()
        #expect(contacts.count == 1) // no duplicate app contact either
    }

    @Test func anAdoptedCardIsNeverOverwrittenFromRelayData() async throws {
        let env = try makeEnvironment()
        try await env.mock.add(makeCard()) // Grace Hopper, grace@example.com
        try await env.dao.upsert(contacts: [
            makeContact(name: "Grace Hopper", email: "grace@example.com"),
        ])
        await env.exporter.reconcileAll()
        let identifier = try #require(env.linkStore.all().first?.cnIdentifier)
        let phonesBefore = env.mock.cards[identifier]?.phoneNumbers.count

        // A later, sparse version of the same contact arrives from the relay.
        let sparse = makeContact(
            name: "Grace Hopper",
            email: "grace@example.com",
            updatedAt: Date().addingTimeInterval(60)
        )
        try await env.dao.upsert(contacts: [sparse])
        await env.exporter.reconcileAll()

        // The card the user authored keeps whatever it had.
        #expect(env.mock.cards[identifier]?.phoneNumbers.count == phonesBefore)
    }

    @Test func anAdoptedCardIsNotDeletedWhenItsContactGoesAway() async throws {
        let env = try makeEnvironment()
        try await env.mock.add(makeCard())
        try await env.dao.upsert(contacts: [
            makeContact(name: "Grace Hopper", email: "grace@example.com"),
        ])
        await env.exporter.reconcileAll()
        #expect(env.mock.cards.count == 1)

        // The contact leaves the app; the card was never ours to remove.
        try await env.dao.clearAll()
        await env.exporter.reconcileAll()

        #expect(env.mock.cards.count == 1)
        #expect(env.linkStore.all().isEmpty) // link forgotten, card kept
    }

    @Test func aWholesaleDeletePlanIsRefused() async throws {
        let env = try makeEnvironment()
        // Two cards the app created, then an empty contact store — the shape a
        // tooOld wipe, an HLP rebuild, or a failed database read produces.
        try await env.dao.upsert(contacts: [
            makeContact(name: "A", email: "a@example.com"),
            makeContact(name: "B", email: "b@example.com"),
        ])
        await env.exporter.reconcileAll()
        #expect(env.mock.cards.count == 2)

        try await env.dao.clearAll()
        await env.exporter.reconcileAll()

        // Both cards survive: reconciliation never empties the address book.
        #expect(env.mock.cards.count == 2)
    }

    @Test func newCardMatchingUnlinkedContactIsAdoptedNotImported() async throws {
        let env = try makeEnvironment()
        await env.exporter.reconcileAll() // captures (empty) baseline

        // A relay contact and a device card for the same person appear later.
        try await env.dao.upsert(contacts: [
            makeContact(name: "Grace Hopper", email: "grace@example.com"),
        ])
        try await env.mock.add(makeCard())

        let summary = await env.exporter.reconcileAll()
        #expect(summary.adopted == 1)
        #expect(summary.imported == 0)
        #expect(env.mock.cards.count == 1)
        let contacts = try await env.dao.listAll()
        #expect(contacts.count == 1)
    }

    @Test func exportUpsertAdoptsMatchingCard() async throws {
        let env = try makeEnvironment()
        try await env.mock.add(makeCard())
        await env.exporter.exportUpsert(
            makeContact(name: "Grace Hopper", email: "grace@example.com")
        )
        #expect(env.mock.cards.count == 1) // updated in place, not duplicated
        #expect(env.mock.addCount == 1)    // only the seeded card
        #expect(env.linkStore.all().count == 1)
    }

    @Test func adoptionMatchesAnySystemCardEmail() async throws {
        let env = try makeEnvironment()
        let card = makeCard() // grace@example.com
        card.emailAddresses.append(
            CNLabeledValue(label: CNLabelWork, value: "grace@work.example.com" as NSString)
        )
        try await env.mock.add(card)
        // The relay knows this person by their second (work) email.
        try await env.dao.upsert(contacts: [
            makeContact(name: "Grace Hopper", email: "grace@work.example.com"),
        ])
        let summary = await env.exporter.reconcileAll()
        #expect(summary.adopted == 1)
        #expect(summary.created == 0)
        #expect(env.mock.cards.count == 1)
    }

    // Mirror of adoptionMatchesAnySystemCardEmail, from the app-contact side:
    // the person is known to the app by two addresses and the user's card
    // carries only the second one.
    @Test func adoptionMatchesAnyAppContactEmail() async throws {
        let env = try makeEnvironment()
        try await env.mock.add(makeCard()) // Grace Hopper, grace@example.com
        var contact = makeContact(name: "Grace Hopper", email: "grace@home.example.com")
        contact.emails.append(
            ContactLabeledValue(label: "work", value: "grace@example.com")
        )
        try await env.dao.upsert(contacts: [contact])

        let summary = await env.exporter.reconcileAll()
        #expect(summary.adopted == 1)
        #expect(summary.created == 0)
        #expect(env.mock.cards.count == 1)
    }

    // The same asymmetry on the import side, which is the worse half: an
    // unadopted card becomes a second *app* contact, queued for the relay.
    @Test func doesNotImportCardMatchingANonPrimaryAppContactEmail() async throws {
        let env = try makeEnvironment()
        _ = await env.exporter.reconcileAll() // capture the baseline

        var contact = makeContact(name: "Grace Hopper", email: "grace@home.example.com")
        contact.emails.append(
            ContactLabeledValue(label: "work", value: "grace@example.com")
        )
        try await env.dao.upsert(contacts: [contact])
        try await env.mock.add(makeCard()) // the user's own card, work address only

        let summary = await env.exporter.reconcileAll()
        #expect(summary.imported == 0)
        let contacts = try await env.dao.listAll()
        #expect(contacts.count == 1)
    }

    @Test func adoptionPairsDuplicateEmailsOneToOne() async throws {
        let env = try makeEnvironment()
        try await env.mock.add(makeCard(given: "Grace", family: "Work"))
        try await env.dao.upsert(contacts: [
            makeContact(name: "Grace Work", email: "grace@example.com"),
            makeContact(name: "Grace Home", email: "grace@example.com"),
        ])
        let summary = await env.exporter.reconcileAll()
        // One contact adopts the existing card; the other exports a new one.
        #expect(summary.adopted == 1)
        #expect(summary.created == 1)
        #expect(env.mock.cards.count == 2)
    }

    // MARK: Sync-back import

    @Test func firstReconcileBaselinesExistingCardsInsteadOfImporting() async throws {
        let env = try makeEnvironment()
        try await env.mock.add(makeCard(given: "Preexisting", family: "Person"))
        let summary = await env.exporter.reconcileAll()
        #expect(summary.imported == 0)
        #expect(env.baselineStore.isCaptured)
        let contacts = try await env.dao.listAll()
        #expect(contacts.isEmpty)
    }

    @Test func importsCardAddedAfterBaseline() async throws {
        let env = try makeEnvironment()
        await env.exporter.reconcileAll() // captures (empty) baseline

        try await env.mock.add(makeCard())
        let summary = await env.exporter.reconcileAll()
        #expect(summary.imported == 1)

        let contacts = try await env.dao.listAll()
        #expect(contacts.count == 1)
        #expect(contacts.first?.name == "Grace Hopper")
        #expect(contacts.first?.primaryEmail == "grace@example.com")
        #expect(contacts.first?.needsSync == true)
        #expect(env.linkStore.all().first?.imported == true)

        // Already linked: not imported again.
        let third = await env.exporter.reconcileAll()
        #expect(third.imported == 0)
        let after = try await env.dao.listAll()
        #expect(after.count == 1)
    }

    @Test func appExportedCardsAreNotImportedBack() async throws {
        let env = try makeEnvironment()
        try await env.dao.upsert(contacts: [makeContact()])
        await env.exporter.reconcileAll() // baseline + export create
        let second = await env.exporter.reconcileAll()
        #expect(second.imported == 0)
        let contacts = try await env.dao.listAll()
        #expect(contacts.count == 1)
    }

    @Test func removeAllExportedKeepsImportedUserCards() async throws {
        let env = try makeEnvironment()
        await env.exporter.reconcileAll() // captures (empty) baseline
        try await env.mock.add(makeCard())
        await env.exporter.reconcileAll() // imports the user's card
        #expect(env.linkStore.all().count == 1)

        let removed = await env.exporter.removeAllExported().deleted
        #expect(removed == 0)
        #expect(env.mock.cards.count == 1) // user's card kept
        #expect(env.linkStore.all().isEmpty)

        // Baselined now: not re-imported on the next pass.
        let after = await env.exporter.reconcileAll()
        #expect(after.imported == 0)
    }

    @Test func removeAllExportedDeletesCardsAndForgetsLinks() async throws {
        let env = try makeEnvironment()
        try await env.dao.upsert(contacts: [
            makeContact(name: "Alpha One", email: "alpha@example.com"),
            makeContact(name: "Beta Two", email: "beta@example.com"),
        ])
        await env.exporter.reconcileAll()
        #expect(env.mock.cards.count == 2)

        let removed = await env.exporter.removeAllExported().deleted
        #expect(removed == 2)
        #expect(env.mock.cards.isEmpty)
        #expect(env.linkStore.all().isEmpty)
        #expect(!env.exporter.hasExportedContacts())
    }
}

// MARK: - CNGroup materialization

@MainActor
@Suite struct SystemContactGroupLinkerTests {
    private func make() -> (MockSystemContactStore, SystemContactGroupLinker, SystemContactGroupLinkStore) {
        let store = MockSystemContactStore()
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let links = SystemContactGroupLinkStore(defaults: defaults)
        return (store, SystemContactGroupLinker(store: store, linkStore: links), links)
    }

    @Test func createsAGroupAndRemembersIt() async throws {
        let (store, linker, links) = make()
        let id = try #require(await linker.ensureGroup(id: "g1", name: "Family"))
        #expect(store.groupAddCount == 1)
        #expect(links.link(groupId: "g1")?.cnIdentifier == id)
        // Idempotent: a second pass reuses the link rather than adding again.
        #expect(await linker.ensureGroup(id: "g1", name: "Family") == id)
        #expect(store.groupAddCount == 1)
    }

    /// Adoption, not duplication — the same rule the card path follows.
    @Test func adoptsAGroupTheUserAlreadyHasByName() async throws {
        let (store, linker, links) = make()
        let existing = store.seedGroup(name: "Family")
        let id = await linker.ensureGroup(id: "g1", name: "Family")
        #expect(id == existing.identifier)
        #expect(store.groupAddCount == 0)
        #expect(links.link(groupId: "g1")?.userOwned == true)
    }

    /// A group we adopted is the user's. Renaming it because the backend
    /// renamed *its* group would edit something we never authored.
    @Test func neverRenamesAnAdoptedGroup() async throws {
        let (store, linker, _) = make()
        let existing = store.seedGroup(name: "Family")
        _ = await linker.ensureGroup(id: "g1", name: "Family")
        _ = await linker.ensureGroup(id: "g1", name: "Relatives")
        #expect(store.groups[existing.identifier]?.name == "Family")
    }

    @Test func renamesAGroupItCreatedItself() async throws {
        let (store, linker, _) = make()
        let id = try #require(await linker.ensureGroup(id: "g1", name: "Old"))
        _ = await linker.ensureGroup(id: "g1", name: "New")
        #expect(store.groups[id]?.name == "New")
        #expect(store.groupAddCount == 1)
    }

    /// A link whose group was deleted in Contacts must not keep claiming the
    /// id, or the group can never be re-materialized.
    @Test func recreatesAGroupDeletedInContacts() async throws {
        let (store, linker, links) = make()
        let first = try #require(await linker.ensureGroup(id: "g1", name: "Family"))
        store.removeGroup(identifier: first)
        let second = await linker.ensureGroup(id: "g1", name: "Family")
        #expect(second != nil)
        #expect(second != first)
        #expect(links.link(groupId: "g1")?.cnIdentifier == second)
    }

    @Test func addsAndRemovesMembershipToMatchTheContact() async throws {
        let (store, linker, _) = make()
        let family = try #require(await linker.ensureGroup(id: "g1", name: "Family"))
        let work = try #require(await linker.ensureGroup(id: "g2", name: "Work"))
        let names = ["g1": "Family", "g2": "Work"]

        await linker.syncMembership(cardIdentifier: "card1", groupIDs: ["g1"], groupNames: names)
        #expect(store.members[family]?.contains("card1") == true)
        #expect(store.members[work]?.contains("card1") != true)

        // Moved on the server: the old membership is withdrawn.
        await linker.syncMembership(cardIdentifier: "card1", groupIDs: ["g2"], groupNames: names)
        #expect(store.members[family]?.contains("card1") != true)
        #expect(store.members[work]?.contains("card1") == true)
    }

    /// Removals are scoped to groups this app links. A card the user also put
    /// in their own group stays in it.
    @Test func leavesTheUsersOwnUnlinkedGroupsAlone() async throws {
        let (store, linker, _) = make()
        let climbing = store.seedGroup(name: "Climbing")
        try await store.addMember(contactIdentifier: "card1", toGroup: climbing.identifier)

        _ = await linker.ensureGroup(id: "g1", name: "Family")
        await linker.syncMembership(
            cardIdentifier: "card1", groupIDs: [], groupNames: ["g1": "Family"]
        )
        #expect(store.members[climbing.identifier]?.contains("card1") == true)
    }

    @Test func aGroupIdWithNoKnownNameIsSkipped() async throws {
        // The groups cache is simply behind; inventing a name would create a
        // CNGroup the next pull then renames out from under the user.
        let (store, linker, _) = make()
        await linker.syncMembership(
            cardIdentifier: "card1", groupIDs: ["unknown"], groupNames: [:]
        )
        #expect(store.groupAddCount == 0)
    }
}

// MARK: - Mass-delete guard

/// A reconcile never deletes more than half of the linked cards in one pass:
/// each orphaned link deletes a real card in the user's own Contacts, and a
/// store that lost most of its rows orphans most links at once.
@MainActor
@Suite struct SystemContactsMassDeleteGuardTests {
    private func exported(_ count: Int) async throws -> (ExporterEnvironment, [Contact]) {
        let env = try makeEnvironment()
        let contacts = (0..<count).map { makeContact(name: "Person \($0)", email: "p\($0)@example.com") }
        try await env.dao.upsert(contacts: contacts)
        await env.exporter.reconcileAll()
        #expect(env.mock.cards.count == count)
        return (env, contacts)
    }

    @Test func deletingMoreThanHalfIsWithheldAndReported() async throws {
        let (env, contacts) = try await exported(3)
        for contact in contacts.prefix(2) { try await env.dao.deleteLocal(localId: contact.localId) }

        let summary = await env.exporter.reconcileAll()

        #expect(summary.withheldDeletes == 2)
        #expect(summary.deleted == 0)
        #expect(env.mock.cards.count == 3)
        #expect(env.linkStore.all().count == 3)
    }

    @Test func deletingHalfOrFewerGoesAhead() async throws {
        let (env, contacts) = try await exported(4)
        for contact in contacts.prefix(2) { try await env.dao.deleteLocal(localId: contact.localId) }

        let summary = await env.exporter.reconcileAll()

        #expect(summary.withheldDeletes == 0)
        #expect(summary.deleted == 2)
        #expect(env.mock.cards.count == 2)
    }

    /// The way out the banner names: cards the user already removed in
    /// Contacts delete nothing, so they do not count against the guard.
    @Test func cardsAlreadyDeletedInContactsDoNotCount() async throws {
        let (env, contacts) = try await exported(3)
        for contact in contacts.prefix(2) {
            try await env.dao.deleteLocal(localId: contact.localId)
            let link = try #require(env.linkStore.link(localId: contact.localId))
            try await env.mock.delete(identifier: link.cnIdentifier)
        }

        let summary = await env.exporter.reconcileAll()

        #expect(summary.withheldDeletes == 0)
        #expect(env.linkStore.all().count == 1)
        #expect(env.mock.cards.count == 1)
    }

    @Test func theAllLinksGuardStillHolds() async throws {
        let (env, _) = try await exported(2)
        try await env.dao.clearAll()

        let summary = await env.exporter.reconcileAll()

        #expect(summary.withheldDeletes == 2)
        #expect(env.mock.cards.count == 2)
    }

    /// A Contacts read that fails is not an empty Contacts database: every
    /// linked card would read as already gone and lose its link.
    @Test func aFailedContactsReadChangesNothing() async throws {
        let (env, contacts) = try await exported(4)
        try await env.dao.deleteLocal(localId: contacts[0].localId)
        env.mock.failListAll = true

        let summary = await env.exporter.reconcileAll()

        #expect(summary == SystemContactsExporter.Summary())
        #expect(env.linkStore.all().count == 4)
        #expect(env.mock.deleteCount == 0)
    }
}
