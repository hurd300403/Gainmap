//
//  UHDRRunner.swift
//  Gainmap
//
//  Thin, testable wrapper around the bundled `uhdrtool` CLI. All argument
//  construction, file-role classification, output-path derivation, and stderr
//  parsing live here as PURE functions so they can be unit-tested in Xcode
//  (⌘U) without spawning a process or touching the filesystem. The single
//  side-effecting method is `run(_:)`.
//
//  CLI contract (mirrors the upstream Lightroom plugin's ToolRunner.lua):
//      uhdrtool --hdr <in.tif> --sdr <in.jpg> --out <out.jpg> [--cgamut N] [--sgamut N]
//
//  uhdrtool prints progress + results to stderr (`hdr:`, `clamps:`, `wrote`),
//  and actionable failures as `error: …`. Exit 0 == success.
//

import Foundation

// MARK: - Color gamut

/// libultrahdr color-gamut selector. Raw values match uhdrtool's --cgamut/--sgamut
/// integer flags (0/1/2). Display labels differ between the HDR and SDR contexts
/// (see `hdrLabel` / `sdrLabel`) but the underlying integer is the same.
enum Gamut: Int, CaseIterable, Identifiable {
    case rec709 = 0   // sRGB / Rec.709
    case displayP3 = 1
    case rec2020 = 2

    var id: Int { rawValue }

    /// Label as shown for the HDR (TIFF) input.
    var hdrLabel: String {
        switch self {
        case .rec709: return "Rec.709"
        case .displayP3: return "Display P3"
        case .rec2020: return "Rec.2020"
        }
    }

    /// Label as shown for the SDR (JPEG) input. Note sRGB is the 0 case here.
    var sdrLabel: String {
        switch self {
        case .rec709: return "sRGB"
        case .displayP3: return "Display P3"
        case .rec2020: return "Rec.2020"
        }
    }
}

// MARK: - File role

/// Which input slot a file belongs in, inferred from its extension. The HDR
/// rendition is always the float TIFF; the SDR rendition is always the JPEG.
enum FileRole: Equatable {
    case hdr   // .tif / .tiff
    case sdr   // .jpg / .jpeg

    /// Classify a file by extension. Returns nil for anything that isn't a
    /// TIFF or JPEG, so the UI can reject unsupported drops.
    static func role(for url: URL) -> FileRole? {
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
struct ClampReadout: Equatable {
    var peakBoost: Double   // linear peak boost (×), floored at 1.0
    var stops: Double       // log2(peakBoost)
    var maxBoost: Double    // K — max content boost
    var targetNits: Int     // L — target display peak brightness
}

// MARK: - Outcome

enum RunOutcome: Equatable {
    case success(output: URL, readout: ClampReadout?)
    case failure(message: String)
}

// MARK: - Runner

struct UHDRRunner {

    enum LocateError: Error, LocalizedError {
        case binaryMissing
        var errorDescription: String? {
            "The bundled uhdrtool helper is missing from the app. Rebuild the app so the binary is copied into Gainmap.app/Contents/Resources."
        }
    }

    /// Where the HDR rendition comes from: a real float TIFF (advanced two-file
    /// mode) or a pre-synthesized raw RGBA f16 buffer (one-file auto mode).
    enum HDRSource: Equatable {
        case tiff(URL)
        case raw(URL, w: Int, h: Int)
    }

    /// A merge job: validated inputs + chosen gamuts + destination.
    struct Job: Equatable {
        var hdr: HDRSource
        var sdr: URL
        var out: URL
        var cgamut: Gamut = .rec709
        var sgamut: Gamut = .rec709
    }

    // MARK: Pure helpers (unit-tested)

    /// Build the exact argv passed to uhdrtool. Gamut flags are always included
    /// (explicit 0 is harmless and keeps the command self-documenting).
    static func arguments(for job: Job) -> [String] {
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
    static func defaultOutputURL(forSDR sdr: URL) -> URL {
        let base = sdr.deletingPathExtension().lastPathComponent
        return sdr.deletingLastPathComponent()
            .appendingPathComponent("\(base)_UltraHDR.jpg")
    }

    /// Parse the `clamps: peak=… (… stops)  K=…  L=…` line from stderr.
    /// Returns nil if the line isn't present (e.g. an early failure).
    static func parseClamps(_ stderr: String) -> ClampReadout? {
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
    static func parseOutcome(exitCode: Int32, stderr: String, output: URL) -> RunOutcome {
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
    static func bundledToolURL(in bundle: Bundle = .main) throws -> URL {
        if let url = bundle.url(forResource: "uhdrtool", withExtension: nil) {
            return url
        }
        if let url = bundle.url(forResource: "uhdrtool", withExtension: nil, subdirectory: "Helpers") {
            return url
        }
        throw LocateError.binaryMissing
    }

    // MARK: Execution (the only side-effecting method)

    /// Run uhdrtool for `job`. Runs off the main actor; safe to `await` from UI.
    func run(_ job: Job, toolURL: URL? = nil) async -> RunOutcome {
        let tool: URL
        do {
            tool = try toolURL ?? Self.bundledToolURL()
        } catch {
            return .failure(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        return await withCheckedContinuation { cont in
            // Process I/O (blocking reads + waitUntilExit) runs off the main
            // thread so the UI stays responsive during a merge.
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = tool
                proc.arguments = Self.arguments(for: job)

                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = Pipe()  // discard stdout (developer hooks only)

                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: .failure(message: "Could not launch uhdrtool: \(error.localizedDescription)"))
                    return
                }

                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: Self.parseOutcome(
                    exitCode: proc.terminationStatus, stderr: stderr, output: job.out))
            }
        }
    }
}
