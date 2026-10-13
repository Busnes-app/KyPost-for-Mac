//
//  ContactsListView.swift
//  KyPost
//
//  Contact list with avatars and sync status (spec §4).
//

import SwiftUI

struct ContactsListView: View {
    @Environment(\.theme) private var theme

    @Bindable var viewModel: ContactsViewModel
    @State private var showNewContact = false
    @State private var showScanKey = false
    @State private var syncIntroShown = false

    /// The self-contact first, everyone else in the order the view model
    /// supplies. There is at most one, so this is a partition rather than a
    /// re-sort — the rest of the list keeps whatever order it already had.
    private var orderedContacts: [Contact] {
        let contacts = viewModel.contacts
        guard let selfIndex = contacts.firstIndex(where: \.isSelf) else { return contacts }
        var ordered = contacts
        ordered.insert(ordered.remove(at: selfIndex), at: 0)
        return ordered
    }

    var body: some View {
        Group {
            if viewModel.contacts.isEmpty {
                ScrollView {
                    EmptyStateView(
                        message: "No contacts yet — add one or sync from the server.",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
            } else {
                List(orderedContacts) { contact in
                    NavigationLink(value: contact) {
                        HStack(spacing: 12) {
                            AvatarView(name: contact.name)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(contact.name)
                                        .font(AppFont.ui(15, weight: .medium))
                                        .foregroundStyle(theme.inkStrong)
                                    if contactHasLinkedPgpKey(
                                        contact: contact,
                                        accountIdentityPresent: viewModel.accountIdentityPresent
                                    ) == true {
                                        Image(systemName: "key.fill")
                                            .font(AppFont.ui(10))
                                            .foregroundStyle(theme.accent)
                                            .accessibilityLabel("Has a PGP key")
                                    }
                                    if contact.isSelf {
                                        Text("You")
                                            .font(AppFont.ui(10, weight: .medium))
                                            .foregroundStyle(theme.bg)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(theme.accent))
                                    }
                                }
                                Text(contact.primaryEmail)
                                    .font(AppFont.mono(12))
                                    .foregroundStyle(theme.ink.opacity(0.8))
                            }
                            Spacer()
                            StatusBadgeView(
                                label: contact.uid == nil ? "Local" : "Synced",
                                isActive: contact.uid != nil
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(theme.bg)
                    .listRowSeparatorTint(theme.line)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ContactSyncBanner(viewModel: viewModel)
        }
        .background(theme.bg)
        .navigationTitle("Contacts")
        .navigationDestination(for: Contact.self) { contact in
            ContactDetailView(contact: contact, viewModel: viewModel)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showNewContact = true
                } label: {
                    Label("Add Contact", systemImage: "plus")
                }
            }
            // Add + Sync + Find Duplicates + Scan is more than an iPhone nav
            // bar holds, so everything but Add collapses into one menu.
            ToolbarItem {
                Menu {
                    Button {
                        if viewModel.shouldExplainSync {
                            syncIntroShown = true
                        } else {
                            Task { await viewModel.sync() }
                        }
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.isSyncing)
                    Button {
                        Task { await viewModel.dedupe() }
                    } label: {
                        Label("Find Duplicates", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(viewModel.isSyncing)
                    Button {
                        showScanKey = true
                    } label: {
                        Label("Scan Contact Key", systemImage: "qrcode.viewfinder")
                    }
                    VCardShareMenu(contacts: viewModel.contacts) {
                        Label("Export All as vCard", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    if viewModel.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Contact Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showNewContact) {
            NavigationStack {
                ContactDetailView(contact: nil, viewModel: viewModel)
            }
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showScanKey) {
            ScanPgpKeyView()
                .environment(\.theme, theme)
        }
        .onChange(of: showScanKey) { _, isPresented in
            // A scanned key lands on a contact via the repository, so the list
            // in memory is stale until it reloads.
            if !isPresented { Task { await viewModel.load() } }
        }
        .confirmationDialog(
            "Sync contacts with your server?",
            isPresented: $syncIntroShown,
            titleVisibility: .visible
        ) {
            Button("Sync Contacts") {
                viewModel.markSyncExplained()
                Task { await viewModel.sync() }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            // Shown once, before the first sync rather than after it: the
            // point is to say what is about to leave the device while that is
            // still a choice.
            Text("Contacts sync both ways with your KyPost server. Contacts you add here are uploaded, and contacts from the server appear here. Your server is the only place they go.")
        }
        .task {
            await viewModel.load()
            await viewModel.loadAccountIdentity(from: SingletonGraph.shared.pgpSendService)
        }
        .toast(message: viewModel.statusMessage)
    }
}
