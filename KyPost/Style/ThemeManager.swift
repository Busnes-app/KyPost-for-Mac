//
//  ThemeManager.swift
//  KyPost
//
//  Holds the active pair and appearance mode and persists them in
//  UserDefaults (spec §1: the theme is non-sensitive). Injected into the
//  SwiftUI environment so every view re-renders on theme change.
//

import SwiftUI
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Observable
@MainActor
final class ThemeManager {
    static let pairKey = "theme.pair"
    static let modeKey = "theme.mode"
    /// The single palette name saved before the pairs. Read once, when no
    /// pair is saved, and never written or removed.
    static let legacyKey = "theme.selectedName"

    private let defaults: UserDefaults

    private(set) var pair: ThemePair
    private(set) var mode: AppearanceMode
    /// The device's appearance, followed while `mode` is `.system`.
    private(set) var systemScheme: ColorScheme

    /// The half on screen.
    var palette: ThemePalette { pair.half(for: mode.scheme ?? systemScheme) }

    /// For `.preferredColorScheme`: nil follows the system.
    var preferredColorScheme: ColorScheme? { mode.scheme }

    init(defaults: UserDefaults = .standard, systemScheme: ColorScheme? = nil) {
        self.defaults = defaults
        self.systemScheme = systemScheme ?? Self.currentSystemScheme
        let saved = Self.restore(from: defaults)
        pair = saved.pair
        mode = saved.mode
    }

    /// A saved pair and mode; else the migrated legacy name; else Busnes,
    /// following the system. An unknown pair or mode resets to the default.
    static func restore(from defaults: UserDefaults) -> (pair: ThemePair, mode: AppearanceMode) {
        if let id = defaults.string(forKey: pairKey) {
            guard let pair = AppTheme.pair(id: id) else { return (AppTheme.defaultPair, .system) }
            let mode = defaults.string(forKey: modeKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
            return (pair, mode)
        }
        if let legacy = defaults.string(forKey: legacyKey) {
            return AppTheme.migrate(legacyName: legacy)
        }
        return (AppTheme.defaultPair, .system)
    }

    func setPair(_ pair: ThemePair) {
        guard AppTheme.pair(id: pair.id) != nil else { return }
        self.pair = pair
        persist()
    }

    func setMode(_ mode: AppearanceMode) {
        self.mode = mode
        applyAppearance()
        // A forced mode hides the system's changes; read it afresh.
        if mode == .system { systemScheme = Self.currentSystemScheme }
        persist()
    }

    /// A scene root's color scheme. Only the system's while nothing is
    /// forced, so a forced half is never recorded as the system's.
    func systemSchemeChanged(_ scheme: ColorScheme) {
        guard mode == .system, scheme != systemScheme else { return }
        systemScheme = scheme
    }

    /// macOS forces the appearance on the application, where returning to
    /// the system works; `.preferredColorScheme(nil)` leaves a macOS window
    /// in the scheme it last forced. iOS uses `.preferredColorScheme`.
    func applyAppearance() {
#if os(macOS)
        guard let app = NSApp else { return }
        app.appearance = mode.scheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
#endif
    }

    private func persist() {
        defaults.set(pair.id, forKey: Self.pairKey)
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    static var currentSystemScheme: ColorScheme {
#if os(macOS)
        let appearance = NSApp?.effectiveAppearance
            ?? NSAppearance(named: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .darkAqua : .aqua)
        return appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
#else
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
#endif
    }
}

extension EnvironmentValues {
    /// The active palette; Busnes Light until the app injects one.
    @Entry var theme: ThemePalette = AppTheme.defaultPair.light
}

extension View {
    /// A scene root's theme: the palette in the environment, the forced
    /// appearance if any, and the system's appearance reported back while
    /// the pair follows it. Every scene root uses this.
    func themed(_ manager: ThemeManager) -> some View {
        modifier(ThemedScene(manager: manager))
    }
}

private struct ThemedScene: ViewModifier {
    let manager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.theme, manager.palette)
#if os(iOS)
            .preferredColorScheme(manager.preferredColorScheme)
#endif
            .onAppear { manager.applyAppearance() }
            .onChange(of: colorScheme, initial: true) { _, scheme in
                manager.systemSchemeChanged(scheme)
            }
    }
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
