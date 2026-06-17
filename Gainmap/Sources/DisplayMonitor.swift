//
//  DisplayMonitor.swift
//  Gainmap
//
//  Watches the current display's EDR (extended dynamic range) headroom so the UI
//  can tell when a screen is pushed past its color-accurate calibration — e.g.
//  when Vivid / BetterDisplay boost a MacBook to 1000–1600 nits. On a calibrated
//  display the gain-map pop looks right; on a boosted one the same content reads
//  as overblown, so we surface a warning and offer to clamp the preview back to
//  the calibrated ceiling.
//
//  NOTE: macOS exposes two values per NSScreen:
//    • maximumExtendedDynamicRangeColorComponentValue          — the *current*
//      available headroom (varies live with brightness / boost tools)
//    • maximumReferenceExtendedDynamicRangeColorComponentValue — the *calibrated*
//      HDR-reference headroom (0 when the display has no reference mode)
//  When the current value runs well above the reference, the display is being
//  driven past its calibrated range. The exact margin can need tuning per rig,
//  so both raw numbers are published and surfaced in the UI.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class DisplayMonitor: ObservableObject {
    /// Current available EDR headroom (1.0 = no headroom / pure SDR).
    @Published private(set) var current: Double = 1.0
    /// Calibrated HDR-reference headroom (0 if the display reports none).
    @Published private(set) var reference: Double = 0.0

    /// Fallback "calibrated" ceiling for displays that report no reference mode —
    /// roughly a ~600-over-300-nit baseline. Documented + surfaced in the UI.
    static let defaultCeiling = 2.0

    /// The headroom a calibrated viewer would see: the display's own HDR reference
    /// when it has one, else the conservative default.
    var calibratedCeiling: Double { reference > 1.01 ? reference : Self.defaultCeiling }

    /// True when the live headroom exceeds the calibrated target by a margin — the
    /// display is being driven past its color-accurate range (boost tool, etc.).
    var isBoosted: Bool { current > calibratedCeiling * 1.15 }

    private var timer: Timer?

    init() {
        sample()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sample),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // EDR headroom drifts with adaptive brightness and flips when a boost tool
        // engages, with no notification — so poll at a light cadence.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sample() {
        guard let screen = NSScreen.main else { return }
        let c = max(1.0, Double(screen.maximumExtendedDynamicRangeColorComponentValue))
        let r = Double(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
        if abs(c - current) > 0.005 { current = c }
        if abs(r - reference) > 0.005 { reference = r }
    }
}
