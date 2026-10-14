//
//  AboutView.swift
//  KyPost
//
//  Shared About and Support surface for iOS and macOS.
//

import SwiftUI
import StoreKit
#if os(macOS)
import AppKit
#endif

struct AboutView: View {
    @Environment(\.theme) private var theme
    @State private var tipJar = TipJarStore()
    #if os(macOS)
    @State private var showAcknowledgements = false
    #endif

    private let privacyPolicyURL = URL(string: "https://www.kypost.org/privacy.html")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        mobileBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(spacing: 5) {
                    Text("KyPost")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.inkStrong)
                    Text("Version ") + Text(version) + Text("  ·  Copyright © 2026 Busnes.app")
                        .font(AppFont.ui(12))
                        .foregroundStyle(theme.secondaryInk)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Tip Jar")
                        .font(AppFont.ui(17, weight: .semibold))
                        .foregroundStyle(theme.inkStrong)
                    Text("If KyPost is useful to you, you can support its continued development with a one-off tip.")
                        .font(AppFont.ui(13))
                        .foregroundStyle(theme.secondaryInk)

                    ForEach(tipJar.products, id: \.id) { product in
                        Button {
                            Task { await tipJar.purchase(product) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(theme.accent)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName)
                                        .font(AppFont.ui(14, weight: .semibold))
                                        .foregroundStyle(theme.inkStrong)
                                    Text("One-off tip")
                                        .font(AppFont.ui(12))
                                        .foregroundStyle(theme.secondaryInk)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(AppFont.ui(14, weight: .semibold))
                                    .foregroundStyle(theme.inkStrong)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(tipJar.isLoading)
                    }

                    if let status = tipJar.statusMessage {
                        Text(status)
                            .font(AppFont.ui(13))
                            .foregroundStyle(theme.secondaryInk)
                    }
                    Text("Payments are processed securely by Apple.")
                        .font(AppFont.ui(12))
                        .foregroundStyle(theme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(theme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 20) {
                    Link("Privacy Policy", destination: privacyPolicyURL)
                    Button("Acknowledgements") { showAcknowledgements = true }
                        .buttonStyle(.link)
                }
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(theme.accent)

                DisclosureGroup {
                    ScrollView {
                        Text(Self.mitLicense)
                            .font(AppFont.mono(10))
                            .textSelection(.enabled)
                            .foregroundStyle(theme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 170)
                    .padding(.top, 8)
                } label: {
                    Text("MIT License")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(theme.inkStrong)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
        .background(theme.bg)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 560, idealHeight: 620)
        .task { await tipJar.start() }
        // The About window is not a navigation stack, so the list opens as a
        // sheet. It shows only bundled licence text, nothing from the account.
        .sheet(isPresented: $showAcknowledgements) {
            NavigationStack {
                AcknowledgementsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showAcknowledgements = false }
                        }
                    }
            }
            .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 600)
            .environment(\.theme, theme)
        }
    }
    #else
    private var mobileBody: some View {
        Form {
            Section("KyPost") {
                LabeledContent("Version", value: version)
                Text("Copyright © 2026 Busnes.app")
                    .foregroundStyle(theme.secondaryInk)
            }
            .listRowBackground(theme.panel)

            Section {
                Text("If KyPost is useful to you, you can support its continued development with a one-off tip.")
                    .foregroundStyle(theme.secondaryInk)

                ForEach(tipJar.products, id: \.id) { product in
                    Button {
                        Task { await tipJar.purchase(product) }
                    } label: {
                        LabeledContent {
                            Text(product.displayPrice)
                        } label: {
                            Label(product.displayName, systemImage: "heart")
                        }
                    }
                    .disabled(tipJar.isLoading)
                }

                if let status = tipJar.statusMessage {
                    Text(status)
                        .font(AppFont.ui(13))
                        .foregroundStyle(theme.secondaryInk)
                }
            } header: {
                Text("Tip Jar")
            } footer: {
                Text("Payments are processed securely by Apple.")
            }
            .listRowBackground(theme.panel)

            Section {
                Link("Privacy Policy", destination: privacyPolicyURL)
                NavigationLink("Acknowledgements") {
                    AcknowledgementsView()
                }
            }
            .listRowBackground(theme.panel)

            Section("MIT License") {
                Text(Self.mitLicense)
                    .font(AppFont.mono(11))
                    .textSelection(.enabled)
                    .foregroundStyle(theme.secondaryInk)
            }
            .listRowBackground(theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("About")
        .task { await tipJar.start() }
    }
    #endif

    private static let mitLicense = """
    MIT License

    Copyright (c) 2026 Busnes.app

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
