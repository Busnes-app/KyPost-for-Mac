//
//  ThemeManager.swift
//  KyPost
//
//  Holds the active theme and persists the selection in UserDefaults
//  (spec §1: theme name is non-sensitive). Injected into the SwiftUI
//  environment so every view re-renders on theme change.
//

import SwiftUI
import Observation

@Observable
@MainActor
final class ThemeManager {
    private static let storageKey = "theme.selectedName"

    private let defaults: UserDefaults

    private(set) var themeName: String
    private(set) var palette: ThemePalette

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.storageKey) ?? AppTheme.defaultThemeName
        let name = AppTheme.palettes[saved] != nil ? saved : AppTheme.defaultThemeName
        themeName = name
        palette = AppTheme.palette(named: name)
    }

    func setTheme(named name: String) {
        guard AppTheme.palettes[name] != nil else { return }
        themeName = name
        palette = AppTheme.palette(named: name)
        defaults.set(name, forKey: Self.storageKey)
    }
}

extension EnvironmentValues {
    /// The active palette; the default theme until the app injects one.
    @Entry var theme: ThemePalette = AppTheme.palette(named: AppTheme.defaultThemeName)
}

// MARK: - Typography (STYLE_GUIDE §2)

/// Space Grotesk and IBM Plex Mono ship in the bundle (Resources/Fonts,
/// registered via UIAppFonts / ATSApplicationFontsPath), so the family name
/// always resolves. Only the four weights the app asks for are bundled —
/// regular, medium, semibold, bold — and CoreText matches `.weight()` to the
/// matching static face. A weight outside that set resolves to the nearest
/// bundled one rather than a synthesized face, so add the TTF before using it.
enum AppFont {
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Space Grotesk", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("IBM Plex Mono", size: size).weight(weight)
    }
}
