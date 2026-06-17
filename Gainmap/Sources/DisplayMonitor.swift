//
//  DisplayMonitor.swift
//  Gainmap
//
//  Reports the active display's live EDR (extended dynamic range) headroom, purely
//  as informational context for the "Preview at headroom" control — so you can see
//  where your own display sits relative to the simulated viewer headrooms.
//
//  NOTE: EDR headroom is *inversely* proportional to SDR brightness — dim the
//  display and the multiplier above SDR white grows (e.g. ~16× at 50% brightness),
//  crank it up and it shrinks (~2.7× near max). So a high number means "lots of
//  room right now," NOT "boosted/miscalibrated" — there's no reliable way to tell
//  a boost tool apart from a normally-dimmed display, so we don't try.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class DisplayMonitor: ObservableObject {
    /// Current available EDR headroom (1.0 = no headroom / pure SDR).
    @Published private(set) var current: Double = 1.0

    private var timer: Timer?

    init() {
        sample()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sample),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // EDR headroom drifts with adaptive brightness with no notification, so
        // poll at a light cadence.
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
        if abs(c - current) > 0.005 { current = c }
    }
}
