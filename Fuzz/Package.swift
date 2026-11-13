// swift-tools-version: 6.2
//
// Linux-only libFuzzer harness for the app's untrusted-input parsers. Not
// part of the Xcode project. Apple's toolchain ships no libFuzzer for Swift,
// so this builds with the swift.org toolchain (`.github/workflows/fuzz.yml`):
//
//   swift build -c release --product FuzzPgpMimeReader \
//     -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library
//
// The settings match the app target's: Swift 5 mode, MainActor default
// isolation, approachable concurrency.

import PackageDescription

let package = Package(
    name: "KyPostFuzz",
    targets: [
        .executableTarget(
            name: "FuzzPgpMimeReader",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
