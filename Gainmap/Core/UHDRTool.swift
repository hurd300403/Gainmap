//
//  UHDRTool.swift
//  GainmapCore
//
//  The PURE half of the uhdrtool wrapper: argument construction, file-role
//  classification, output-path derivation, gamut detection, and stderr parsing —
//  all platform-independent and unit-tested without spawning a process or
//  touching the filesystem. The side-effecting Process runner lives in
//  UHDRToolProcess.swift (macOS-only; the CLI never ships on iOS — the
//  in-process encoder replaces it at the `runTool` seam in P2).
//
//  CLI contract (mirrors the upstream Lightroom plugin's ToolRunner.lua):
//      uhdrtool --hdr <in.tif> --sdr <in.jpg> --out <out.jpg> [--cgamut N] [--sgamut N]
//
//  uhdrtool prints progress + results to stderr (`hdr:`, `clamps:`, `wrote`),
//  and actionable failures as `error: …`. Exit 0 == success.
//

import Foundation
import ImageIO

// MARK: - Color gamut

/// libultrahdr color-gamut selector. Raw values match uhdrtool's --cgamut/--sgamut
/// integer flags (0/1/2). Display labels differ between the HDR and SDR contexts
/// (see `hdrLabel` / `sdrLabel`) but the underlying integer is the same.
public enum Gamut: Int, CaseIterable, Identifiable {
    case rec709 = 0   // sRGB / Rec.709
    case displayP3 = 1
    case rec2020 = 2

    public var id: Int { rawValue }

    /// Label as shown for the HDR (TIFF) input.
    public var hdrLabel: String {
        switch self {
        case .rec709: return "Rec.709"
        case .displayP3: return "Display P3"
        case .rec2020: return "Rec.2020"
        }
    }

    /// Label as shown for the SDR (JPEG) input. Note sRGB is the 0 case here.
    public var sdrLabel: String {
        switch self {
        case .rec709: return "sRGB"
        case .displayP3: return "Display P3"
        case .rec2020: return "Rec.2020"
        }
    }

    /// Pure mapping from an ICC profile name to the closest libultrahdr gamut.
    public static func matching(profileName: String) -> Gamut {
        let n = profileName.lowercased()
        if n.contains("p3") { return .displayP3 }
        if n.contains("2020") || n.contains("2100") { return .rec2020 }
        return .rec709
    }

    /// Best-effort gamut of an image's embedded ICC profile. libultrahdr
    /// HARD-FAILS when --sgamut disagrees with the profile in the JPEG
    /// ("configured color gamut does not match with color gamut specified in
    /// icc box"), so a Display P3 export from Lightroom would refuse to merge
    /// at all under a fixed sRGB flag. Defaults to Rec.709/sRGB when there is
    /// no readable profile (untagged JPEGs are treated as sRGB everywhere).
    public static func detect(of url: URL) -> Gamut {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let name = props[kCGImagePropertyProfileName] as? String else { return .rec709 }
        return matching(profileName: name)
    }
}

// MARK: - File role

/// Which input slot a file belongs in, inferred from its extension. The HDR
/// rendition is always the float TIFF; the SDR rendition is always the JPEG.
public enum FileRole: Equatable {
    case hdr   // .tif / .tiff
    case sdr   // .jpg / .jpeg

    /// Classify a file by extension. Returns nil for anything that isn't a
    /// TIFF or JPEG, so the UI can reject unsupported drops.
    public static func role(for url: URL) -> FileRole? {
        switch url.pathExtension.lowercased() {
        case "tif", "tiff": return .hdr
        case "jpg", "jpeg": return .sdr
        default: return nil
        }
    }
}

// MARK: - Clamp readout (parsed from uhdrtool stderr)

/// The gain-map clamp values uhdrtool computes and prints, surfaced in the UI
/// as the "instrument readout".
public struct ClampReadout: Equatable {
    public var peakBoost: Double   // linear peak boost (×), floored at 1.0
    public var stops: Double       // log2(peakBoost)
    public var maxBoost: Double    // K — max content boost
    public var targetNits: Int     // L — target display peak brightness

    public init(peakBoost: Double, stops: Double, maxBoost: Double, targetNits: Int) {
        self.peakBoost = peakBoost
        self.stops = stops
        self.maxBoost = maxBoost
        self.targetNits = targetNits
    }
}

// MARK: - Outcome

public enum RunOutcome: Equatable {
    case success(output: URL, readout: ClampReadout?)
    case failure(message: String)
}

// MARK: - Runner (pure surface)

public struct UHDRRunner {

    public init() {}

    public enum LocateError: Error, LocalizedError {
        case binaryMissing
        public var errorDescription: String? {
            "The bundled uhdrtool helper is missing from the app. Rebuild the app so the binary is copied into Gainmap.app/Contents/Resources."
        }
    }

    /// Where the HDR rendition comes from: a real float TIFF (advanced two-file
    /// mode) or a pre-synthesized raw RGBA f16 buffer (one-file auto mode).
    public enum HDRSource: Equatable {
        case tiff(URL)
        case raw(URL, w: Int, h: Int)
    }

    /// A merge job: validated inputs + chosen gamuts + destination.
    public struct Job: Equatable {
        public var hdr: HDRSource
        public var sdr: URL
        public var out: URL
        public var cgamut: Gamut
        public var sgamut: Gamut

        public init(hdr: HDRSource, sdr: URL, out: URL,
                    cgamut: Gamut = .rec709, sgamut: Gamut = .rec709) {
            self.hdr = hdr
            self.sdr = sdr
            self.out = out
            self.cgamut = cgamut
            self.sgamut = sgamut
        }
    }

    // MARK: Pure helpers (unit-tested)

    /// Build the exact argv passed to uhdrtool. Gamut flags are always included
    /// (explicit 0 is harmless and keeps the command self-documenting).
    public static func arguments(for job: Job) -> [String] {
        var args: [String]
        switch job.hdr {
        case .tiff(let url):
            args = ["--hdr", url.path]
        case .raw(let url, let w, let h):
            args = ["--raw-hdr", url.path, "--raw-w", String(w), "--raw-h", String(h)]
        }
        args += [
            "--sdr", job.sdr.path,
            "--out", job.out.path,
            "--cgamut", String(job.cgamut.rawValue),
            "--sgamut", String(job.sgamut.rawValue),
        ]
        return args
    }

    /// Default output location: `<sdr-basename>_UltraHDR.jpg` beside the SDR input.
    public static func defaultOutputURL(forSDR sdr: URL) -> URL {
        let base = sdr.deletingPathExtension().lastPathComponent
        return sdr.deletingLastPathComponent()
            .appendingPathComponent("\(base)_UltraHDR.jpg")
    }

    /// Pure check: does the FILENAME carry our own export suffix? (Unit-tested.)
    public static func nameLooksLikeMergedOutput(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix("_UltraHDR")
    }

    /// True when a file already looks like an UltraHDR export — our `_UltraHDR`
    /// name suffix, or an embedded gain map ImageIO can see. Merging such a file
    /// again would bloom the bloom, so the UI warns before double-processing.
    public static func looksLikeMergedOutput(_ url: URL) -> Bool {
        if nameLooksLikeMergedOutput(url) { return true }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return true
        }
        if #available(macOS 15.0, iOS 18.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return true
        }
        return false
    }

    /// Parse the `clamps: peak=… (… stops)  K=…  L=…` line from stderr.
    /// Returns nil if the line isn't present (e.g. an early failure).
    public static func parseClamps(_ stderr: String) -> ClampReadout? {
        // Example: "clamps: peak=3.973 (1.99 stops)  K=4.171  L=806"
        guard let line = stderr
            .split(separator: "\n")
            .first(where: { $0.contains("clamps:") }) else { return nil }
        let s = String(line)

        // Leading numeric run immediately following `key`.
        func number(after key: String) -> Double? {
            guard let r = s.range(of: key) else { return nil }
            let chars = s[r.upperBound...].prefix { "0123456789.+-eE".contains($0) }
            return Double(chars)
        }
        // The `stops` value sits before the word inside the parens: "(1.99 stops)".
        func stopsValue() -> Double? {
            guard let open = s.range(of: "("),
                  let kw = s.range(of: " stops", range: open.upperBound..<s.endIndex)
            else { return nil }
            return Double(s[open.upperBound..<kw.lowerBound].trimmingCharacters(in: .whitespaces))
        }

        guard let peak = number(after: "peak="),
              let k = number(after: "K="),
              let l = number(after: "L=") else { return nil }
        return ClampReadout(peakBoost: peak,
                            stops: stopsValue() ?? 0,
                            maxBoost: k,
                            targetNits: Int(l))
    }

    /// Map a finished process (exit code + captured stderr) to a RunOutcome.
    public static func parseOutcome(exitCode: Int32, stderr: String, output: URL) -> RunOutcome {
        if exitCode == 0 {
            return .success(output: output, readout: parseClamps(stderr))
        }
        // Surface uhdrtool's actionable `error: …` line if present.
        if let errLine = stderr
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("error:") }) {
            let msg = errLine.dropFirst("error:".count).trimmingCharacters(in: .whitespaces)
            return .failure(message: msg)
        }
        return .failure(message: "uhdrtool exited with code \(exitCode).")
    }

    /// Locate the bundled helper (copied into the app's Resources at build time).
    public static func bundledToolURL(in bundle: Bundle = .main) throws -> URL {
        if let url = bundle.url(forResource: "uhdrtool", withExtension: nil) {
            return url
        }
        if let url = bundle.url(forResource: "uhdrtool", withExtension: nil, subdirectory: "Helpers") {
            return url
        }
        throw LocateError.binaryMissing
    }
}
