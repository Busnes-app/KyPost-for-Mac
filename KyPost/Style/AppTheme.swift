//
//  AppTheme.swift
//  KyPost
//
//  The suite's six light/dark theme pairs (ky-ui 0.11.0 `THEME_PAIRS`,
//  `src/themes.js` and `src/tokens.css`). Binding contract: every hex matches
//  ky-ui — if a value changes there, port it the same day. Native palettes
//  use bg/panel/ink/inkStrong/accent/line + accentSoft (the avatar gradient,
//  STYLE_GUIDE §3) and the three status colours.
//
//  Every palette colour on the native clients is opaque. Where ky-ui's value
//  is translucent (the Busnes `line`, Nord's `accentSoft`) the value here is
//  that colour composited onto `panel`.
//
//  Status colours (ky-ui 0.8.0) are per half and never the accent: danger is
//  a cool crimson, Forest's success is teal, Nord keeps its own. Each has a
//  `*Soft` tint, the status at 12% over `panel`. `ThemeContrastTests` ports
//  ky-ui's `scripts/check-status-colours.mjs` gate.
//

import SwiftUI

struct ThemePalette: Equatable, Sendable {
    let bg: Color
    let panel: Color
    let ink: Color
    let inkStrong: Color
    let accent: Color
    let accentSoft: Color
    let line: Color
    /// Secondary text (dates, sizes, captions, hints). Use this, never
    /// `ink.opacity(…)`: an opacity drops below WCAG AA on several themes.
    let secondaryInk: Color
    /// Link colour in the HTML reader (`EmailDetailView.themedHTML`).
    let link: Color
    /// Readable text color on top of the accent fill (web: buttonText).
    let readableOnAccent: Color
    /// Status text and icons. Never the accent; always beside a word.
    let danger: Color
    let warning: Color
    let success: Color
    /// Status pill and banner fills: the status at 12% over `panel`.
    let dangerSoft: Color
    let warningSoft: Color
    let successSoft: Color
    /// Whether this is the light half of its pair. Light halves run the light
    /// system appearance (and dark halves the dark one) so default text,
    /// form and toolbar colors stay readable on the theme's backgrounds.
    let isLight: Bool
    /// The same colors as sRGB hex, for contrast checks.
    let hex: Hex

    struct Hex: Equatable, Sendable {
        let bg, panel, ink, inkStrong, accent, secondaryInk, link, readableOnAccent: UInt32
        let danger, warning, success, dangerSoft, warningSoft, successSoft: UInt32
    }

    var preferredColorScheme: ColorScheme {
        isLight ? .light : .dark
    }

    /// `danger` and `success` default to the shared status colours for the
    /// half's own scheme (ky-ui `--ky-*-light` / `--ky-*-dark`); warning has
    /// no override in the suite.
    init(
        bg: UInt32, panel: UInt32, ink: UInt32, inkStrong: UInt32,
        accent: UInt32, accentSoft: UInt32, line: UInt32,
        isLight: Bool, danger: UInt32? = nil, success: UInt32? = nil
    ) {
        self.bg = Color(hex: bg)
        self.panel = Color(hex: panel)
        self.ink = Color(hex: ink)
        self.inkStrong = Color(hex: inkStrong)
        self.accent = Color(hex: accent)
        self.accentSoft = Color(hex: accentSoft)
        self.line = Color(hex: line)
        self.isLight = isLight
        let secondary = Contrast.secondaryInk(ink: ink, bg: bg, panel: panel)
        let link = Contrast.link(accent: accent, inkStrong: inkStrong, bg: bg, panel: panel)
        let onAccent = Contrast.readableOn(accent)
        self.secondaryInk = Color(hex: secondary)
        self.link = Color(hex: link)
        self.readableOnAccent = Color(hex: onAccent)
        let status = isLight ? StatusColors.light : StatusColors.dark
        let danger = danger ?? status.danger
        let success = success ?? status.success
        let warning = status.warning
        let soft = { (color: UInt32) in Contrast.mix(color, over: panel, alpha: StatusColors.softAlpha) }
        self.danger = Color(hex: danger)
        self.warning = Color(hex: warning)
        self.success = Color(hex: success)
        dangerSoft = Color(hex: soft(danger))
        warningSoft = Color(hex: soft(warning))
        successSoft = Color(hex: soft(success))
        hex = Hex(
            bg: bg, panel: panel, ink: ink, inkStrong: inkStrong, accent: accent,
            secondaryInk: secondary, link: link, readableOnAccent: onAccent,
            danger: danger, warning: warning, success: success,
            dangerSoft: soft(danger), warningSoft: soft(warning), successSoft: soft(success)
        )
    }
}

/// The shared status colours (ky-ui `tokens.css`, `--ky-{danger,success,
/// warning}-{light,dark}`), used by every half that does not set its own.
nonisolated enum StatusColors {
    struct Triple: Equatable, Sendable {
        let danger, warning, success: UInt32
    }

    static let light = Triple(danger: 0xA8174E, warning: 0x7A5F00, success: 0x267442)
    static let dark = Triple(danger: 0xFF8FB1, warning: 0xFFD25E, success: 0x86EFAC)
    /// `--ky-*-soft`: `color-mix(in srgb, status 12%, panel)`.
    static let softAlpha = 0.12
}

/// WCAG 2.x contrast, and the derived colors that use it. Every text color
/// the app puts on a theme background reads at least `minimum` (AA, normal
/// text) — `ThemeContrastTests` checks every theme.
nonisolated enum Contrast {
    static let minimum = 4.5

    /// WCAG relative luminance of an sRGB hex color.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `foreground` laid over `background` at `alpha`, as an opaque color.
    static func mix(_ foreground: UInt32, over background: UInt32, alpha: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let f = Double((foreground >> shift) & 0xFF)
            let b = Double((background >> shift) & 0xFF)
            return UInt32((alpha * f + (1 - alpha) * b).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func readsOn(_ text: UInt32, _ backgrounds: UInt32...) -> Bool {
        backgrounds.allSatisfy { ratio(text, $0) >= minimum }
    }

    /// `ink` faded toward `bg` as the old `ink.opacity(0.7)` did, but only as
    /// far as AA allows on both `bg` and `panel`; at worst `ink` itself.
    static func secondaryInk(ink: UInt32, bg: UInt32, panel: UInt32) -> UInt32 {
        for step in 0...6 {
            let candidate = mix(ink, over: bg, alpha: 0.7 + Double(step) * 0.05)
            if readsOn(candidate, bg, panel) { return candidate }
        }
        return ink
    }

    /// The accent where it reads on `bg` and `panel`, else the accent moved
    /// toward `inkStrong` until it does — keeping some of the accent's hue
    /// on the light themes whose accent is a pale fill color.
    static func link(accent: UInt32, inkStrong: UInt32, bg: UInt32, panel: UInt32) -> UInt32 {
        for step in 0...20 {
            let candidate = mix(inkStrong, over: accent, alpha: Double(step) * 0.05)
            if readsOn(candidate, bg, panel) { return candidate }
        }
        return inkStrong
    }

    /// The web's buttonText choice (charcoal on a light accent, white on a
    /// dark one), switched to the other when that one does not reach AA.
    static func readableOn(_ accent: UInt32) -> UInt32 {
        let charcoal: UInt32 = 0x1A1A1E, white: UInt32 = 0xFFFFFF
        // The same weighting as `Color.isPerceptuallyLight`.
        let r = Double((accent >> 16) & 0xFF), g = Double((accent >> 8) & 0xFF), b = Double(accent & 0xFF)
        let preferred = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.55 ? charcoal : white
        let other = preferred == white ? charcoal : white
        return ratio(preferred, accent) >= minimum ? preferred : other
    }
}

/// One light/dark pair. A pair follows the system appearance unless the
/// user forces a half (`AppearanceMode`).
struct ThemePair: Identifiable, Equatable, Sendable {
    /// ky-ui's pair ID (`busnes-pair`); saved, so never rename one.
    let id: String
    let name: String
    let light: ThemePalette
    let dark: ThemePalette

    func half(for scheme: ColorScheme) -> ThemePalette {
        scheme == .dark ? dark : light
    }
}

/// System (the default) follows the device; Light and Dark force a half.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The forced scheme, or nil to follow the system.
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppTheme {
    /// The six pairs in display order — ky-ui `THEME_PAIRS`. Values are
    /// ky-ui's `THEME_PALETTES` and the Busnes block of `tokens.css`.
    static let pairs: [ThemePair] = [
        ThemePair(
            id: "busnes-pair", name: "Busnes",
            light: ThemePalette(
                bg: 0xF8F6F0, panel: 0xFFFFFF, ink: 0x566461, inkStrong: 0x182326,
                accent: 0xBF3F18, accentSoft: 0xFBF0EC, line: 0xCCCFCF, isLight: true
            ),
            dark: ThemePalette(
                bg: 0x182326, panel: 0x1F2B2E, ink: 0xB3BCB8, inkStrong: 0xF2EFE8,
                accent: 0xF5865F, accentSoft: 0x2B2622, line: 0x525A5B, isLight: false
            )
        ),
        ThemePair(
            id: "matter-pair", name: "Matter",
            light: ThemePalette(
                bg: 0xF5EFE5, panel: 0xFFF8EE, ink: 0x4C3D32, inkStrong: 0x2D1F15,
                accent: 0x805A39, accentSoft: 0xE2D0B8, line: 0xD4C7B5, isLight: true
            ),
            dark: ThemePalette(
                bg: 0x1D1B19, panel: 0x292725, ink: 0xCFC6BB, inkStrong: 0xF0E9DF,
                accent: 0xC29A72, accentSoft: 0x49392C, line: 0x45403A, isLight: false
            )
        ),
        ThemePair(
            id: "ocean-pair", name: "Ocean",
            light: ThemePalette(
                bg: 0xF7F9FB, panel: 0xFFFFFF, ink: 0x2E4C63, inkStrong: 0x163246,
                accent: 0x1D5FA6, accentSoft: 0xDDE9F7, line: 0xC7D6DF, isLight: true
            ),
            dark: ThemePalette(
                bg: 0x0F1B24, panel: 0x152A36, ink: 0xB8D8E8, inkStrong: 0xE0F2FB,
                accent: 0x6AA8E8, accentSoft: 0x1F3A55, line: 0x2F5567, isLight: false
            )
        ),
        // Forest's success is teal: the shared green sits too close to its
        // green accent.
        ThemePair(
            id: "forest-pair", name: "Forest",
            light: ThemePalette(
                bg: 0xF3F6EF, panel: 0xFCFDF9, ink: 0x435342, inkStrong: 0x203322,
                accent: 0x4B6B37, accentSoft: 0xE2EBDA, line: 0xC5D0BC, isLight: true,
                success: 0x00737A
            ),
            dark: ThemePalette(
                bg: 0x142018, panel: 0x1F2F24, ink: 0xC7DBC7, inkStrong: 0xE3F0DF,
                accent: 0x8FAA74, accentSoft: 0x3A5837, line: 0x4F694F, isLight: false,
                success: 0x6EE0D0
            )
        ),
        ThemePair(
            id: "ky-pair", name: "Ky",
            light: ThemePalette(
                bg: 0xEEF2F6, panel: 0xFFFFFF, ink: 0x475569, inkStrong: 0x0F172A,
                accent: 0x08758B, accentSoft: 0xDAF2F4, line: 0xC2CDD8, isLight: true
            ),
            dark: ThemePalette(
                bg: 0x10161E, panel: 0x1B2530, ink: 0xAFBDCA, inkStrong: 0xE2E8F0,
                accent: 0x6FC9CC, accentSoft: 0x203D41, line: 0x34414D, isLight: false
            )
        ),
        // Nord keeps its own status colours. Its accentSoft is ky-ui's
        // rgba(136, 192, 208, 0.2) over its panel.
        ThemePair(
            id: "nord-pair", name: "Nord",
            light: ThemePalette(
                bg: 0xECEFF4, panel: 0xFFFFFF, ink: 0x4C566A, inkStrong: 0x2E3440,
                accent: 0x4A6A94, accentSoft: 0xDBE4EF, line: 0xC5CDD9, isLight: true
            ),
            dark: ThemePalette(
                bg: 0x2E3440, panel: 0x3B4252, ink: 0xD8DEE9, inkStrong: 0xECEFF4,
                accent: 0x88C0D0, accentSoft: 0x4A5B6B, line: 0x4C566A, isLight: false,
                danger: 0xECC4C8, success: 0xBCD4AA
            )
        ),
    ]

    /// The one place the fallback lives: a fresh install, a saved pair this
    /// build does not offer, and a removed palette all resolve to Busnes,
    /// following the system.
    static let defaultPair = pairs[0]

    static func pair(id: String) -> ThemePair? {
        pairs.first { $0.id == id }
    }

    /// What a name saved under `theme.selectedName` (the 17 single palettes
    /// before the pairs) becomes. A half that survives keeps its pair with
    /// that half forced: the user fixed the mode by choosing it. Everything
    /// removed resets to Busnes, following the system (ky-ui's rule).
    static func migrate(legacyName: String) -> (pair: ThemePair, mode: AppearanceMode) {
        let halves: [String: (String, AppearanceMode)] = [
            "Busnes Light": ("busnes-pair", .light),
            "Busnes Dark": ("busnes-pair", .dark),
            "Light Matter": ("matter-pair", .light),
            "Dark Matter": ("matter-pair", .dark),
            "White Cliffs": ("ocean-pair", .light),
            "Ocean": ("ocean-pair", .dark),
            "Forest": ("forest-pair", .dark),
            "Polished Ky": ("ky-pair", .light),
            "Patina Ky": ("ky-pair", .dark),
        ]
        guard let (id, mode) = halves[legacyName], let pair = pair(id: id) else {
            return (defaultPair, .system)
        }
        return (pair, mode)
    }
}

/// Shape tokens (spec §6 / STYLE_GUIDE §3). Stadium shapes use Capsule.
enum Shape {
    static let field: CGFloat = 14
    static let button: CGFloat = 10
    static let panel: CGFloat = 14
    static let sheet: CGFloat = 14
    static let emptyState: CGFloat = 10
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
