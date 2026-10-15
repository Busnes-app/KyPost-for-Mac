// swift-tools-version: 6.0
//
//  GopenPGP
//
//  Wraps the gomobile-built GopenPGP XCFramework as a binary dependency so no
//  18 MB binary lives in this repository's history.
//
//  The binary is built by .github/workflows/gopenpgp-xcframework.yml from
//  ProtonMail/gopenpgp at the tag pinned in Dependencies/gopenpgp.env, using
//  upstream's own build.sh, plus a linker default of GODEBUG
//  asyncpreemptoff=1 baked into the Go runtime (see the workflow's "Bake
//  asyncpreemptoff" step: without it the runtime crashes the process that
//  links it). The checksum below was verified against the
//  published asset independently of the workflow that produced it — the first
//  release's notes quoted a different hash than the asset actually had,
//  because two runs raced.
//
//  SwiftPM refuses the download if the bytes ever stop matching this
//  checksum, which is the property that matters: the binary in this app's
//  crypto path cannot change without this line changing too.
//

import PackageDescription

let package = Package(
    name: "GopenPGP",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "GopenPGP", targets: ["gopenpgp"]),
    ],
    targets: [
        // Named for the .xcframework inside the zip, which SwiftPM matches by
        // name. The Swift module it vends is `Gopenpgp` — that is the name
        // gomobile gave the framework, and it is what source files import.
        .binaryTarget(
            name: "gopenpgp",
            url: "https://github.com/Busnes-app/KyPost-for-Mac/releases/download/gopenpgp-v3.5.2/gopenpgp.xcframework.zip",
            checksum: "ed2ad1463b4dc54149c45dc13a9800c15f9eb1ea0c83609b543476c03663c852"
        ),
    ]
)
