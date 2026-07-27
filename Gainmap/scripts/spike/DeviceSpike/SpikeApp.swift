//  S1 device spike: on launch, run both probes and print results to stdout
//  (captured via `devicectl device process launch --console`) and on screen.
import SwiftUI
import CryptoKit
import Photos
import ImageIO

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

struct SpikeView: View {
    @State private var report = "running…"
    @State private var s2Report = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(report).font(.system(.footnote, design: .monospaced))
                Button("Run S2 Photos round-trip") {
                    s2Report = "S2 running…"
                    Task { s2Report = await runS2() }
                }.buttonStyle(.borderedProminent)
                Text(s2Report).font(.system(.footnote, design: .monospaced))
            }.padding()
        }
        .task { report = await Task.detached { runProbes() }.value }
    }
}

// S2: save a real UltraHDR export to Photos, re-fetch its bytes, verify the
// gain map survives. The load-bearing unknown of the whole iOS export story.
func runS2() async -> String {
    var lines = ["=== S2 PHOTOS ROUND-TRIP ==="]
    guard let fixURL = Bundle.main.url(forResource: "s2-fixture", withExtension: "jpg"),
          let original = try? Data(contentsOf: fixURL) else { return "S2: missing fixture" }
    let origHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    lines.append("orig: \(original.count) bytes sha \(String(origHash.prefix(16)))…")

    let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard auth == .authorized || auth == .limited else { return "S2: photo permission denied (\(auth.rawValue))" }

    var localID: String?
    do {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.shouldMoveFile = false
            opts.originalFilename = "s2-fixture.jpg"
            req.addResource(with: .photo, fileURL: fixURL, options: opts)
            localID = req.placeholderForCreatedAsset?.localIdentifier
        }
    } catch { return "S2: save failed — \(error.localizedDescription)" }
    guard let id = localID,
          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
        return "S2: created asset not found"
    }
    lines.append("saved asset \(String(id.prefix(12)))…")

    let resources = PHAssetResource.assetResources(for: asset)
    lines.append("resources: " + resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(separator: " "))
    guard let photoRes = resources.first(where: { $0.type == .photo }) else { return "S2: no .photo resource" }

    var fetched = Data()
    do {
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(for: photoRes, options: opts) { chunk in
                fetched.append(chunk)
            } completionHandler: { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
        }
    } catch { return "S2: re-fetch failed — \(error.localizedDescription)" }

    let fetchedHash = SHA256.hash(data: fetched).map { String(format: "%02x", $0) }.joined()
    lines.append("fetched: \(fetched.count) bytes sha \(String(fetchedHash.prefix(16)))…")
    lines.append(fetchedHash == origHash ? "BYTES: IDENTICAL ✅" : "BYTES: DIFFER ⚠️")

    // Gain-map survival on the ROUND-TRIPPED bytes (both dialects).
    if let src = CGImageSourceCreateWithData(fetched as CFData, nil) {
        var iso = false
        if #available(iOS 18.0, *) {
            iso = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        let apple = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        lines.append("ISO 21496-1 gain map: \(iso ? "PRESENT ✅" : "MISSING ❌")")
        lines.append("Apple/HDR gain map:  \(apple ? "present" : "absent")")
        lines.append((fetchedHash == origHash || iso) ? "S2/RESULT: PASS" : "S2/RESULT: FAIL")
    } else {
        lines.append("S2/RESULT: FAIL (fetched bytes not decodable)")
    }
    lines.append("Now open Photos and confirm the image visibly glows (HDR) on this screen.")
    lines.append("=== S2 DONE ===")
    let out = lines.joined(separator: "\n")
    print(out); fflush(stdout)
    return out
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
