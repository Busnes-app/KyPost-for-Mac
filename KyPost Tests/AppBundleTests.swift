//
//  AppBundleTests.swift
//  KyPost Tests
//
//  What ships inside KyPost.app. The suite runs hosted in the app, so
//  Bundle.main is the built product and these read what an upload would carry.
//

import Foundation
import Testing
@testable import KyPost

struct AppBundleTests {
    // AGENTS.md files are working contracts for agents, not app content. The
    // synchronized root group copies every file under KyPost/ unless
    // project.pbxproj lists it as a membership exception.
    @Test func noAgentsDocIsBundled() throws {
        let enumerator = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)
        let docs = (enumerator?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent == "AGENTS.md" }
        #expect(docs.isEmpty, "bundled: \(docs.map(\.path))")
    }

    // App Store Connect rejects an upload (ITMS-91053) that calls a
    // required-reason API its manifest does not declare. The GopenPGP archive
    // has no manifest of its own, so its stat and mach_absolute_time imports
    // are declared in ours.
    @Test func privacyManifestDeclaresEveryRequiredReasonAPI() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        let types = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in types {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[category] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        #expect(reasons == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        ])
    }

    @Test func everyAcknowledgementHasItsLicenceText() throws {
        let items = try Acknowledgement.load()
        let names = Set(items.map(\.name))
        for required in ["GopenPGP", "go-crypto", "go-mime", "CIRCL", "The Go standard library and runtime"] {
            #expect(names.contains(required), "missing \(required)")
        }
        for item in items {
            #expect(item.licenseText.count > 500, "\(item.name): licence text looks truncated")
        }
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func aMissingLicenceFileFailsTheLoadInsteadOfDroppingTheEntry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = #"[{"name":"X","detail":"d","license":"MIT","url":"https://example.com","licenseFile":"Nope"}]"#
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("Acknowledgements.json"))
        let bundle = try #require(Bundle(url: dir))

        #expect(throws: Acknowledgement.LoadError.missingLicenseFile("Nope")) {
            try Acknowledgement.load(from: bundle)
        }
    }
}
