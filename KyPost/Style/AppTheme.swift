//
//  AppTheme.swift
//  KyPost
//
//  Theme palettes (spec §6, STYLE_GUIDE.md §1). Binding contract: the 17
//  theme names and hex values are numerically identical to web theme.ts and
//  Android AppTheme.kt — if a hex changes on one side, port it the same day.
//  Mobile uses bg/panel/ink/inkStrong/accent/line + accentSoft (the one extra
//  field, needed for the avatar gradient per STYLE_GUIDE §3).
//
//  Exception: colors that failed WCAG AA (4.5:1) were changed here, on
//  purpose, for web and Android to follow — the list is in
//  Presentation/AGENTS.md, and ThemeContrastTests holds every text pair.
//
//  The two Busnes palettes come from the web's ky-ui palettes.ts. Their web
//  `line` is translucent; `line` here is Android's opaque composite onto
//  `panel`, because every palette color on both native clients is opaque.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    /// The same colors as sRGB hex, for contrast checks.
    let hex: Hex

    struct Hex: Equatable, Sendable {
        let bg, panel, ink, inkStrong, accent, secondaryInk, link, readableOnAccent: UInt32
    }

    /// Light themes must run the light system appearance (and vice versa) so
    /// default text, form, and toolbar colors stay readable on the theme's
    /// backgrounds.
    var isLight: Bool {
        bg.isPerceptuallyLight
    }

    var preferredColorScheme: ColorScheme {
        isLight ? .light : .dark
    }

    init(
        bg: UInt32, panel: UInt32, ink: UInt32, inkStrong: UInt32,
        accent: UInt32, accentSoft: UInt32, line: UInt32
    ) {
        self.bg = Color(hex: bg)
        self.panel = Color(hex: panel)
        self.ink = Color(hex: ink)
        self.inkStrong = Color(hex: inkStrong)
        self.accent = Color(hex: accent)
        self.accentSoft = Color(hex: accentSoft)
        self.line = Color(hex: line)
        let secondary = Contrast.secondaryInk(ink: ink, bg: bg, panel: panel)
        let link = Contrast.link(accent: accent, inkStrong: inkStrong, bg: bg, panel: panel)
        let onAccent = Contrast.readableOn(accent)
        self.secondaryInk = Color(hex: secondary)
        self.link = Color(hex: link)
        self.readableOnAccent = Color(hex: onAccent)
        hex = Hex(
            bg: bg, panel: panel, ink: ink, inkStrong: inkStrong, accent: accent,
            secondaryInk: secondary, link: link, readableOnAccent: onAccent
        )
    }
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

enum AppTheme {
    /// Theme names in display order — exact list from web THEME_OPTIONS.
    static let themeNames: [String] = [
        "Busnes Light", "Busnes Dark",
        "Dark Matter", "Light Matter", "Tropics", "Tropic Night", "Ocean",
        "Coffee", "White Cliffs", "Cyber Punk", "Neon Purple", "Space",
        "Sky", "Forest", "Sun", "Patina Ky", "Polished Ky",
    ]

    /// The one place the fallback lives: a fresh install, a saved name this
    /// build no longer offers, and a missing palette all resolve here.
    /// Matches Android's `DEFAULT_THEME`. (The web instead picks Busnes Light
    /// or Busnes Dark from the system appearance.) An explicit saved choice is
    /// always kept — `ThemeManager` only discards names it does not know.
    static let defaultThemeName = "Busnes Light"

    /// Values transcribed from frontend theme.ts — do not edit independently.
    static let palettes: [String: ThemePalette] = [
        "Busnes Light": ThemePalette(
            bg: 0xF8F6F0, panel: 0xFFFFFF, ink: 0x566461, inkStrong: 0x182326,
            accent: 0xBF3F18, accentSoft: 0xFBF0EC, line: 0xCCCFCF
        ),
        "Busnes Dark": ThemePalette(
            bg: 0x182326, panel: 0x1F2B2E, ink: 0xB3BCB8, inkStrong: 0xF2EFE8,
            accent: 0xF5865F, accentSoft: 0x2B2622, line: 0x525A5B
        ),
        "Dark Matter": ThemePalette(
            bg: 0x1A1A1E, panel: 0x252530, ink: 0xD4C5E2, inkStrong: 0xE8DDF5,
            accent: 0xC29A72, accentSoft: 0x5A3F31, line: 0x404050
        ),
        "Light Matter": ThemePalette(
            bg: 0xF5EFE5, panel: 0xFFF8EE, ink: 0x4C3D32, inkStrong: 0x2D1F15,
            accent: 0xC29A72, accentSoft: 0xE6D2BE, line: 0xC5B29D
        ),
        "Tropics": ThemePalette(
            bg: 0xF4F1EB, panel: 0xFFFAF0, ink: 0x43362D, inkStrong: 0x241A14,
            accent: 0x9BC400, accentSoft: 0xD4E3A0, line: 0xC4B7A3
        ),
        "Tropic Night": ThemePalette(
            bg: 0x15131A, panel: 0x221F2B, ink: 0xCDBDE0, inkStrong: 0xE8DDF5,
            accent: 0x9BC400, accentSoft: 0x6B4A42, line: 0x3C3650
        ),
        "Ocean": ThemePalette(
            bg: 0x0F1B24, panel: 0x152A36, ink: 0xB8D8E8, inkStrong: 0xE0F2FB,
            accent: 0x5EA9BE, accentSoft: 0x214657, line: 0x2F5567
        ),
        "Coffee": ThemePalette(
            bg: 0x1D1714, panel: 0x2A211D, ink: 0xD6C0B3, inkStrong: 0xF0DED2,
            accent: 0xB47F5C, accentSoft: 0x5F3F2F, line: 0x4A3830
        ),
        "White Cliffs": ThemePalette(
            bg: 0xF7F9FB, panel: 0xFFFFFF, ink: 0x2E4C63, inkStrong: 0x163246,
            accent: 0x5EA8D8, accentSoft: 0xDFF1FB, line: 0x8FC3DF
        ),
        "Cyber Punk": ThemePalette(
            bg: 0x120918, panel: 0x1E1028, ink: 0xF5D0FF, inkStrong: 0xFFE9FF,
            accent: 0x00F5D4, accentSoft: 0x3B1760, line: 0x5C2D84
        ),
        "Neon Purple": ThemePalette(
            bg: 0x130B1D, panel: 0x231233, ink: 0xE4CCFF, inkStrong: 0xF2E6FF,
            accent: 0xC86CFF, accentSoft: 0x47206C, line: 0x63358A
        ),
        "Space": ThemePalette(
            bg: 0x0B0F1A, panel: 0x151C2D, ink: 0xC8D5F0, inkStrong: 0xE7EFFF,
            accent: 0x86A8FF, accentSoft: 0x263E74, line: 0x34496F
        ),
        "Sky": ThemePalette(
            bg: 0xDFF1FF, panel: 0xF4FBFF, ink: 0x2F4F64, inkStrong: 0x183142,
            accent: 0x6DB3D6, accentSoft: 0xB6DCED, line: 0x93BDD2
        ),
        "Forest": ThemePalette(
            bg: 0x142018, panel: 0x1F2F24, ink: 0xC7DBC7, inkStrong: 0xE3F0DF,
            accent: 0x8FAA74, accentSoft: 0x3A5837, line: 0x4F694F
        ),
        "Sun": ThemePalette(
            bg: 0xFFF3DC, panel: 0xFFF9EC, ink: 0x5A4024, inkStrong: 0x392611,
            accent: 0xE0AB4F, accentSoft: 0xF1D9A2, line: 0xD4B27A
        ),
        // ink deviates from web/Android 0x64748B (4.0:1 on bg, 3.7:1 on
        // panel) to reach WCAG AA; see Presentation/AGENTS.md.
        "Patina Ky": ThemePalette(
            bg: 0x0D0F14, panel: 0x161A22, ink: 0x7C8BA1, inkStrong: 0xE2E8F0,
            accent: 0x4DEEEA, accentSoft: 0x0E4A48, line: 0x1E293B
        ),
        "Polished Ky": ThemePalette(
            bg: 0xEEF2F6, panel: 0xFFFFFF, ink: 0x475569, inkStrong: 0x0F172A,
            accent: 0x0891B2, accentSoft: 0xCFFAFE, line: 0xCBD5E1
        ),
    ]

    static func palette(named name: String) -> ThemePalette {
        palettes[name] ?? palettes[defaultThemeName]!
    }
}

/// Semantic colors (STYLE_GUIDE §1: fixed literals, not part of the
/// per-theme palette).
///
/// The text colors have a light and a dark variant: the web's single
/// literals (#FF5F5F, #A5DCA5, #FFD64D) are built for dark backgrounds and
/// read at 1.3–2.7:1 on the light themes. Each resolves by appearance, and
/// every scene sets `preferredColorScheme` from the theme's `isLight`, so
/// the variant follows the theme. Recorded as a deviation from web/Android
/// in Presentation/AGENTS.md; `ThemeContrastTests` checks both variants.
enum SemanticColors {
    static let dangerLight: UInt32 = 0xB71C1C
    static let dangerDark: UInt32 = 0xFF8A8A
    static let successLight: UInt32 = 0x1B5E20
    static let successDark: UInt32 = 0xA5DCA5
    static let warningLight: UInt32 = 0x8A5A00
    static let warningDark: UInt32 = 0xFFD64D
    /// The fill under danger text, as an opaque blend over its background.
    static let dangerFillBase: UInt32 = 0xFF5F5F
    static let dangerFillOpacity = 0.12

    static let danger = Color(light: dangerLight, dark: dangerDark)
    static let dangerBorder = Color(hex: 0xFFB4AB).opacity(0.4)
    static let dangerFill = Color(hex: dangerFillBase).opacity(dangerFillOpacity)
    static let warning = Color(light: warningLight, dark: warningDark)
    static let successBorder = Color(hex: 0x7BBF7B)
    static let successText = Color(light: successLight, dark: successDark)
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

    /// One color per appearance (light / dark), resolved by the view's
    /// color scheme.
    init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        let (lr, lg, lb) = components(light)
        let (dr, dg, db) = components(dark)
#if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: 1)
                : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: 1)
        })
#else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dr, green: dg, blue: db, alpha: 1)
                : UIColor(red: lr, green: lg, blue: lb, alpha: 1)
        })
#endif
    }

    /// Relative luminance check used by readableOnAccent.
    var isPerceptuallyLight: Bool {
        guard let components = resolvedRGB else { return false }
        let luminance = 0.299 * components.r + 0.587 * components.g + 0.114 * components.b
        return luminance > 0.55
    }

    private var resolvedRGB: (r: Double, g: Double, b: Double)? {
        let resolved = resolve(in: EnvironmentValues())
        return (Double(resolved.red), Double(resolved.green), Double(resolved.blue))
    }
}
