//
//  Theme.swift
//  GainmapCore
//
//  The Legacy Lab visual system, ported from the canonical Second Light /
//  Beam brand. Colors and the three-font stack (Zilla Slab display, Inter UI,
//  JetBrains Mono readouts) match the rest of the product family. Fonts are
//  bundled by each APP target (see Resources/Fonts + Info.plist
//  ATSApplicationFontsPath on macOS; UIAppFonts on iOS); if a family is
//  unavailable at runtime the helpers fall back to the closest system face so
//  the app always renders.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum Theme {

    // MARK: Palette  (hex from secondlight-mockups.html)
    public static let bg        = Color(hex: 0x1A1818)
    public static let bgDeep    = Color(hex: 0x141212)
    public static let surface   = Color(hex: 0x2C2A2B)
    public static let surfaceHi = Color(hex: 0x363334)
    public static let inset     = Color(hex: 0x111010)
    public static let accent    = Color(hex: 0xE05A3F)   // signature aperture red
    public static let accentHot = Color(hex: 0xF47A5E)
    public static let gold      = Color(hex: 0xE8B86D)
    public static let goldDeep  = Color(hex: 0xD4A96A)
    public static let info      = Color(hex: 0xF0A878)   // light orange — info ⓘ glyphs (legible on dark)
    public static let warn      = Color(hex: 0xF0A03C)   // amber — boost/overblow warnings
    public static let syncGreen = Color(hex: 0x2D8548)   // calm, legible synced state
    public static let stone     = Color(hex: 0xDAD7CE)
    public static let stoneDim  = Color(hex: 0xDAD7CE).opacity(0.45)
    public static let stoneFaint = Color(hex: 0xDAD7CE).opacity(0.32)   // was 0.16 — unreadable at small sizes
    public static let line      = Color(hex: 0xDAD7CE).opacity(0.10)

    // MARK: Fonts
    /// Display / wordmark — Zilla Slab, falling back to the system serif.
    public static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        font("Zilla Slab", size: size, weight: weight, fallback: .system(size: size, weight: weight, design: .serif))
    }
    /// UI body — Inter, falling back to the system sans.
    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font("Inter", size: size, weight: weight, fallback: .system(size: size, weight: weight))
    }
    /// Technical readouts — JetBrains Mono, falling back to the system mono.
    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font("JetBrains Mono", size: size, weight: weight, fallback: .system(size: size, weight: weight, design: .monospaced))
    }

    private static func font(_ family: String, size: CGFloat, weight: Font.Weight, fallback: Font) -> Font {
        // Only use the custom family if it actually registered at runtime —
        // per-platform check because the registries differ (AppKit font manager
        // vs UIKit family list).
        #if canImport(AppKit)
        if NSFontManager.shared.availableFontFamilies.contains(family) {
            return Font.custom(family, size: size).weight(weight)
        }
        #elseif canImport(UIKit)
        if UIFont.familyNames.contains(family) {
            return Font.custom(family, size: size).weight(weight)
        }
        #endif
        return fallback
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
