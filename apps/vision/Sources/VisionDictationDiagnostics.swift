import Foundation
import Observation

/// A small, privacy-safe ring buffer that makes device-only dictation startup
/// diagnostics available to the person holding the device.
@MainActor
@Observable
final class VisionDictationDiagnostics {
    static let shared = VisionDictationDiagnostics()

    private static let maximumEntryCount = 300
    private(set) var entries: [String] = []

    func record(_ message: String) {
        let timestamp = Date.now.formatted(
            .dateTime.hour().minute().second().secondFraction(.fractional(3))
        )
        entries.append("\(timestamp)  \(message)")
        if entries.count > Self.maximumEntryCount {
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }
    }

    var copyableText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        return ([
            "T3 Vision dictation diagnostics",
            "App: \(version) (\(build))",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Transcribed text is intentionally excluded.",
            "",
        ] + entries).joined(separator: "\n")
    }
}
