//
//  AcknowledgementsView.swift
//  KyPost
//
//  Third-party licences, reached from About on both platforms. Must sit inside
//  a NavigationStack: iOS pushes it from About, macOS wraps it in one in the
//  About window's sheet.
//

import SwiftUI

struct AcknowledgementsView: View {
    @Environment(\.theme) private var theme

    private let result = Result { try Acknowledgement.load() }

    var body: some View {
        Form {
            switch result {
            case .success(let items):
                Section {
                    ForEach(items) { item in
                        NavigationLink {
                            AcknowledgementDetailView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(AppFont.ui(14, weight: .semibold))
                                    .foregroundStyle(theme.inkStrong)
                                Text(item.detail)
                                    .font(AppFont.ui(12))
                                    .foregroundStyle(theme.secondaryInk)
                                Text(item.license)
                                    .font(AppFont.mono(11))
                                    .foregroundStyle(theme.secondaryInk)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    Text("KyPost includes the software listed here. Each is used under the licence shown with it.")
                }
                .listRowBackground(theme.panel)
            case .failure:
                Text("The acknowledgements could not be loaded.")
                    .foregroundStyle(theme.ink)
                    .listRowBackground(theme.panel)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Acknowledgements")
    }
}

private struct AcknowledgementDetailView: View {
    @Environment(\.theme) private var theme
    let item: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Link(item.url.absoluteString, destination: item.url)
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(item.licenseText)
                    .font(AppFont.mono(11))
                    .textSelection(.enabled)
                    .foregroundStyle(theme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .background(theme.bg)
        .navigationTitle(item.name)
    }
}
