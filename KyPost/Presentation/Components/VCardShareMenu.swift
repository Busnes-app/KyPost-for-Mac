//
//  VCardShareMenu.swift
//  KyPost
//
//  "Share as vCard" / "Export All": a choice of vCard 4.0 or 3.0, each a
//  ShareLink over `VCardExport` (Android #184, VCardShare.kt). Refused under
//  Hostile Location Protection with an explanation, like Android: the
//  receiving app could save the cards anywhere, which is the thing that mode
//  exists to prevent.
//

import SwiftUI

struct VCardShareMenu<Label: View>: View {
    let contacts: [Contact]
    @ViewBuilder let label: () -> Label

    @State private var refusalShown = false

    private var hostileLocation: Bool {
        SingletonGraph.shared.hostileLocationProtectionStore.enabled
    }

    var body: some View {
        if hostileLocation {
            Button { refusalShown = true } label: { label() }
                .alert("Sharing Is Off", isPresented: $refusalShown) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Contacts can't be shared while Hostile Location Protection is on. The receiving app could save them anywhere.")
                }
        } else {
            Menu {
                ShareLink(
                    item: VCardExport(contacts: contacts, version: .v4),
                    preview: SharePreview(VCardWriter.fileName(for: contacts))
                ) {
                    Text("vCard 4.0")
                }
                ShareLink(
                    item: VCardExport(contacts: contacts, version: .v3),
                    preview: SharePreview(VCardWriter.fileName(for: contacts))
                ) {
                    Text("vCard 3.0 (older apps)")
                }
            } label: {
                label()
            }
            .disabled(contacts.isEmpty)
        }
    }
}
