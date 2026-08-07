import SwiftUI

/// Semantic styling consumed by the shared native chat Markdown renderer.
/// Spatial windows should inherit their material and appearance instead of
/// introducing the opaque iOS surfaces from the main SwiftUI client.
enum T3Colors {
    static let surface = Color.secondary.opacity(0.05)
    static let surfaceRaised = Color.secondary.opacity(0.1)
    static let border = Color.secondary.opacity(0.16)
    static let separator = Color.secondary.opacity(0.12)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.8)
    static let accent = Color.accentColor
    static let success = Color.green
}

enum T3Typography {
    static let threadBody = Font.body
    static let threadHeading1 = Font.title2.bold()
    static let threadHeading2 = Font.title3.bold()
    static let threadHeading3 = Font.headline.bold()
    static let threadHeading4 = Font.body.bold()
    static let code = Font.callout.monospaced()
    static let control = Font.callout.weight(.medium)
    static let supporting = Font.footnote
    static let supportingStrong = Font.footnote.weight(.semibold)
}
