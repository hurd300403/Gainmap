//
//  UHDREncoding.swift
//  GainmapCore
//
//  The production encode entry point behind MergeModel's `runTool` seam (P2).
//  Default everywhere: the IN-PROCESS encoder (GMUltraHDR -> encoder.cpp ->
//  the vendored libultrahdr) — byte-identical to the CLI by golden test, and
//  the only possible path on iOS (apps can't spawn helper binaries).
//
//  macOS keeps the CLI for ONE release as a rollback:
//      defaults write com.legacylab.gainmap GainmapEncoderBackend cli
//  The Process machinery is deleted in the release after 1.7 if nothing burns.
//

import Foundation

public enum UHDREncoding {

    /// UserDefaults rollback flag (macOS only, one release): set to "cli" to
    /// spawn the bundled uhdrtool instead of encoding in-process.
    public static let backendDefaultsKey = "GainmapEncoderBackend"

    public static var usesCLIFallback: Bool {
        #if os(macOS)
        UserDefaults.standard.string(forKey: backendDefaultsKey)?.lowercased() == "cli"
        #else
        false
        #endif
    }

    /// Encode `job`. Routing: in-process by default; the CLI when the macOS
    /// rollback flag is set, and for the (dev-only) two-file TIFF source, which
    /// only the CLI can read.
    public static func run(_ job: UHDRRunner.Job) async -> RunOutcome {
        #if os(macOS)
        if usesCLIFallback { return await runViaCLI(job) }
        if case .tiff = job.hdr { return await runViaCLI(job) }
        #endif
        return await InProcessEncoder.run(job)
    }

    #if os(macOS)
    /// CLI adapter (rollback path): materializes an in-memory HDR buffer to a
    /// temp file — the CLI reads files — then spawns the bundled uhdrtool
    /// exactly as 1.6 and earlier always did.
    static func runViaCLI(_ job: UHDRRunner.Job) async -> RunOutcome {
        switch job.hdr {
        case .rawBuffer(let buf):
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("gainmap-\(UUID().uuidString).rawf16")
            do { try buf.data.write(to: tmp) } catch {
                return .failure(message: "Couldn't stage the HDR buffer: \(error.localizedDescription)")
            }
            defer { try? FileManager.default.removeItem(at: tmp) }
            var staged = job
            staged.hdr = .raw(tmp, w: buf.width, h: buf.height)
            return await UHDRRunner().run(staged)
        case .tiff, .raw:
            return await UHDRRunner().run(job)
        }
    }
    #endif
}

/// The in-process encoder: computeClamps + libultrahdr encode via the
/// GMUltraHDR bridge, writing the result where the job asked. Runs detached —
/// an encode is seconds of CPU and must never block the main actor.
enum InProcessEncoder {

    static func run(_ job: UHDRRunner.Job) async -> RunOutcome {
        // Cancellation is honored BEFORE the encode starts and before the
        // output is written — unlike the CLI child, the encode itself can't be
        // interrupted mid-flight, so these are the cancellation points.
        if Task.isCancelled { return .failure(message: "Stopped.") }
        let j = job
        return await Task.detached(priority: .userInitiated) { () -> RunOutcome in
            let hdrData: Data
            let w: Int, h: Int
            switch j.hdr {
            case .rawBuffer(let buf):
                hdrData = buf.data; w = buf.width; h = buf.height
            case .raw(let url, let rw, let rh):
                guard let d = try? Data(contentsOf: url) else {
                    return .failure(message: "cannot open --raw-hdr '\(url.path)'")
                }
                hdrData = d; w = rw; h = rh
            case .tiff:
                return .failure(message: "TIFF input isn't supported by the in-process encoder.")
            }
            guard let sdrData = try? Data(contentsOf: j.sdr) else {
                return .failure(message: "cannot open SDR JPEG '\(j.sdr.path)'")
            }
            if Task.isCancelled { return .failure(message: "Stopped.") }

            do {
                var clamps: GMUHDRClamps?
                let out = try GMUltraHDR.encode(
                    hdrData, width: w, height: h, sdrJPEG: sdrData,
                    cgamut: j.cgamut.rawValue, sgamut: j.sgamut.rawValue,
                    clamps: &clamps)
                if Task.isCancelled { return .failure(message: "Stopped.") }
                try out.write(to: j.out)
                let readout = clamps.map {
                    ClampReadout(peakBoost: $0.peakBoost, stops: $0.stops,
                                 maxBoost: $0.maxBoost, targetNits: $0.targetNits)
                }
                return .success(output: j.out, readout: readout)
            } catch {
                // Bridge errors carry the CLI's verbatim messages.
                return .failure(message: (error as NSError).localizedDescription)
            }
        }.value
    }
}
