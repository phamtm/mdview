import AppKit
import SwiftUI

/// The Classical palette, for the parts of the window AppKit draws.
///
/// The document's copy of these tokens lives in `Resources/style.css`. Two
/// tables rather than one generated file is deliberate — see DESIGN.md — so a
/// value changed here has to be changed there too.
enum AppTheme: String, CaseIterable {
    case paper, vellum, night, system

    /// Which palette to draw, resolving `system` against the current appearance.
    func palette(dark: Bool) -> Palette {
        switch self {
        case .paper: return .paper
        case .vellum: return .vellum
        case .night: return .night
        case .system: return dark ? .night : .paper
        }
    }
}

struct Palette {
    let bg: Color
    let surface: Color
    /// The sidebar sits between the two: surface 62% over bg.
    let sidebar: Color
    let text: Color
    let muted: Color
    let divider: Color
    let accent: Color
    let accentText: Color

    // Classical ramps.
    private static let neutral100 = Color(hex: 0xf8_f4f4)
    private static let neutral200 = Color(hex: 0xea_e7e7)
    private static let neutral400 = Color(hex: 0xba_b6b6)
    private static let neutral900 = Color(hex: 0x2d_2b2b)
    private static let accent100 = Color(hex: 0xff_f3e4)
    private static let accent200 = Color(hex: 0xff_e3bf)
    private static let accent300 = Color(hex: 0xfa_cb8d)
    private static let accent400 = Color(hex: 0xe1_ad66)
    private static let accent500 = Color(hex: 0xc2_8d41)
    private static let accent600 = Color(hex: 0xa0_6f24)
    private static let accent800 = Color(hex: 0x5a_3b0a)
    private static let accent900 = Color(hex: 0x3a_270d)

    static let paper = Palette(
        bg: neutral100,
        surface: neutral200,
        sidebar: neutral200.mixed(with: neutral100, amount: 0.38),
        text: neutral900,
        muted: neutral900.opacity(0.64),
        divider: neutral900.opacity(0.16),
        accent: accent500,
        accentText: accent600
    )

    static let vellum = Palette(
        bg: accent100.mixed(with: neutral100, amount: 0.34),
        surface: accent200.mixed(with: neutral100, amount: 0.58),
        sidebar: accent200.mixed(with: neutral100, amount: 0.74),
        text: accent900,
        muted: accent900.opacity(0.62),
        divider: accent900.opacity(0.22),
        accent: accent600,
        accentText: accent800
    )

    static let night = Palette(
        bg: neutral900.mixed(with: .black, amount: 0.20),
        surface: neutral900.mixed(with: .white, amount: 0.12),
        sidebar: neutral900.mixed(with: .black, amount: 0.10),
        text: neutral100.opacity(0.92),
        muted: neutral400,
        divider: neutral100.opacity(0.18),
        accent: accent400,
        accentText: accent300
    )
}

/// Cormorant Garamond for headings and labels, Lora for running text — the
/// pairing the document uses. Registered from the bundle at launch: CoreText
/// cannot read the woff2 files the page uses, so the chrome ships variable TTFs.
enum Typeface {
    static let heading = "Cormorant Garamond"
    static let body = "Lora"

    static func register() {
        var urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? []
        if urls.isEmpty {
            // Running outside the app bundle (the design/snapshot tools).
            let dir = URL(fileURLWithPath: "Resources/fonts")
            urls =
                (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "ttf" } ?? []
        }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// Cormorant's x-height is 4.83 where Lora's is 6.25, both at 12.5pt
    /// (measured from the faces). The eye reads x-height as size, so mixed-case
    /// display text set at the body's point size looks a third too small.
    static let opticalRatio: CGFloat = 1.295

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(heading, size: size).weight(weight)
    }

    /// Display type that reads the same size as body type at `bodySize`. Use for
    /// mixed-case chrome — labels in caps are governed by cap height, not
    /// x-height, and need no correction.
    static func displayMatching(_ bodySize: CGFloat, weight: Font.Weight = .semibold) -> Font {
        display((bodySize * opticalRatio).rounded(), weight: weight)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(body, size: size).weight(weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }

    /// Blends towards `other` by `amount`, the way the design's color-mix() does.
    func mixed(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(
            .sRGB,
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t),
            opacity: 1
        )
    }
}
