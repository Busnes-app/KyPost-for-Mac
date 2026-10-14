//
//  AddressBookView.swift
//  KyPost
//
//  Browse-and-pick address book for compose (ContactAutocomplete.md §3).
//  Presented as a sheet on the compose window, which is what settles "the
//  active composition window" — with several compose windows open on macOS,
//  the answer is definitionally the one this sheet is modal to.
//

import SwiftUI

struct AddressBookView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Reading @Observable state here is what re-renders the added-ticks as
    /// recipients change; nothing else to wire up.
    let viewModel: ComposeViewModel

    @State private var search = ""
    /// Chosen address per contact, for contacts with more than one.
    @State private var chosenAddress: [UUID: String] = [:]
    /// Held rather than computed in `body`: this scan is unbounded, and body
    /// re-runs for every token added and every toast, none of which change
    /// the results.
    @State private var matches: [ContactMatch] = []

    var body: some View {
#if os(macOS)
        content
            .frame(minWidth: 640, minHeight: 460)
#else
        NavigationStack {
            content
                .navigationTitle("Contacts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
#endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                searchBar
#if os(macOS)
                // SecondaryButtonStyle stretches to maxWidth for sheet
                // footers; pin it so it doesn't swallow the search bar.
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 90)
#endif
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            header
            Divider().overlay(theme.line)
            if matches.isEmpty {
                EmptyStateView(
                    message: search.isEmpty
                        ? "No contacts yet"
                        : "No contacts found",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(theme.bg)
        .task { refresh() }
        .onChange(of: search) { refresh() }
        // The compose window's own toast renders behind this sheet, so the
        // duplicate notice has to be bound here as well to be seen at all.
        .toast(message: viewModel.toastMessage)
#if os(macOS)
#endif
    }

    private func refresh() {
        matches = ContactSearch.matches(search, in: viewModel.contactIndex, options: .directory)
    }

    private var searchBar: some View {
        TextField("Search contacts", text: $search)
            .textFieldStyle(.plain)
            .font(AppFont.ui(14))
            .padding(10)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
            .overlay(
                RoundedRectangle(cornerRadius: Shape.field)
                    .strokeBorder(theme.line, lineWidth: 1)
            )
#if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#endif
    }

    private var header: some View {
        row(
            name: Text("Name"),
            email: Text("Email"),
            department: Text("Department"),
            actions: Text("")
        )
        .font(AppFont.ui(11, weight: .semibold))
        .foregroundStyle(theme.secondaryInk)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var list: some View {
        List {
            ForEach(matches) { match in
                contactRow(match)
                    .listRowBackground(theme.bg)
                    .listRowSeparatorTint(theme.line)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Fixed column widths shared by the header and every row. A Grid per row
    /// won't do: separate Grids size their columns independently, so the
    /// header would drift out of line with the rows. A Table would align for
    /// free but collapses to one column on iOS and can't be themed.
    private enum Column {
        static let name: CGFloat = 170
        static let department: CGFloat = 100
        static let actions: CGFloat = 130
    }

    private func row(
        name: some View,
        email: some View,
        department: some View,
        actions: some View
    ) -> some View {
        HStack(spacing: 10) {
            name.frame(width: Column.name, alignment: .leading)
            email.frame(maxWidth: .infinity, alignment: .leading)
            department.frame(width: Column.department, alignment: .leading)
            actions.frame(width: Column.actions, alignment: .trailing)
        }
    }

    private func contactRow(_ match: ContactMatch) -> some View {
        let contact = match.entry.contact
        let address = chosenAddress[contact.localId] ?? match.entry.address
        return row(
            name: HStack(spacing: 8) {
                AvatarView(name: match.entry.displayName, size: 24)
                HighlightedText(
                    text: match.entry.displayName,
                    highlight: match.nameHighlight,
                    font: AppFont.ui(13),
                    highlightFont: AppFont.ui(13, weight: .bold)
                )
                .foregroundStyle(theme.inkStrong)
                .lineLimit(1)
            },
            email: addressCell(contact: contact, match: match, address: address),
            department: Text(contact.department)
                .font(AppFont.ui(12))
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1),
            actions: HStack(spacing: 4) {
                ForEach(RecipientField.allCases, id: \.self) { field in
                    addButton(field, contact: contact, name: match.entry.displayName, address: address)
                }
            }
        )
    }

    /// Contacts with several addresses get a menu; the rest are plain text.
    @ViewBuilder
    private func addressCell(contact: Contact, match: ContactMatch, address: String) -> some View {
        let all = contact.emails.map(\.value).filter { !$0.isEmpty }
        if all.count > 1 {
            Menu {
                ForEach(all, id: \.self) { option in
                    Button(option) { chosenAddress[contact.localId] = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(address)
                        .font(AppFont.mono(11))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(theme.secondaryInk)
            }
            .menuStyle(.borderlessButton)
        } else {
            HighlightedText(
                text: address,
                highlight: match.addressHighlight,
                font: AppFont.mono(11),
                highlightFont: AppFont.mono(11, weight: .bold)
            )
            .foregroundStyle(theme.secondaryInk)
            .lineLimit(1)
        }
    }

    private func addButton(
        _ field: RecipientField,
        contact: Contact,
        name: String,
        address: String
    ) -> some View {
        let isAdded = viewModel[field].contains { $0.comparisonKey == address.lowercased() }
        // add() refuses an address that's already a recipient anywhere, so
        // the other two fields are shown disabled rather than looking
        // available and then silently refusing.
        let isElsewhere = !isAdded && viewModel.isRecipient(address)
        return Button {
            viewModel.add(
                RecipientToken(address: address, displayName: name, contactId: contact.localId),
                to: field
            )
        } label: {
            HStack(spacing: 3) {
                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(field.buttonLabel)
                    .font(AppFont.ui(10, weight: .semibold))
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            // Sized for the checked state up front, so gaining a checkmark
            // doesn't squeeze the label ("✓ T(") or shove the row about.
            .frame(width: 40)
            .foregroundStyle(isAdded ? theme.readableOnAccent : theme.ink)
            .background(isAdded ? theme.accent : theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
            .opacity(isElsewhere ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isElsewhere)
        .help(helpText(isAdded: isAdded, isElsewhere: isElsewhere, field: field))
        .accessibilityLabel("Add \(address) to \(field.buttonLabel)")
    }

    private func helpText(isAdded: Bool, isElsewhere: Bool, field: RecipientField) -> String {
        if isAdded { return "Already in \(field.buttonLabel)" }
        if isElsewhere { return "Already a recipient in another field" }
        return "Add to \(field.buttonLabel)"
    }
}

private extension RecipientField {
    var buttonLabel: String {
        switch self {
        case .to: "TO"
        case .cc: "CC"
        case .bcc: "BCC"
        }
    }
}
