//  S1 device spike: on launch, run both probes and print results to stdout
//  (captured via `devicectl device process launch --console`) and on screen.
import SwiftUI
import CryptoKit

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

struct SpikeView: View {
    @State private var report = "running…"
    var body: some View {
        ScrollView { Text(report).font(.system(.footnote, design: .monospaced)).padding() }
            .task { report = await Task.detached { runProbes() }.value }
    }
}

func runProbes() -> String {
    var lines: [String] = ["=== S1 DEVICE SPIKE ==="]
    let bundle = Bundle.main
    let tmp = FileManager.default.temporaryDirectory

    // Probe A: in-process encode, byte-parity vs the Mac CLI (bundled expected hash).
    if let raw = bundle.url(forResource: "test", withExtension: "rawf16"),
       let sdr = bundle.url(forResource: "test_sdr", withExtension: "jpg"),
       let expURL = bundle.url(forResource: "expected-cli", withExtension: "sha256"),
       let expected = try? String(contentsOf: expURL).trimmingCharacters(in: .whitespacesAndNewlines) {
        let out = tmp.appendingPathComponent("device.jpg")
        let result = spike_encode(raw.path, 512, 512, sdr.path, out.path)
        let clamps = result.map { String(cString: $0) } ?? "error: nil"
        result.map { free($0) }
        lines.append("A/encode: \(clamps)")
        if let bytes = try? Data(contentsOf: out) {
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            lines.append("A/sha256: \(hash)")
            lines.append(hash == expected ? "A/RESULT: PASS byte-identical to Mac CLI"
                                          : "A/RESULT: FAIL (expected \(expected))")
        } else {
            lines.append("A/RESULT: FAIL no output file")
        }
    } else {
        lines.append("A/RESULT: FAIL missing bundle resources")
    }

    // Probe B: render the verbatim bloom pipeline on this GPU, diff vs the Mac render.
    if let srcURL = bundle.url(forResource: "spike-src", withExtension: "jpg"),
       let refURL = bundle.url(forResource: "ref-mac", withExtension: "f16"),
       let jpeg = try? Data(contentsOf: srcURL),
       let ref = try? Data(contentsOf: refURL) {
        if let r = SpikeRender.renderF16(jpegData: jpeg) {
            lines.append("B/render: \(r.width)x\(r.height) \(r.data.count) bytes (ref \(ref.count))")
            if let c = SpikeRender.compare(r.data, ref) {
                lines.append(String(format: "B/maxAbsDiff: %.6f", c.maxAbs))
                lines.append(String(format: "B/meanAbsDiff: %.8f", c.meanAbs))
                lines.append(String(format: "B/PSNR: %.2f dB (peak 4.5 linear)", c.psnr))
                lines.append("B/RESULT: \(c.psnr > 60 ? "PASS" : "REVIEW") (plan threshold: PSNR > 60 dB)")
            } else {
                lines.append("B/RESULT: FAIL size mismatch")
            }
        } else {
            lines.append("B/RESULT: FAIL render")
        }
    } else {
        lines.append("B/RESULT: FAIL missing bundle resources")
    }

    lines.append("=== SPIKE DONE ===")
    let report = lines.joined(separator: "\n")
    print(report)                       // → devicectl --console
    fflush(stdout)
    return report
}
