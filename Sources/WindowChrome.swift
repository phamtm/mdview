import AppKit
import SwiftUI

/// The titlebar treatment that lets content run to the top of the window.
///
/// In the app this is done by `.windowStyle(.hiddenTitleBar)` on the scene —
/// setting the AppKit properties by hand does not survive SwiftUI's own titlebar
/// setup. `apply` exists for the offscreen design tools, which build their own
/// windows with no SwiftUI scene to configure them.
@MainActor
final class WindowStyler {
    static let shared = WindowStyler()

    func apply(_ window: NSWindow?, background: NSColor? = nil) {
        let targets = window.map { [$0] } ?? NSApp.windows
        for target in targets where target.styleMask.contains(.titled) {
            // An empty unified toolbar is what moves the traffic lights down to
            // the centre of a taller band. Nothing is ever put in it.
            if target.toolbar == nil {
                let toolbar = NSToolbar(identifier: "mdview.titlebar")
                toolbar.showsBaselineSeparator = false
                target.toolbar = toolbar
            }
            if target.toolbarStyle != .unified { target.toolbarStyle = .unified }
            if !target.styleMask.contains(.fullSizeContentView) {
                target.styleMask.insert(.fullSizeContentView)
            }
            if !target.titlebarAppearsTransparent { target.titlebarAppearsTransparent = true }
            if target.titleVisibility != .hidden { target.titleVisibility = .hidden }
            if let background, target.backgroundColor != background {
                target.backgroundColor = background
            }
        }
    }

    /// Reports what actually stuck, for `tools/check-window-chrome.sh`.
    func describe() -> String {
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else {
            return "no titled window"
        }
        let content = window.contentView?.frame ?? .zero
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        var buttonCentre = -1.0
        if let button = window.standardWindowButton(.closeButton),
            let frame = button.superview?.convert(button.frame, to: nil)
        {
            buttonCentre = window.frame.height - frame.maxY + frame.height / 2
        }
        let windowBackground =
            window.backgroundColor.usingColorSpace(.sRGB).map {
                String(
                    format: "#%02x%02x%02x", Int($0.redComponent * 255),
                    Int($0.greenComponent * 255), Int($0.blueComponent * 255))
            } ?? "none"
        let appearance = window.appearance?.name.rawValue ?? "system"
        return [
            "windowBg=\(windowBackground)",
            "appearance=\(appearance)",
            "buttonCentre=\(Int(buttonCentre.rounded()))",
            "firstResponder=\(responder)",
            "titleVisibility=\(window.titleVisibility == .hidden ? "hidden" : "visible")",
            "fullSizeContentView=\(window.styleMask.contains(.fullSizeContentView))",
            "titlebarTransparent=\(window.titlebarAppearsTransparent)",
            "contentHeight=\(Int(content.height))",
            "windowHeight=\(Int(window.frame.height))",
        ].joined(separator: " ")
    }
}

/// Applies the chrome for whichever window hosts this view.
struct WindowChrome: NSViewRepresentable {
    /// The window's own background shows at the frame's edges during a resize,
    /// and behind everything else. It has to be the theme's, not the system's.
    var background: Color = .clear

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            WindowStyler.shared.apply(view.window, background: NSColor(background))
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            WindowStyler.shared.apply(view.window, background: NSColor(background))
        }
    }
}
