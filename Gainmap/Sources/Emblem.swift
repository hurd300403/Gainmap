//
//  Emblem.swift
//  Gainmap
//
//  The Legacy Lab flask + camera-aperture emblem, ported from the canonical
//  brand SVG into SwiftUI. `GainmapEmblem` is the header/icon mark (rings +
//  flask + Gainmap's HDR-luminance liquid + aperture swirl). `ApertureIris` is
//  the larger central "fusion point" that spins while a merge runs.
//
//  All geometry is authored in the brand's 200×200 viewBox and scaled to the
//  view's frame, so the shapes are resolution-independent.
//

import SwiftUI

// MARK: - GainmapEmblem (header / icon mark)

struct GainmapEmblem: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 200
            ctx.scaleBy(x: s, y: s)

            // Concentric rings: accent outer, white halo, dark face.
            ctx.stroke(Path(ellipseIn: CGRect(x: 5, y: 5, width: 190, height: 190)),
                       with: .color(Theme.accent), lineWidth: 10)
            ctx.fill(Path(ellipseIn: CGRect(x: 15, y: 15, width: 170, height: 170)),
                     with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: 25, y: 25, width: 150, height: 150)),
                     with: .color(Theme.surface))

            // SVG group: translate(100,110) scale(0.9).
            let g = CGAffineTransform(translationX: 100, y: 110).scaledBy(x: 0.9, y: 0.9)

            // HDR luminance liquid (Gainmap's distinguishing twist): stone → white-hot.
            var liquid = Path()
            liquid.move(to: CGPoint(x: -21, y: -2))
            liquid.addLine(to: CGPoint(x: -30, y: 15))
            liquid.addQuadCurve(to: CGPoint(x: -20, y: 30), control: CGPoint(x: -32, y: 25))
            liquid.addLine(to: CGPoint(x: 20, y: 30))
            liquid.addQuadCurve(to: CGPoint(x: 30, y: 15), control: CGPoint(x: 32, y: 25))
            liquid.addLine(to: CGPoint(x: 21, y: -2))
            liquid.closeSubpath()
            ctx.fill(liquid.applying(g),
                     with: .linearGradient(
                        Gradient(colors: [Theme.stone, Color(hex: 0xF4E9D6), .white]),
                        startPoint: CGPoint(x: 100, y: 137),
                        endPoint: CGPoint(x: 100, y: 104)))

            // Flask outline + neck.
            var flask = Path()
            flask.move(to: CGPoint(x: -15, y: -55))
            flask.addLine(to: CGPoint(x: -15, y: -30))
            flask.addLine(to: CGPoint(x: -30, y: 15))
            flask.addQuadCurve(to: CGPoint(x: -20, y: 30), control: CGPoint(x: -32, y: 25))
            flask.addLine(to: CGPoint(x: 20, y: 30))
            flask.addQuadCurve(to: CGPoint(x: 30, y: 15), control: CGPoint(x: 32, y: 25))
            flask.addLine(to: CGPoint(x: 15, y: -30))
            flask.addLine(to: CGPoint(x: 15, y: -55))
            ctx.stroke(flask.applying(g), with: .color(Theme.stone),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            var neck = Path()
            neck.move(to: CGPoint(x: -18, y: -55))
            neck.addLine(to: CGPoint(x: 18, y: -55))
            ctx.stroke(neck.applying(g), with: .color(Theme.stone),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // Aperture swirl: six blades.
            for i in 0..<6 {
                var blade = Path()
                blade.move(to: CGPoint(x: 0, y: -18))
                blade.addQuadCurve(to: CGPoint(x: 9, y: 0), control: CGPoint(x: 11, y: -9))
                let t = CGAffineTransform(rotationAngle: Double(i) * .pi / 3).concatenating(g)
                ctx.stroke(blade.applying(t), with: .color(Theme.accent), lineWidth: 2)
            }

            // Center hub.
            let hub = Path(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10)).applying(g)
            ctx.fill(hub, with: .color(Theme.accent))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - GainmapAddEmblem (on-brand "add a photo" mark)

/// The Gainmap flask mark with an accent "+" badge in the corner — used for the
/// add tile / empty-state so the add affordance matches the app icon instead of
/// a bare system glyph. `active` brightens the badge (hover/emphasis).
struct GainmapAddEmblem: View {
    var active: Bool = false
    var body: some View {
        GainmapEmblem()
            .overlay {
                GeometryReader { geo in
                    let d = geo.size.width * 0.40          // badge ≈ 40% of the mark
                    Circle()
                        .fill(active ? Theme.accentHot : Theme.accent)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: d * 0.55, weight: .black))
                                .foregroundStyle(.white)
                        }
                        // Dark ring separates the accent badge from the mark's accent rim.
                        .overlay(Circle().stroke(Theme.surface, lineWidth: max(1, d * 0.11)))
                        .frame(width: d, height: d)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .position(x: geo.size.width - d * 0.42, y: geo.size.height - d * 0.42)
                }
            }
            .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - ApertureIris (center fusion point)

/// The six curved aperture blades, drawn to fill the view's frame.
private struct ApertureBlades: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 200
        var p = Path()
        for i in 0..<6 {
            var blade = Path()
            blade.move(to: CGPoint(x: 0, y: -40))
            blade.addQuadCurve(to: CGPoint(x: 20, y: 2), control: CGPoint(x: 24, y: -20))
            let t = CGAffineTransform(rotationAngle: Double(i) * .pi / 3)
                .concatenating(CGAffineTransform(translationX: 100, y: 100))
                .concatenating(CGAffineTransform(scaleX: s, y: s))
            p.addPath(blade.applying(t))
        }
        return p
    }
}

struct ApertureIris: View {
    var spinning: Bool

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = spinning ? (t.truncatingRemainder(dividingBy: 1.1) / 1.1) * 360 : 0
            ZStack {
                Circle()
                    .stroke(Theme.stoneFaint, lineWidth: 2)
                    .padding(6)
                ApertureBlades()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(angle))
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 18, height: 18)
            }
            .shadow(color: Theme.accent.opacity(0.35), radius: 7)
        }
    }
}
