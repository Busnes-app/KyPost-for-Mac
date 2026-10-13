//
//  SignatureSettingsView.swift
//  KyPost
//
//  Edits the plain-text email signature (Android #177): a Settings
//  destination on iOS and a Settings pane on macOS. Plain text only, at most
//  `MailSignatureStore.maxCharacters`; compose places it, never this screen.
//

import SwiftUI

struct SignatureSettingsView: View {
    @Environment(\.theme) private var theme

    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(AppFont.mono(13))
                    .frame(minHeight: 120)
                    .onChange(of: text) { _, new in
                        if new.count > MailSignatureStore.maxCharacters {
                            text = String(new.prefix(MailSignatureStore.maxCharacters))
                        }
                    }
            } header: {
                Text("Signature")
            } footer: {
                Text("Added below a “-- ” line on new messages, replies and forwards, above any quoted text. Plain text only. \(text.count)/\(MailSignatureStore.maxCharacters)")
            }
            .listRowBackground(theme.panel)

            Section {
                HStack {
                    Button("Save") {
                        SingletonGraph.shared.mailSignatureStore.save(text)
                        saved = SingletonGraph.shared.mailSignatureStore.signature
                        text = saved
                    }
                    .disabled(text == saved)
                    Spacer()
                    if !saved.isEmpty {
                        Button("Remove Signature", role: .destructive) {
                            SingletonGraph.shared.mailSignatureStore.clear()
                            saved = ""
                            text = ""
                        }
                    }
                }
            }
            .listRowBackground(theme.panel)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Signature")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            saved = SingletonGraph.shared.mailSignatureStore.signature
            text = saved
        }
    }
}
