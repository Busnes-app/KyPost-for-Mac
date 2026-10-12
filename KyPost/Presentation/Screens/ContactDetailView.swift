//
//  ContactDetailView.swift
//  KyPost
//
//  Contact page (spec §4). Existing contacts open read-only — a card layout
//  with the 52pt+ avatar header per STYLE_GUIDE §4 — and switch to the edit
//  form via the Edit button. New contacts start in the edit form. Carries the
//  full contactPayload field set (Client_Contact_Update.md); read-only cards
//  show only populated fields, the edit form exposes everything except
//  pgpKey (set via the QR scan flow, display/remove only here).
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContactDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// nil = creating a new contact.
    let contact: Contact?
    let viewModel: ContactsViewModel

    @State private var draft: Contact
    @State private var isEditing: Bool
    /// Empty until the group list is read, and empty for a contact in no
    /// groups — the card is hidden either way, so there is no flash of an
    /// empty section while it loads.
    @State private var groupNames: [String] = []
    @State private var deleteConfirmationShown = false

    init(contact: Contact?, viewModel: ContactsViewModel) {
        self.contact = contact
        self.viewModel = viewModel
        _draft = State(initialValue: contact ?? Self.emptyContact())
        _isEditing = State(initialValue: contact == nil)
    }

    private static func emptyContact() -> Contact {
        Contact(uid: nil, name: "", avatarUrl: nil, createdAt: Date(), updatedAt: Date())
    }

    var body: some View {
        Group {
            if isEditing {
                editForm
            } else {
                detailCards
            }
        }
        .background(theme.bg)
        .navigationTitle(navigationTitle)
        .toolbar { toolbarContent }
        .task(id: draft.groupIDs) {
            groupNames = await viewModel.groupNames(for: draft)
        }
    }

    private var navigationTitle: String {
        if contact == nil { return "New Contact" }
        return isEditing ? "Edit Contact" : (draft.name.isEmpty ? "Contact" : draft.name)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if contact == nil {
                        dismiss()
                    } else {
                        draft = contact ?? Self.emptyContact()
                        isEditing = false
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await save()
                        if contact == nil {
                            dismiss()
                        } else {
                            isEditing = false
                        }
                    }
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            if contact != nil {
                ToolbarItem {
                    // The draft, not `contact`: after an edit it is what was saved.
                    VCardShareMenu(contacts: [draft]) {
                        Label("Share as vCard", systemImage: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Edit") { isEditing = true }
            }
        }
    }

    // MARK: - Read-only cards

    private var detailCards: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                contactInfoCard
                if !draft.org.isEmpty || !draft.title.isEmpty || !draft.department.isEmpty {
                    workCard
                }
                if !draft.birthday.isEmpty || !draft.events.isEmpty || !draft.relations.isEmpty {
                    personalCard
                }
                if !groupNames.isEmpty {
                    groupsCard
                }
                if !draft.notes.isEmpty {
                    notesCard
                }
                if !draft.customFields.isEmpty {
                    customFieldsCard
                }
                if draft.pendingPgpKey != nil {
                    pendingPgpKeyBanner
                }
                if draft.pgpKey != nil || contact?.uid != nil {
                    metadataCard
                }
                if let contact {
                    Button("Delete Contact") { deleteConfirmationShown = true }
                        .buttonStyle(DangerButtonStyle())
                        .confirmationDialog(
                            "Delete \(contact.name.isEmpty ? "this contact" : contact.name)?",
                            isPresented: $deleteConfirmationShown,
                            titleVisibility: .visible
                        ) {
                            Button("Delete Contact", role: .destructive) {
                                Task {
                                    await viewModel.delete(contact)
                                    dismiss()
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            // Names the reach honestly: a synced delete is not
                            // local, and an exported card is a third place the
                            // contact exists.
                            Text(contact.uid == nil
                                ? "This contact has never reached the server, so this removes it from this device."
                                : "This removes the contact from the server and from every device you've paired.")
                        }
                }
            }
            .padding()
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    private var headerCard: some View {
        VStack(spacing: 12) {
            AvatarView(name: draft.name.isEmpty ? "?" : draft.name, size: 72)
            Text(draft.name.isEmpty ? "Unnamed" : draft.name)
                .font(AppFont.ui(22, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
                .multilineTextAlignment(.center)
            if !draft.pronouns.isEmpty {
                Text(draft.pronouns)
                    .font(AppFont.ui(13))
                    .foregroundStyle(theme.ink.opacity(0.7))
            }
            if !draft.nickname.isEmpty {
                Text("“\(draft.nickname)”")
                    .font(AppFont.ui(13))
                    .foregroundStyle(theme.ink.opacity(0.7))
            }
            StatusBadgeView(
                label: contact?.uid == nil ? "Local only" : "Synced",
                isActive: contact?.uid != nil
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.panel))
    }

    private var contactInfoCard: some View {
        card {
            if draft.emails.isEmpty {
                detailRow(icon: "envelope", label: "Email", value: "")
            }
            ForEach(Array(draft.emails.enumerated()), id: \.offset) { _, email in
                detailRow(icon: "envelope", label: email.label ?? "Email", value: email.value)
            }
            rowDivider
            if draft.phones.isEmpty {
                detailRow(icon: "phone", label: "Phone", value: "")
            }
            ForEach(Array(draft.phones.enumerated()), id: \.offset) { _, phone in
                detailRow(icon: "phone", label: phone.label ?? "Phone", value: phone.value)
            }
            ForEach(Array(draft.ims.enumerated()), id: \.offset) { _, im in
                detailRow(icon: "message", label: imServiceName(im), value: im.value)
            }
            ForEach(Array(draft.websites.enumerated()), id: \.offset) { _, site in
                detailRow(icon: "globe", label: site.label ?? "Website", value: site.value)
            }
            ForEach(Array(draft.addresses.enumerated()), id: \.offset) { _, address in
                detailRow(
                    icon: "mappin.and.ellipse",
                    label: address.label ?? "Address",
                    value: formatted(address)
                )
            }
        }
    }

    private var workCard: some View {
        card {
            if !draft.org.isEmpty {
                detailRow(icon: "building.2", label: "Company", value: draft.org)
            }
            if !draft.title.isEmpty {
                detailRow(icon: "briefcase", label: "Title", value: draft.title)
            }
            if !draft.department.isEmpty {
                detailRow(icon: "person.3", label: "Department", value: draft.department)
            }
        }
    }

    private var personalCard: some View {
        card {
            if !draft.birthday.isEmpty {
                detailRow(icon: "birthday.cake", label: "Birthday", value: draft.birthday)
            }
            ForEach(Array(draft.events.enumerated()), id: \.offset) { _, event in
                detailRow(icon: "calendar", label: event.label ?? "Date", value: event.date)
            }
            ForEach(Array(draft.relations.enumerated()), id: \.offset) { _, relation in
                detailRow(
                    icon: "person.2",
                    label: relation.label ?? "Related",
                    value: relation.name
                )
            }
        }
    }

    /// Group names, resolved from `Contact.groupIDs` against the pulled group
    /// list. Loaded in `.task` rather than computed: the lookup crosses an
    /// actor, and SwiftUI re-evaluates `body` far too often for that.
    private var groupsCard: some View {
        card {
            ForEach(groupNames, id: \.self) { name in
                detailRow(icon: "person.3", label: "Group", value: name)
            }
        }
    }

    private var notesCard: some View {
        card {
            detailRow(icon: "note.text", label: "Notes", value: draft.notes)
        }
    }

    private var customFieldsCard: some View {
        card {
            ForEach(Array(draft.customFields.enumerated()), id: \.offset) { _, field in
                detailRow(icon: "tag", label: field.label, value: field.value)
            }
        }
    }

    /// Shown when sync received a PGP key that differs from the one already
    /// on file — see ContactSyncRepository.applyPgpKey. Mirrors the
    /// "Replace existing key?" confirmation on the manual QR-attach path
    /// (ScanPgpKeyView/ContactKeyPicker), extended to the sync path where a
    /// compromised relay could otherwise swap a fingerprint-verified key
    /// with no warning at all.
    private var pendingPgpKeyBanner: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SemanticColors.warning)
                        .frame(width: 32, height: 32)
                        .background(SemanticColors.warning.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PGP KEY CHANGED")
                            .font(AppFont.ui(11, weight: .medium))
                            .foregroundStyle(theme.ink.opacity(0.65))
                        Text("A different key arrived for this contact. Check the new fingerprint with them over a channel the server doesn't control before trusting it.")
                            .font(AppFont.ui(13))
                            .foregroundStyle(theme.inkStrong)
                    }
                    Spacer(minLength: 0)
                }
                // Without these the banner asked for a comparison the app gave
                // the user no way to make: no fingerprint was rendered anywhere
                // for a stored or pending key, so "Trust New Key" was a blind
                // one-tap decision.
                VStack(alignment: .leading, spacing: 6) {
                    fingerprintRow(label: "CURRENT", armored: draft.pgpKey)
                    fingerprintRow(label: "NEW", armored: draft.pendingPgpKey)
                }
                HStack(spacing: 12) {
                    Button("Keep Current Key") {
                        let toDismiss = draft
                        draft.pendingPgpKey = nil
                        Task { await viewModel.dismissPendingPgpKey(for: toDismiss) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Trust New Key") {
                        let toAccept = draft
                        if let pending = draft.pendingPgpKey {
                            draft.pgpKey = pending
                        }
                        draft.pendingPgpKey = nil
                        Task { await viewModel.acceptPendingPgpKey(for: toAccept) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// One labelled fingerprint line, computed from the key's own bytes.
    private func fingerprintRow(label: String, armored: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppFont.ui(11, weight: .medium))
                .foregroundStyle(theme.ink.opacity(0.65))
            Text(Self.fingerprintText(for: armored))
                .font(AppFont.mono(12))
                .foregroundStyle(theme.inkStrong)
                .textSelection(.enabled)
        }
    }

    /// Grouped fingerprint for an armored key, or a plain marker when the key
    /// can't be parsed — never a fabricated value.
    static func fingerprintText(for armored: String?) -> String {
        guard let armored, !armored.isEmpty else { return "None" }
        guard let fingerprint = PgpFingerprint.compute(fromArmored: armored) else {
            return "Unreadable key"
        }
        return ScanPgpKeyView.groupedFingerprint(fingerprint)
    }

    private var metadataCard: some View {
        card {
            if let pgpKey = draft.pgpKey {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(width: 32, height: 32)
                        .background(theme.accentSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PGP KEY")
                            .font(AppFont.ui(11, weight: .medium))
                            .foregroundStyle(theme.ink.opacity(0.65))
                        // The fingerprint, not just "on file": this is the
                        // value the user compares out of band, and it was
                        // previously unreachable anywhere in the app for a
                        // stored key.
                        Text(Self.fingerprintText(for: pgpKey))
                            .font(AppFont.mono(12))
                            .foregroundStyle(theme.inkStrong)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button("Copy") { copyToPasteboard(pgpKey) }
                        .buttonStyle(.borderless)
                        .font(AppFont.ui(13))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            if let uid = contact?.uid {
                if draft.pgpKey != nil { rowDivider }
                detailRow(icon: "arrow.triangle.2.circlepath", label: "Sync ID", value: uid)
            }
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.vertical, 6)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.panel))
    }

    private var rowDivider: some View {
        Divider()
            .overlay(theme.line)
            .padding(.leading, 58)
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 32, height: 32)
                .background(theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(theme.ink.opacity(0.65))
                Text(value.isEmpty ? "—" : value)
                    .font(AppFont.mono(14))
                    .foregroundStyle(value.isEmpty ? theme.ink.opacity(0.5) : theme.inkStrong)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func imServiceName(_ im: ContactIM) -> String {
        SystemContactMapper.imService(code: im.service)?.displayName
            ?? im.label
            ?? "IM"
    }

    private func formatted(_ address: ContactPostalAddress) -> String {
        let cityLine = [address.city, address.region, address.postalCode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [address.street, cityLine.isEmpty ? nil : cityLine, address.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func copyToPasteboard(_ string: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#else
        UIPasteboard.general.string = string
#endif
    }

    // MARK: - Edit form

    private static let relationLabels = [
        "spouse", "child", "parent", "partner", "manager",
        "assistant", "friend", "relative", "other",
    ]

    private var editForm: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    AvatarView(name: draft.name.isEmpty ? "?" : draft.name, size: 52)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("Name") {
                TextField("Name", text: $draft.name)
                    .font(AppFont.ui(15))
                TextField("Nickname", text: $draft.nickname)
                    .font(AppFont.ui(15))
                TextField("Pronouns", text: $draft.pronouns)
                    .font(AppFont.ui(15))
            }
            .listRowBackground(theme.panel)

            EditableListSection(
                title: "Emails",
                addTitle: "Add Email",
                items: $draft.emails,
                makeItem: { ContactLabeledValue(label: nil, value: "") }
            ) { $item in
                LabeledValueRow(
                    label: $item.label,
                    value: $item.value,
                    valuePlaceholder: "Email"
                )
            }

            EditableListSection(
                title: "Phones",
                addTitle: "Add Phone",
                items: $draft.phones,
                makeItem: { ContactLabeledValue(label: nil, value: "") }
            ) { $item in
                LabeledValueRow(
                    label: $item.label,
                    value: $item.value,
                    valuePlaceholder: "Phone"
                )
            }

            EditableListSection(
                title: "Addresses",
                addTitle: "Add Address",
                items: $draft.addresses,
                makeItem: { ContactPostalAddress() }
            ) { $item in
                addressFields($item)
            }

            Section("Work") {
                TextField("Company", text: $draft.org)
                    .font(AppFont.ui(15))
                TextField("Title", text: $draft.title)
                    .font(AppFont.ui(15))
                TextField("Department", text: $draft.department)
                    .font(AppFont.ui(15))
            }
            .listRowBackground(theme.panel)

            EditableListSection(
                title: "Instant Messaging & Social",
                addTitle: "Add Handle",
                items: $draft.ims,
                makeItem: { ContactIM(service: nil, label: nil, value: "") }
            ) { $item in
                imFields($item)
            }

            EditableListSection(
                title: "Websites",
                addTitle: "Add Website",
                items: $draft.websites,
                makeItem: { ContactLabeledValue(label: nil, value: "") }
            ) { $item in
                LabeledValueRow(
                    label: $item.label,
                    value: $item.value,
                    valuePlaceholder: "URL"
                )
            }

            EditableListSection(
                title: "Related People",
                addTitle: "Add Person",
                items: $draft.relations,
                makeItem: { ContactRelation(label: "other", name: "") }
            ) { $item in
                relationFields($item)
            }

            birthdaySection

            EditableListSection(
                title: "Dates",
                addTitle: "Add Date",
                items: $draft.events,
                makeItem: { ContactEvent(label: "anniversary", date: "") }
            ) { $item in
                LabeledValueRow(
                    label: $item.label,
                    value: $item.date,
                    valuePlaceholder: "YYYY-MM-DD"
                )
            }

            Section("Phonetic Name") {
                TextField("Phonetic given name", text: $draft.phoneticGivenName)
                    .font(AppFont.ui(15))
                TextField("Phonetic family name", text: $draft.phoneticFamilyName)
                    .font(AppFont.ui(15))
            }
            .listRowBackground(theme.panel)

            Section("Notes") {
                TextEditor(text: $draft.notes)
                    .font(AppFont.ui(14))
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
            }
            .listRowBackground(theme.panel)

            EditableListSection(
                title: "Custom Fields",
                addTitle: "Add Field",
                items: $draft.customFields,
                makeItem: { ContactCustomField(label: "", value: "") }
            ) { $item in
                HStack(spacing: 8) {
                    TextField("Label", text: $item.label)
                        .font(AppFont.ui(13))
                        .frame(width: 90)
                    TextField("Value", text: $item.value)
                        .font(AppFont.mono(14))
                }
            }

            if draft.pgpKey != nil {
                Section("PGP Key") {
                    HStack {
                        Label("Public key on file", systemImage: "lock.shield")
                            .font(AppFont.ui(14))
                        Spacer()
                        Button("Remove", role: .destructive) {
                            draft.pgpKey = nil
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .listRowBackground(theme.panel)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var birthdaySection: some View {
        Section("Birthday") {
            Toggle("Set birthday", isOn: Binding(
                get: { !draft.birthday.isEmpty },
                set: { hasBirthday in
                    draft.birthday = hasBirthday ? Self.isoString(from: Date()) : ""
                }
            ))
            .font(AppFont.ui(15))
            if !draft.birthday.isEmpty {
                DatePicker(
                    "Date",
                    selection: birthdayBinding,
                    displayedComponents: .date
                )
                .font(AppFont.ui(15))
            }
        }
        .listRowBackground(theme.panel)
    }

    private var birthdayBinding: Binding<Date> {
        Binding(
            get: {
                SystemContactMapper.dateComponents(fromISODate: draft.birthday)
                    .flatMap { Calendar.current.date(from: $0) } ?? Date()
            },
            set: { draft.birthday = Self.isoString(from: $0) }
        )
    }

    private static func isoString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
    }

    private func addressFields(_ item: Binding<ContactPostalAddress>) -> some View {
        VStack(spacing: 6) {
            TextField("Label", text: optionalBinding(item.label))
                .font(AppFont.ui(13))
            TextField("Street", text: optionalBinding(item.street))
                .font(AppFont.ui(14))
            HStack(spacing: 8) {
                TextField("City", text: optionalBinding(item.city))
                TextField("Region", text: optionalBinding(item.region))
            }
            .font(AppFont.ui(14))
            HStack(spacing: 8) {
                TextField("Postal code", text: optionalBinding(item.postalCode))
                TextField("Country", text: optionalBinding(item.country))
            }
            .font(AppFont.ui(14))
        }
    }

    private func imFields(_ item: Binding<ContactIM>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { item.wrappedValue.service ?? "" },
                set: { item.wrappedValue.service = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(SystemContactMapper.imServiceCatalog, id: \.code) { service in
                    Text(service.displayName).tag(service.code)
                }
                Text("Other").tag("")
            }
            .labelsHidden()
            .frame(width: 110)
            if item.wrappedValue.service == nil {
                TextField("Service", text: optionalBinding(item.label))
                    .font(AppFont.ui(13))
                    .frame(width: 80)
            }
            TextField("Handle", text: item.value)
                .font(AppFont.mono(14))
        }
    }

    private func relationFields(_ item: Binding<ContactRelation>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { item.wrappedValue.label ?? "other" },
                set: { item.wrappedValue.label = $0 }
            )) {
                ForEach(Self.relationLabels, id: \.self) { label in
                    Text(label.capitalized).tag(label)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            TextField("Name", text: item.name)
                .font(AppFont.ui(14))
        }
    }

    private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Actions

    private func save() async {
        var updated = draft
        updated.name = updated.name.trimmingCharacters(in: .whitespaces)
        // The form edits the display name only; when it changed, stale
        // structured name parts would disagree with it on the server, so
        // clear them (export then falls back to splitting the display name).
        if updated.name != (contact?.name ?? "") {
            updated.givenName = ""
            updated.familyName = ""
            updated.middleName = ""
            updated.prefix = ""
            updated.suffix = ""
        }
        updated.emails = cleaned(updated.emails)
        updated.phones = cleaned(updated.phones)
        updated.websites = cleaned(updated.websites)
        updated.ims = updated.ims.filter {
            !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        updated.relations = updated.relations.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        updated.events = updated.events.filter {
            SystemContactMapper.dateComponents(fromISODate: $0.date) != nil
        }
        updated.customFields = updated.customFields.filter {
            !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        updated.addresses = updated.addresses.filter { address in
            [address.street, address.city, address.region, address.postalCode, address.country]
                .contains { !($0 ?? "").isEmpty }
        }
        draft = updated
        await viewModel.save(updated)
    }

    private func cleaned(_ values: [ContactLabeledValue]) -> [ContactLabeledValue] {
        values
            .map { ContactLabeledValue(
                label: $0.label,
                value: $0.value.trimmingCharacters(in: .whitespaces)
            ) }
            .filter { !$0.value.isEmpty }
    }
}
