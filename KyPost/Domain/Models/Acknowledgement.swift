//
//  Acknowledgement.swift
//  KyPost
//
//  Third-party software shipped inside the app, with the licence text each
//  one requires us to reproduce. The list and the texts are bundle resources
//  (Resources/Acknowledgements), so a dependency bump edits files, not Swift.
//

import Foundation

struct Acknowledgement: Identifiable, Hashable {
    let name: String
    let detail: String
    /// SPDX identifier, e.g. "MIT" or "BSD-3-Clause".
    let license: String
    let url: URL
    let licenseText: String

    var id: String { name }

    enum LoadError: Error, Equatable {
        case missingManifest
        case missingLicenseFile(String)
    }

    private struct Entry: Decodable {
        let name: String
        let detail: String
        let license: String
        let url: URL
        /// A `.txt` resource name without its extension. The synchronized
        /// group copies resources flat into the bundle, so this is a bare
        /// name, never a path.
        let licenseFile: String
    }

    /// Reads `Acknowledgements.json` and the licence file each entry names.
    /// Throws on any missing file rather than dropping the entry: shipping a
    /// dependency without its licence text is the thing this list prevents.
    static func load(from bundle: Bundle = .main) throws -> [Acknowledgement] {
        guard let manifest = bundle.url(forResource: "Acknowledgements", withExtension: "json") else {
            throw LoadError.missingManifest
        }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifest))
        return try entries.map { entry in
            guard let file = bundle.url(forResource: entry.licenseFile, withExtension: "txt") else {
                throw LoadError.missingLicenseFile(entry.licenseFile)
            }
            return Acknowledgement(
                name: entry.name,
                detail: entry.detail,
                license: entry.license,
                url: entry.url,
                licenseText: try String(contentsOf: file, encoding: .utf8)
            )
        }
    }
}
