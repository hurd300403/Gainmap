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
/// GMUltraHDR bridge, writing the result where the job asked.
///
/// Runs INLINE in the caller's task — nonisolated async, so it executes on the
/// concurrent executor (off the main actor) WITHOUT Task.detached. Detaching
/// here would sever cancellation inheritance and turn Stop into a no-op
/// mid-encode (P2 review finding): a detached task never sees the parent's
/// cancel, so a "stopped" batch could keep committing finished encodes.
enum InProcessEncoder {

    static func run(_ job: UHDRRunner.Job) async -> RunOutcome {
        // The encode itself can't be interrupted mid-flight (unlike the CLI
        // child, which Stop could SIGTERM), so cancellation is honored at the
        // boundaries: before the encode, before the write, and after the write
        // (discarding the file) — a Stop never lets a result stand.
        if Task.isCancelled { return .failure(message: "Stopped.") }
        let hdrData: Data
        let w: Int, h: Int
        switch job.hdr {
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
        guard let sdrData = try? Data(contentsOf: job.sdr) else {
            return .failure(message: "cannot open SDR JPEG '\(job.sdr.path)'")
        }
        if Task.isCancelled { return .failure(message: "Stopped.") }

        do {
            var clamps: GMUHDRClamps?
            let out = try GMUltraHDR.encode(
                hdrData, width: w, height: h, sdrJPEG: sdrData,
                cgamut: job.cgamut.rawValue, sgamut: job.sgamut.rawValue,
                clamps: &clamps)
            if Task.isCancelled { return .failure(message: "Stopped.") }
            try out.write(to: job.out)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: job.out)
                return .failure(message: "Stopped.")
            }
            let readout = clamps.map {
                ClampReadout(peakBoost: $0.peakBoost, stops: $0.stops,
                             maxBoost: $0.maxBoost, targetNits: $0.targetNits)
            }
            return .success(output: job.out, readout: readout)
        } catch {
            // Bridge errors carry the CLI's verbatim messages.
            return .failure(message: (error as NSError).localizedDescription)
        }
    }
}
