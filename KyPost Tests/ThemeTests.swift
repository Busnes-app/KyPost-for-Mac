//
//  ThemeTests.swift
//  KyPost Tests
//
//  The six ky-ui theme pairs (values, halves, status colours), the WCAG and
//  status-colour gate ported from ky-ui `scripts/check-status-colours.mjs`,
//  ThemeManager persistence and the migration of saved single-palette names,
//  inbox filtering.
//

import Foundation
import SwiftUI
import Testing
@testable import KyPost

// MARK: - Palette contract

@Suite struct ThemePaletteTests {
    /// ky-ui `THEME_PAIRS`: IDs are saved, so their spelling is contract.
    @Test func pairsMatchKyUi() {
        #expect(AppTheme.pairs.map(\.id) == [
            "busnes-pair", "matter-pair", "ocean-pair", "forest-pair", "ky-pair", "nord-pair",
        ])
        #expect(AppTheme.pairs.map(\.name) == ["Busnes", "Matter", "Ocean", "Forest", "Ky", "Nord"])
    }

    @Test func defaultIsBusnes() {
        #expect(AppTheme.defaultPair.id == "busnes-pair")
        #expect(AppTheme.pair(id: "tropics") == nil)
    }

    /// Unchanged from before the pairs; `line` is the opaque composite of
    /// the web's translucent value.
    @Test func busnesHalvesAreUnchanged() {
        let busnes = AppTheme.defaultPair
        #expect(busnes.light == ThemePalette(
            bg: 0xF8F6F0, panel: 0xFFFFFF, ink: 0x566461, inkStrong: 0x182326,
            accent: 0xBF3F18, accentSoft: 0xFBF0EC, line: 0xCCCFCF, isLight: true
        ))
        #expect(busnes.dark == ThemePalette(
            bg: 0x182326, panel: 0x1F2B2E, ink: 0xB3BCB8, inkStrong: 0xF2EFE8,
            accent: 0xF5865F, accentSoft: 0x2B2622, line: 0x525A5B, isLight: false
        ))
    }

    /// Sampled from ky-ui `THEME_PALETTES` — the binding contract.
    @Test func spotCheckValuesAgainstKyUi() {
        let ocean = AppTheme.pair(id: "ocean-pair")!
        #expect(ocean.light.hex.accent == 0x1D5FA6)
        #expect(ocean.dark.hex.bg == 0x0F1B24)
        let matter = AppTheme.pair(id: "matter-pair")!
        #expect(matter.light.hex.accent == 0x805A39)
        #expect(matter.dark.hex.panel == 0x292725)
        let ky = AppTheme.pair(id: "ky-pair")!
        #expect(ky.dark.hex.bg == 0x10161E)
        #expect(ky.light.hex.accent == 0x08758B)
        let nord = AppTheme.pair(id: "nord-pair")!
        #expect(nord.light.hex.bg == 0xECEFF4)
        #expect(nord.dark.accentSoft == Color(hex: 0x4A5B6B))
    }

    /// Status colours: the shared ones by the half's own scheme, Forest's
    /// teal success, Nord's own, and the 12% tint over `panel`.
    @Test func statusColoursMatchKyUi() {
        let busnes = AppTheme.defaultPair
        #expect(busnes.light.hex.danger == 0xA8174E)
        #expect(busnes.light.hex.warning == 0x7A5F00)
        #expect(busnes.light.hex.success == 0x267442)
        #expect(busnes.dark.hex.danger == 0xFF8FB1)
        #expect(busnes.dark.hex.warning == 0xFFD25E)
        #expect(busnes.dark.hex.success == 0x86EFAC)
        let forest = AppTheme.pair(id: "forest-pair")!
        #expect(forest.light.hex.success == 0x00737A)
        #expect(forest.dark.hex.success == 0x6EE0D0)
        let nord = AppTheme.pair(id: "nord-pair")!
        #expect(nord.dark.hex.danger == 0xECC4C8)
        #expect(nord.dark.hex.success == 0xBCD4AA)
        #expect(nord.dark.hex.warning == 0xFFD25E)
        for pair in AppTheme.pairs {
            for half in [pair.light, pair.dark] {
                let hex = half.hex
                #expect(hex.dangerSoft == Contrast.mix(hex.danger, over: hex.panel, alpha: 0.12))
                #expect(hex.warningSoft == Contrast.mix(hex.warning, over: hex.panel, alpha: 0.12))
                #expect(hex.successSoft == Contrast.mix(hex.success, over: hex.panel, alpha: 0.12))
            }
        }
    }

    /// Each half runs its own system appearance, so default text is dark on
    /// a light half and light on a dark one.
    @Test func halvesHaveTheirOwnScheme() {
        for pair in AppTheme.pairs {
            #expect(pair.light.isLight, "\(pair.name) light")
            #expect(!pair.dark.isLight, "\(pair.name) dark")
            #expect(pair.half(for: .light) == pair.light)
            #expect(pair.half(for: .dark) == pair.dark)
            #expect(pair.dark.preferredColorScheme == .dark)
            // The light half's background really is the lighter one.
            #expect(Contrast.luminance(pair.light.hex.bg) > Contrast.luminance(pair.dark.hex.bg))
        }
    }

    /// Web buttonText: white on Busnes Light's orange, charcoal on Dark's.
    @Test func busnesAccentsGetTheWebsButtonTextContrast() {
        #expect(AppTheme.defaultPair.light.hex.readableOnAccent == 0xFFFFFF)
        #expect(AppTheme.defaultPair.dark.hex.readableOnAccent == 0x1A1A1E)
    }
}

// MARK: - WCAG AA and the status-colour gate

/// Every half, by name, for parameterised tests.
private let allHalves: [String] = AppTheme.pairs.flatMap { ["\($0.id)/light", "\($0.id)/dark"] }

private func half(_ name: String) -> ThemePalette {
    let parts = name.split(separator: "/")
    let pair = AppTheme.pair(id: String(parts[0]))!
    return parts[1] == "light" ? pair.light : pair.dark
}

/// Every text color the app puts on a theme background, in every half,
/// reads at least 4.5:1 (WCAG 2.x AA, normal text).
@Suite struct ThemeContrastTests {
    private struct Pair {
        let name: String
        let text: UInt32
        let background: UInt32
    }

    private func pairs(_ palette: ThemePalette) -> [Pair] {
        let hex = palette.hex
        var pairs = [Pair(name: "readableOnAccent/accent", text: hex.readableOnAccent, background: hex.accent)]
        for (surface, background) in [("bg", hex.bg), ("panel", hex.panel)] {
            pairs += [
                Pair(name: "ink/\(surface)", text: hex.ink, background: background),
                Pair(name: "inkStrong/\(surface)", text: hex.inkStrong, background: background),
                Pair(name: "secondaryInk/\(surface)", text: hex.secondaryInk, background: background),
                Pair(name: "link/\(surface)", text: hex.link, background: background),
            ]
        }
        pairs += [
            Pair(name: "inkStrong/dangerSoft", text: hex.inkStrong, background: hex.dangerSoft),
            Pair(name: "inkStrong/warningSoft", text: hex.inkStrong, background: hex.warningSoft),
        ]
        return pairs
    }

    @Test(arguments: allHalves)
    func everyTextPairReachesAA(_ name: String) {
        for pair in pairs(half(name)) {
            let ratio = Contrast.ratio(pair.text, pair.background)
            #expect(
                ratio >= Contrast.minimum,
                "\(name) \(pair.name): \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    /// ky-ui `check-status-colours.mjs`, check for check: each status on bg,
    /// on panel and on its own tint at 4.5:1; CIEDE2000 ΔE ≥ 20 between
    /// accent and danger and ≥ 10 between any two of accent, danger, warning
    /// and success.
    @Test(arguments: allHalves)
    func statusColoursPassTheKyUiGate(_ name: String) {
        let hex = half(name).hex
        let statuses: [(String, UInt32, UInt32)] = [
            ("danger", hex.danger, hex.dangerSoft),
            ("warning", hex.warning, hex.warningSoft),
            ("success", hex.success, hex.successSoft),
        ]
        for (status, color, soft) in statuses {
            for (surface, background) in [("bg", hex.bg), ("panel", hex.panel), ("\(status)-soft", soft)] {
                let ratio = Contrast.ratio(color, background)
                #expect(ratio >= 4.5, "\(name) \(status) on \(surface): \(String(format: "%.2f", ratio))")
            }
        }
        let accentDanger = ColorDifference.ciede2000(hex.accent, hex.danger)
        #expect(accentDanger >= 20, "\(name) ΔE accent–danger \(String(format: "%.2f", accentDanger))")
        let others: [(String, UInt32, String, UInt32)] = [
            ("accent", hex.accent, "warning", hex.warning),
            ("accent", hex.accent, "success", hex.success),
            ("danger", hex.danger, "warning", hex.warning),
            ("danger", hex.danger, "success", hex.success),
            ("warning", hex.warning, "success", hex.success),
        ]
        for (a, x, b, y) in others {
            let difference = ColorDifference.ciede2000(x, y)
            #expect(difference >= 10, "\(name) ΔE \(a)–\(b) \(String(format: "%.2f", difference))")
        }
    }

    /// Sharma, Wu and Dalal (2005) test data, so the ΔE formula is checked
    /// and not only its use.
    @Test func ciede2000MatchesThePublishedTestData() {
        let cases: [((Double, Double, Double), (Double, Double, Double), Double)] = [
            ((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425),
            ((50, 0, 0), (50, -1, 2), 2.3669),
            ((50, 2.5, 0), (73, 25, -18), 27.1492),
            ((60.2574, -34.0099, 36.2677), (60.4626, -34.1751, 39.4387), 1.2644),
            ((22.7233, 20.0904, -46.694), (23.0331, 14.973, -42.5619), 2.0373),
        ]
        for (a, b, expected) in cases {
            #expect(abs(ColorDifference.ciede2000(lab: a, lab: b) - expected) < 0.0001)
        }
        // And through sRGB: the gate's own example, the rust accent beside
        // the old red danger, is the clash the status colours removed.
        #expect(ColorDifference.ciede2000(0xBF3F18, 0xB71C1C) < 20)
        #expect(ColorDifference.ciede2000(0xBF3F18, 0xA8174E) >= 20)
    }

    /// The reference values from the WCAG definition, so the formula itself
    /// is checked and not only its use.
    @Test func ratioMatchesTheWcagDefinition() {
        #expect(Contrast.ratio(0x000000, 0xFFFFFF) == 21)
        #expect(Contrast.ratio(0x777777, 0x777777) == 1)
        #expect(abs(Contrast.ratio(0x767676, 0xFFFFFF) - 4.54) < 0.01)
    }

    /// Secondary text and links stay derived, and the derivation still
    /// matters: Busnes ink at 70% fails, and a link that reads keeps the accent.
    @Test func derivedTextColoursStillEarnTheirPlace() {
        let busnes = AppTheme.defaultPair.light.hex
        #expect(Contrast.ratio(Contrast.mix(busnes.ink, over: busnes.bg, alpha: 0.7), busnes.bg) < 4.5)
        #expect(busnes.link == 0xBF3F18)
    }
}

/// CIEDE2000 colour difference, a port of ky-ui `check-status-colours.mjs`
/// (sRGB → CIELAB D65, then Sharma, Wu and Dalal 2005, kL = kC = kH = 1).
private enum ColorDifference {
    static func ciede2000(_ a: UInt32, _ b: UInt32) -> Double {
        ciede2000(lab: lab(a), lab: lab(b))
    }

    static func lab(_ hex: UInt32) -> (Double, Double, Double) {
        func linear(_ shift: UInt32) -> Double {
            let v = Double((hex >> shift) & 0xFF) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (linear(16), linear(8), linear(0))
        let x: Double = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y: Double = 0.2126729 * r + 0.7151522 * g + 0.072175 * b
        let z: Double = (0.0193339 * r + 0.119192 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116
        }
        let xyz: [Double] = [f(x), f(y), f(z)]
        return (116 * xyz[1] - 16, 500 * (xyz[0] - xyz[1]), 200 * (xyz[1] - xyz[2]))
    }

    static func ciede2000(lab first: (Double, Double, Double), lab second: (Double, Double, Double)) -> Double {
        let (L1, a1, b1) = first
        let (L2, a2, b2) = second
        let rad = Double.pi / 180
        let C = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let C7: Double = pow(C, 7)
        let G: Double = 0.5 * (1 - sqrt(C7 / (C7 + pow(25, 7))))
        let (ap1, ap2) = (a1 * (1 + G), a2 * (1 + G))
        let (Cp1, Cp2) = (hypot(ap1, b1), hypot(ap2, b2))
        func hue(_ b: Double, _ a: Double) -> Double {
            (atan2(b, a) / rad + 360).truncatingRemainder(dividingBy: 360)
        }
        let (hp1, hp2) = (hue(b1, ap1), hue(b2, ap2))
        let dL = L2 - L1, dC = Cp2 - Cp1
        var dh: Double = Cp1 * Cp2 == 0 ? 0 : hp2 - hp1
        if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        let dH = 2 * sqrt(Cp1 * Cp2) * sin(dh * rad / 2)
        let Lm = (L1 + L2) / 2, Cm = (Cp1 + Cp2) / 2
        var hm: Double = hp1 + hp2
        if Cp1 * Cp2 != 0 {
            if abs(hp1 - hp2) > 180 { hm += hm < 360 ? 360 : -360 }
            hm /= 2
        }
        let t1: Double = 0.17 * cos((hm - 30) * rad)
        let t2: Double = 0.24 * cos(2 * hm * rad)
        let t3: Double = 0.32 * cos((3 * hm + 6) * rad)
        let t4: Double = 0.2 * cos((4 * hm - 63) * rad)
        let T: Double = 1 - t1 + t2 + t3 - t4
        let lOffset: Double = pow(Lm - 50, 2)
        let SL: Double = 1 + 0.015 * lOffset / sqrt(20 + lOffset)
        let SC: Double = 1 + 0.045 * Cm
        let SH: Double = 1 + 0.015 * Cm * T
        let c7: Double = pow(Cm, 7)
        let rotation: Double = 60 * exp(-pow((hm - 275) / 25, 2)) * rad
        let RT: Double = -2 * sqrt(c7 / (c7 + pow(25, 7))) * sin(rotation)
        let (l, c, h) = (dL / SL, dC / SC, dH / SH)
        return sqrt(l * l + c * c + h * h + RT * c * h)
    }
}

// MARK: - ThemeManager and the migration of saved names

@Suite struct ThemeManagerTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    @MainActor
    private func manager(legacy: String?, system: ColorScheme = .light) -> ThemeManager {
        let defaults = freshDefaults()
        if let legacy { defaults.set(legacy, forKey: ThemeManager.legacyKey) }
        return ThemeManager(defaults: defaults, systemScheme: system)
    }

    @Test @MainActor func aFreshInstallIsBusnesFollowingTheSystem() {
        let light = manager(legacy: nil, system: .light)
        #expect(light.pair.id == "busnes-pair")
        #expect(light.mode == .system)
        #expect(light.preferredColorScheme == nil)
        #expect(light.palette == AppTheme.defaultPair.light)
        #expect(manager(legacy: nil, system: .dark).palette == AppTheme.defaultPair.dark)
    }

    /// The owner's rule: an old Busnes Light or Dark keeps Busnes with that
    /// half forced, whatever the system does.
    @Test @MainActor func busnesLightAndDarkKeepTheirHalfForced() {
        let light = manager(legacy: "Busnes Light", system: .dark)
        #expect(light.pair.id == "busnes-pair")
        #expect(light.mode == .light)
        #expect(light.palette == AppTheme.defaultPair.light)
        #expect(light.preferredColorScheme == .light)
        let dark = manager(legacy: "Busnes Dark", system: .light)
        #expect(dark.pair.id == "busnes-pair")
        #expect(dark.mode == .dark)
        #expect(dark.palette == AppTheme.defaultPair.dark)
    }

    /// A half that survives into a pair keeps that pair and half (ky-ui's
    /// rule for a saved half ID).
    @Test(arguments: [
        ("Light Matter", "matter-pair", AppearanceMode.light),
        ("Dark Matter", "matter-pair", .dark),
        ("White Cliffs", "ocean-pair", .light),
        ("Ocean", "ocean-pair", .dark),
        ("Forest", "forest-pair", .dark),
        ("Polished Ky", "ky-pair", .light),
        ("Patina Ky", "ky-pair", .dark),
    ])
    @MainActor func survivingHalvesKeepTheirPair(_ legacy: String, _ pairID: String, _ mode: AppearanceMode) {
        let migrated = manager(legacy: legacy)
        #expect(migrated.pair.id == pairID)
        #expect(migrated.mode == mode)
    }

    /// Everything removed, and anything unknown, resets to Busnes following
    /// the system.
    @Test(arguments: [
        "Tropics", "Tropic Night", "Coffee", "Cyber Punk", "Neon Purple", "Space", "Sky", "Sun",
        "Retired Theme", "",
    ])
    @MainActor func removedPalettesResetToBusnesFollowingTheSystem(_ legacy: String) {
        let migrated = manager(legacy: legacy, system: .dark)
        #expect(migrated.pair.id == "busnes-pair")
        #expect(migrated.mode == .system)
        #expect(migrated.palette == AppTheme.defaultPair.dark)
    }

    /// Migration reads the old name and writes nothing; a choice writes the
    /// pair and mode, which win over the old name from then on.
    @Test @MainActor func persistsPairAndModeAndLeavesTheOldNameAlone() {
        let defaults = freshDefaults()
        defaults.set("Coffee", forKey: ThemeManager.legacyKey)
        let manager = ThemeManager(defaults: defaults, systemScheme: .light)
        #expect(defaults.string(forKey: ThemeManager.pairKey) == nil)

        manager.setPair(AppTheme.pair(id: "ocean-pair")!)
        manager.setMode(.dark)
        #expect(manager.palette == AppTheme.pair(id: "ocean-pair")!.dark)
        #expect(defaults.string(forKey: ThemeManager.pairKey) == "ocean-pair")
        #expect(defaults.string(forKey: ThemeManager.modeKey) == "dark")
        #expect(defaults.string(forKey: ThemeManager.legacyKey) == "Coffee")

        let restored = ThemeManager(defaults: defaults, systemScheme: .light)
        #expect(restored.pair.id == "ocean-pair")
        #expect(restored.mode == .dark)
    }

    @Test @MainActor func anUnknownSavedPairOrModeResets() {
        let defaults = freshDefaults()
        defaults.set("tropics-pair", forKey: ThemeManager.pairKey)
        defaults.set("dark", forKey: ThemeManager.modeKey)
        defaults.set("Ocean", forKey: ThemeManager.legacyKey)
        let unknownPair = ThemeManager(defaults: defaults)
        #expect(unknownPair.pair.id == "busnes-pair")
        #expect(unknownPair.mode == .system)

        defaults.set("ky-pair", forKey: ThemeManager.pairKey)
        defaults.set("sepia", forKey: ThemeManager.modeKey)
        let unknownMode = ThemeManager(defaults: defaults)
        #expect(unknownMode.pair.id == "ky-pair")
        #expect(unknownMode.mode == .system)
    }

    /// System follows the scene's appearance; a forced half ignores it, so
    /// the forced scheme is never taken for the system's.
    @Test @MainActor func systemModeFollowsTheAppearance() {
        let manager = ThemeManager(defaults: freshDefaults(), systemScheme: .light)
        manager.systemSchemeChanged(.dark)
        #expect(manager.palette == AppTheme.defaultPair.dark)
        manager.systemSchemeChanged(.light)
        #expect(manager.palette == AppTheme.defaultPair.light)

        manager.setMode(.dark)
        manager.systemSchemeChanged(.dark)
        #expect(manager.systemScheme == .light)
        #expect(manager.palette == AppTheme.defaultPair.dark)
    }
}

// MARK: - InboxViewModel filtering

@Suite struct InboxViewModelTests {
    @MainActor
    private func makeViewModel(
        client: HTTPClient,
        initialRefreshErrorDelay: Duration = .seconds(90),
        initialRefreshRetryDelay: Duration = .seconds(15)
    ) throws -> InboxViewModel {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let mailRepository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: client
        )
        return InboxViewModel(
            mailRepository: mailRepository,
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: defaults)
            ),
            initialRefreshErrorDelay: initialRefreshErrorDelay,
            initialRefreshRetryDelay: initialRefreshRetryDelay
        )
    }

    @Test @MainActor func loadBuildsTabsAndFiltersBySelection() async throws {
        let json = """
        {
          "byTab": {
            "Work": [{ "messageId": "1", "subject": "Work thing" }],
            "Important": [{ "messageId": "2", "subject": "Urgent thing" }],
            "": [{ "messageId": "3", "subject": "Untagged thing" }]
          }
        }
        """
        let client = HTTPClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
        let viewModel = try makeViewModel(client: client)

        await viewModel.load()
        #expect(viewModel.emails.count == 3)
        #expect(viewModel.tabs.map(\.name) == ["Important", "Work"])
        #expect(viewModel.errorMessage == nil)

        viewModel.selectedTab = "Work"
        #expect(viewModel.filteredEmails.map(\.serverId) == ["1"])
        viewModel.selectedTab = nil
        #expect(viewModel.filteredEmails.count == 3)
    }

    @Test @MainActor func markReadFlipsFlagsInPlaceAndPostsTheBulkAction() async throws {
        let listJson = """
        {
          "byTab": {
            "": [
              { "messageId": "1", "subject": "a" },
              { "messageId": "2", "subject": "b" }
            ]
          }
        }
        """
        let actionBody = Box("")
        let client = HTTPClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.url!.path.contains("inbox/actions") {
                actionBody.value = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
                return (Data(#"{"ok": true}"#.utf8), response)
            }
            return (Data(listJson.utf8), response)
        }
        let viewModel = try makeViewModel(client: client)
        await viewModel.load()
        #expect(viewModel.emails.allSatisfy { !$0.read })

        await viewModel.markRead(serverIds: ["1", "2"])

        // Rows stay in the list with the flag flipped — no removal.
        // (byTab merge order isn't stable, so compare as a set.)
        #expect(Set(viewModel.emails.map(\.serverId)) == ["1", "2"])
        #expect(viewModel.emails.allSatisfy { $0.read })
        #expect(actionBody.value.contains(#""action":"read""#))
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func notPairedProducesFriendlyError() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let keychain = KeychainStorage(service: "org.kysecurity.mail.tests.\(UUID().uuidString)")
        let db = try AppDatabase(inMemory: true)
        let viewModel = InboxViewModel(
            mailRepository: MailRepository(
                securePairingStore: SecurePairingStore(keychain: keychain),
                emailDAO: EmailDAO(modelContainer: db.container),
                httpClient: HTTPClient { _ in throw URLError(.badURL) }
            ),
            keywordRepository: KeywordRepository(
                settingsStore: KeywordSettingsStore(defaults: defaults)
            )
        )
        await viewModel.refresh()
        #expect(viewModel.errorMessage?.contains("Pair this device") == true)
    }

    @Test @MainActor func initialTransientRefreshErrorRetriesBeforeAppearing() async throws {
        let attempts = Box(0)
        let client = HTTPClient { request in
            attempts.value += 1
            if attempts.value == 1 { throw URLError(.timedOut) }
            return (
                Data(#"{"byTab":{}}"#.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
            )
        }
        let viewModel = try makeViewModel(
            client: client,
            initialRefreshErrorDelay: .milliseconds(60),
            initialRefreshRetryDelay: .milliseconds(15)
        )

        await viewModel.load()
        #expect(viewModel.errorMessage == nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(attempts.value == 2)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func persistentInitialErrorAppearsAfterTheGracePeriod() async throws {
        let attempts = Box(0)
        let viewModel = try makeViewModel(
            client: HTTPClient { _ in
                attempts.value += 1
                throw URLError(.timedOut)
            },
            initialRefreshErrorDelay: .milliseconds(60),
            initialRefreshRetryDelay: .milliseconds(15)
        )

        await viewModel.load()
        try await Task.sleep(for: .milliseconds(40))
        #expect(attempts.value == 2)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == "Unable to connect to the mail server.")
    }

    @Test @MainActor func leavingInboxCancelsItsPendingError() async throws {
        let attempts = Box(0)
        let viewModel = try makeViewModel(
            client: HTTPClient { _ in
                attempts.value += 1
                throw URLError(.timedOut)
            },
            initialRefreshErrorDelay: .milliseconds(60),
            initialRefreshRetryDelay: .milliseconds(15)
        )

        await viewModel.load()
        viewModel.leaveInbox()
        try await Task.sleep(for: .milliseconds(80))

        #expect(attempts.value == 1)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == nil)
    }

    @Test @MainActor func manualRefreshFailureUsesSanitizedConnectionNotice() async throws {
        let viewModel = try makeViewModel(
            client: HTTPClient { _ in throw URLError(.cannotConnectToHost) }
        )

        await viewModel.refresh()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.connectionNotice == "Unable to connect to the mail server.")
    }

    @Test @MainActor func returningToInboxDoesNotReloadIt() async throws {
        let attempts = Box(0)
        let client = HTTPClient { request in
            attempts.value += 1
            return (
                Data(#"{"byTab":{}}"#.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
            )
        }
        let viewModel = try makeViewModel(client: client)

        await viewModel.loadIfNeeded()
        viewModel.leaveInbox()
        await viewModel.loadIfNeeded()

        #expect(attempts.value == 1)
        #expect(viewModel.errorMessage == nil)
    }
}
