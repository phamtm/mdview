import SwiftUI

/// The small chrome controls the design allows: the icon button, the copy button
/// built from it, and the outline and ghost button styles. One file because they
/// are the shared vocabulary the rest of the chrome is assembled from, not
/// because each has many callers.

/// A 26pt square, transparent until hovered, then a gold wash — the design's
/// only interactive chrome treatment.
struct IconButton: View {
    /// The square's side. `ViewerView.collapsedZone` is measured from this, so
    /// the two cannot drift apart.
    static let size: CGFloat = 26

    let symbol: String
    let palette: Palette
    /// A toggle that is currently on keeps the gold wash, so its state is visible
    /// without hovering it.
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active || hovering ? palette.accentText : palette.muted)
                .frame(width: IconButton.size, height: IconButton.size)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.accent.opacity(active ? 0.16 : (hovering ? 0.14 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Copies the document's markdown, and says so for a moment afterwards.
struct CopyButton: View {
    let palette: Palette
    @State private var copied = false

    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", palette: palette) {
            NotificationCenter.default.post(name: .mdvCopyDocument, object: nil)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied = false
            }
        }
        .help(copied ? "Copied" : "Copy document (⌥⌘C)")
    }
}

/// Outlined, never filled — the design is explicit about that.
struct OutlineButtonStyle: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.display(13))
            .foregroundStyle(palette.accentText)
            .padding(.horizontal, 13.8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(palette.accent, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palette.accent.opacity(configuration.isPressed ? 0.22 : 0))
                    )
            )
    }
}

/// Text in the accent, no border — the design's ghost button.
struct GhostButtonStyle: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.display(12.5))
            .foregroundStyle(palette.accentText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.accent.opacity(configuration.isPressed ? 0.18 : 0))
            )
    }
}
