//
//  CrashReporting.swift
//  GainmapCore
//
//  Sentry crash + error reporting, with aggressive privacy scrubbing. This app's
//  errors are made of users' file paths (e.g. /Users/<name>/Pictures/<client>/…)
//  and uhdrtool stderr, so every event is stripped of usernames/paths and no PII,
//  IP, screenshot, or view hierarchy is ever sent. Opt-out via Settings disables
//  the SDK entirely (it's only started here if enabled).
//

import Foundation
import Sentry

public enum CrashReporting {
    /// UserDefaults key for the "Send anonymous crash reports" toggle (default ON).
    /// Deliberately shared across platforms — consent is per-device either way.
    public static let defaultsKey = "gainmap.crashReporting"

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Start Sentry once at launch — only if the user hasn't opted out AND a DSN
    /// is configured. An empty DSN (dev builds) is a silent no-op. Call this
    /// before the rest of app init so the crash handler arms first.
    public static func bootstrap() {
        guard isEnabled else { return }
        let dsn = info("SentryDSN").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dsn.isEmpty else { return }

        let short = info("CFBundleShortVersionString", default: "0")
        let build = info("CFBundleVersion", default: "0")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.legacylab.gainmap"

        SentrySDK.start { options in
            options.dsn = dsn
            // Match the release id release.sh tags: bundleId@short+build.
            options.releaseName = "\(bundleID)@\(short)+\(build)"
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
            options.enableCrashHandler = true
            options.enableAutoSessionTracking = true   // crash-free-sessions health
            options.tracesSampleRate = 0.0             // no perf tracing for a desktop tool

            // Privacy hard-stops. On macOS screenshot / view-hierarchy capture
            // doesn't exist in the SDK; on iOS it DOES — hard-off both so the
            // window's client photos can never ride along with an event.
            options.sendDefaultPii = false
            options.maxBreadcrumbs = 30
            #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            #endif

            options.beforeSend = { event in
                event.user?.ipAddress = nil
                if let f = event.message?.formatted {
                    event.message = SentryMessage(formatted: redact(f))
                }
                event.exceptions?.forEach { ex in
                    ex.value = redact(ex.value)
                }
                if var extra = event.extra {
                    for (k, v) in extra { if let s = v as? String { extra[k] = redact(s) } }
                    event.extra = extra
                }
                return event
            }
            options.beforeBreadcrumb = { crumb in
                if crumb.category == "http" { return nil }   // drop Sparkle appcast etc.
                if let m = crumb.message { crumb.message = redact(m) }
                if var data = crumb.data {
                    for (k, v) in data { if let s = v as? String { data[k] = redact(s) } }
                    crumb.data = data
                }
                return crumb
            }
        }
    }

    /// Strip usernames / file paths so events carry no client or project names.
    /// Redaction consumes the WHOLE path tail, terminating at a quote or newline —
    /// not whitespace — because shoot folders contain spaces ("Client Names/…").
    /// uhdrtool quotes paths in its error lines, so quote-terminated matching is
    /// exact there; in unquoted prose it may over-consume to end-of-line, which is
    /// the right failure mode (over-redact rather than leak).
    /// The /var/mobile & /var/containers rules cover iOS sandbox paths (photo
    /// picker temp files, app containers); they can't match macOS paths, so they
    /// run unconditionally.
    public static func redact(_ s: String) -> String {
        var o = s
        let rules: [(String, String)] = [
            (#"file:///Users/[^\s"']+"#, "file:///Users/<redacted>"),
            (#"file:///private/var/mobile/[^\s"']+"#, "file:///var/<redacted>"),
            (#"/Users/[^"'\n]+"#,   "/Users/<redacted>"),
            (#"/Volumes/[^"'\n]+"#, "/Volumes/<redacted>"),
            (#"/private/var/mobile/[^"'\n]+"#, "/var/<redacted>"),
            (#"/var/mobile/[^"'\n]+"#, "/var/<redacted>"),
            (#"/var/containers/[^"'\n]+"#, "/var/<redacted>"),
        ]
        for (pat, rep) in rules {
            o = o.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }
        return o
    }

    private static func info(_ key: String, default def: String = "") -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? def
    }
}
