//
//  SignatureSettingsView.swift
//  KyPost
//
//  The mobile signature (`MailSignatureStore`): a Settings destination on
//  iOS and a Settings pane on macOS. Kept on this device only; the web
//  signature lives on the server and is never read here. Every change saves
//  at once; a refused text saves nothing, says why, and holds the switches
//  until it is fixed. Compose places the
//  signature, never this screen.
//

import SwiftUI

struct SignatureSettingsView: View {
    @Environment(\.theme) private var theme

    @State private var settings = MailSignatureSettings()
    @State private var problem: MailSignatureProblem?
    @State private var loaded = false

    private var store: MailSignatureStore { SingletonGraph.shared.mailSignatureStore }

    var body: some View {
        Form {
            Section {
                Toggle("Use a signature", isOn: $settings.isOn)
            }
            // A refused text saves nothing (owner, Q4 B), so a switch moved
            // now would show a state that is not stored.
            .disabled(problem != nil)
            .listRowBackground(theme.panel)

            Section {
                TextEditor(text: $settings.text)
                    .font(AppFont.mono(13))
                    .frame(minHeight: 120)
                    .accessibilityLabel("Signature text")
                if let problem {
                    StatusText(problem.message + " " + String(localized: "Nothing is saved, switches included, until the text is fixed."), kind: .danger, size: 12)
                }
            } header: {
                Text("Signature")
            } footer: {
                Text("Used only on this device. Your web signature is set in KyPost on the web. Plain text. \(settings.text.unicodeScalars.count)/\(MailSignatureStore.maxCharacters)")
            }
            .listRowBackground(theme.panel)

            Section {
                Toggle("Add to replies", isOn: $settings.addToReplies)
                Toggle("Add to forwards", isOn: $settings.addToForwards)
            }
            .disabled(!settings.isOn || problem != nil)
            .listRowBackground(theme.panel)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Signature")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            settings = store.settings
        }
        .onChange(of: settings) { _, new in
            guard loaded else { return }
            problem = store.save(new)
        }
    }
}
