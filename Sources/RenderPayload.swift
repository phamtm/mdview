import Foundation

/// What Swift hands the page for one render.
///
/// The app and the snapshot harness both build this, so the two cannot drift —
/// a harness with its own copy of the contract will happily pass while the app
/// sends something else. `tools/check-payload.sh` checks both directions: every
/// key the page reads is sent, and every key sent is read.
struct RenderPayload {
    var markdown: String
    var path: String
    var dir: String
    var error: String
    var showFrontmatter: Bool
    var theme: String
    var size: String
    var alignment: String
    var measure: Double

    var dictionary: [String: Any] {
        [
            "markdown": markdown,
            "path": path,
            "dir": dir,
            "error": error,
            "showFrontmatter": showFrontmatter,
            "theme": theme,
            "size": size,
            "alignment": alignment,
            "measure": measure,
        ]
    }

    /// The JS call to evaluate, or nil if the payload cannot be encoded.
    var renderCall: String? {
        guard let json = try? JSONSerialization.data(withJSONObject: dictionary),
            let literal = String(data: json, encoding: .utf8)
        else { return nil }
        return "window.mdview.render(\(literal));"
    }

    /// Reads the display settings from defaults with explicit fallbacks, so
    /// behaviour never depends on whether a default was registered first.
    /// Defaults live here, in one place, rather than in each reader.
    static let defaultMeasure = 700.0

    static func settings(from defaults: UserDefaults = .standard) -> (
        showFrontmatter: Bool, theme: String, size: String, alignment: String, measure: Double
    ) {
        (
            showFrontmatter: defaults.object(forKey: "showFrontmatter") as? Bool ?? true,
            theme: defaults.string(forKey: "theme") ?? AppTheme.system.rawValue,
            size: defaults.string(forKey: "size") ?? "regular",
            alignment: defaults.string(forKey: "alignment") ?? "justify",
            measure: defaults.object(forKey: "measure") as? Double ?? defaultMeasure
        )
    }
}
