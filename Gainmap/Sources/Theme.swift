//
//  Theme.swift
//  Gainmap
//
//  The Legacy Lab visual system, ported from the canonical Second Light /
//  Beam brand. Colors and the three-font stack (Zilla Slab display, Inter UI,
//  JetBrains Mono readouts) match the rest of the product family. Fonts are
//  bundled (see Resources/Fonts + Info.plist ATSApplicationFontsPath); if a
//  family is unavailable the helpers fall back to the closest system face so
//  the app always renders.
//

import SwiftUI

enum Theme {

    // MARK: Palette  (hex from secondlight-mockups.html)
    static let bg        = Color(hex: 0x1A1818)
    static let bgDeep    = Color(hex: 0x141212)
    static let surface   = Color(hex: 0x2C2A2B)
    static let surfaceHi = Color(hex: 0x363334)
    static let inset     = Color(hex: 0x111010)
    static let accent    = Color(hex: 0xE05A3F)   // signature aperture red
    static let accentHot = Color(hex: 0xF47A5E)
    static let gold      = Color(hex: 0xE8B86D)
    static let goldDeep  = Color(hex: 0xD4A96A)
    static let info      = Color(hex: 0xF0A878)   // light orange — info ⓘ glyphs (legible on dark)
    static let warn      = Color(hex: 0xF0A03C)   // amber — boost/overblow warnings
    static let stone     = Color(hex: 0xDAD7CE)
    static let stoneDim  = Color(hex: 0xDAD7CE).opacity(0.45)
    static let stoneFaint = Color(hex: 0xDAD7CE).opacity(0.16)
    static let line      = Color(hex: 0xDAD7CE).opacity(0.10)

    // MARK: Fonts
    /// Display / wordmark — Zilla Slab, falling back to the system serif.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        font("Zilla Slab", size: size, weight: weight, fallback: .system(size: size, weight: weight, design: .serif))
    }
    /// UI body — Inter, falling back to the system sans.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font("Inter", size: size, weight: weight, fallback: .system(size: size, weight: weight))
    }
    /// Technical readouts — JetBrains Mono, falling back to the system mono.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font("JetBrains Mono", size: size, weight: weight, fallback: .system(size: size, weight: weight, design: .monospaced))
    }

    private static func font(_ family: String, size: CGFloat, weight: Font.Weight, fallback: Font) -> Font {
        #if canImport(AppKit)
        // Only use the custom family if it actually registered.
        if NSFontManager.shared.availableFontFamilies.contains(family) {
            return Font.custom(family, size: size).weight(weight)
        }
        #endif
        return fallback
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
