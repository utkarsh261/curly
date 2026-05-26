import AppKit
import SwiftUI

// MARK: - Semantic Colors (Light & Dark)
// Edit values here to update the app theme globally.

let themeAccentNS = NSColor(name: "accent") { _ in
    NSColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1) // #7C3AED
}

let surfaceGroupedNS = NSColor(name: "surfaceGrouped") { appearance in
    let isDark = appearance.name == .darkAqua || appearance.name == .vibrantDark
    return isDark
        ? NSColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1) // #1C1C1E
        : NSColor(red: 0.949, green: 0.949, blue: 0.953, alpha: 1) // #F2F2F4
}

let surfaceInsetNS = NSColor(name: "surfaceInset") { appearance in
    let isDark = appearance.name == .darkAqua || appearance.name == .vibrantDark
    return isDark
        ? NSColor(red: 0.086, green: 0.086, blue: 0.094, alpha: 1) // #161618
        : NSColor(red: 0.973, green: 0.973, blue: 0.976, alpha: 1) // #F8F8F9
}

private enum SurfaceRaisedValues {
    static let light = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)       // #FFFFFF
    static let dark = NSColor(red: 0.165, green: 0.165, blue: 0.173, alpha: 1)  // #2A2A2C
}

let surfaceRaisedNS = NSColor(name: "surfaceRaised") { appearance in
    let isDark = appearance.name == .darkAqua || appearance.name == .vibrantDark
    return isDark ? SurfaceRaisedValues.dark : SurfaceRaisedValues.light
}

func resolvedSurfaceRaised(for colorScheme: ColorScheme) -> NSColor {
    colorScheme == .dark ? SurfaceRaisedValues.dark : SurfaceRaisedValues.light
}

let borderSubtleNS = NSColor(name: "borderSubtle") { appearance in
    let isDark = appearance.name == .darkAqua || appearance.name == .vibrantDark
    return isDark
        ? NSColor(red: 0.235, green: 0.235, blue: 0.247, alpha: 1) // #3C3C3F
        : NSColor(red: 0.867, green: 0.867, blue: 0.875, alpha: 1) // #DDDDDF
}

let textMutedNS = NSColor(name: "textMuted") { _ in
    NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1) // #8E8E93
}

extension Color {
    static let accent = Color(nsColor: themeAccentNS)
    static let surfaceGrouped = Color(nsColor: surfaceGroupedNS)
    static let surfaceInset = Color(nsColor: surfaceInsetNS)
    static let surfaceRaised = Color(nsColor: surfaceRaisedNS)
    static let borderSubtle = Color(nsColor: borderSubtleNS)
    static let textMuted = Color(nsColor: textMutedNS)

    static var accentSoft: Color {
        accent.opacity(0.12)
    }
}
