// swift-tools-version: 6.0
// Built from checksum-verified Go modules by .github/scripts/build-gopenpgp.sh.
// The bridge and upstream packages MUST share one embedded Go runtime.
import PackageDescription

let package = Package(
    name: "GopenPGP",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "GopenPGP", targets: ["gopenpgp"])],
    targets: [.binaryTarget(name: "gopenpgp", path: "gopenpgp.xcframework")]
)
