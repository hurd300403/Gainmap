//
//  VersionGate.swift
//  GainmapCore
//
//  Remote "disable old versions" kill-switch. On launch the app fetches a tiny
//  gate.json; if this build's integer build number is below `minimumBuild`, the
//  UI shows a non-dismissible "please update" overlay (with Update Now + a direct
//  download link). It FAILS OPEN: any network error, non-200, or parse failure
//  leaves the app fully usable — so an offline user, or a hiccup on the host, can
//  never brick the app. Lets Sam disable an old build instantly by editing one
//  file, no new release required.
//
//  The Info.plist key and fallback URL are init parameters so each platform
//  gates against its OWN file (Mac and iOS build-number series diverge): the
//  Mac app uses the defaults; the iOS app will pass its own key + gate-ios.json.
//
//  gate.json shape:
//    { "minimumBuild": 3, "message": "…", "downloadURL": "https://…" }
//

import Foundation

@MainActor
public final class VersionGate: ObservableObject {
    @Published public private(set) var blocked = false
    @Published public private(set) var message = "This version of Gainmap is no longer supported. Please update."
    @Published public private(set) var downloadURL = URL(string: "https://github.com/hurd300403/Gainmap/releases/latest")!

    private struct Gate: Decodable {
        let minimumBuild: Int
        let message: String?
        let downloadURL: String?
    }

    private let infoPlistKey: String
    private let fallbackURLString: String

    public init(infoPlistKey: String = "GainmapGateURL",
                fallbackURLString: String = "https://samhurdphotography.com/gainmap/gate.json") {
        self.infoPlistKey = infoPlistKey
        self.fallbackURLString = fallbackURLString
    }

    /// Fetch the gate and block only if this build is too old. Fails open.
    public func check() async {
        let raw = (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: raw.isEmpty ? fallbackURLString : raw) else { return }
        // Cache-bust so a freshly-edited gate.json is seen promptly.
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970))")]
        guard let url = comps.url else { return }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("Gainmap", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }  // fail open
            let gate = try JSONDecoder().decode(Gate.self, from: data)
            let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
            guard build < gate.minimumBuild else { return }   // current enough → no gate
            if let m = gate.message, !m.isEmpty { message = m }
            if let d = gate.downloadURL, let u = URL(string: d) { downloadURL = u }
            blocked = true
        } catch {
            // Fail OPEN — offline / host down / bad JSON never strands the user.
        }
    }
}
