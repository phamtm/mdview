import SwiftUI

/// The document's headings, as the page reported them.
struct Outline {
    struct Heading: Identifiable {
        let level: Int
        let title: String
        let index: Int
        var id: Int { index }
    }

    var headings: [Heading] = []
    /// Which heading the reader is currently under.
    var current = -1
}

/// The contents panel: a column on the right of the document, mirroring the
/// library on the left. Left answers "where am I in my files", this answers
/// "where am I in this document".
struct OutlinePanel: View {
    let outline: Outline
    let palette: Palette
    /// Set by the reader, by dragging the panel's inner edge.
    var width: CGFloat = OutlinePanel.defaultWidth
    let jump: (Int) -> Void

    static let defaultWidth: CGFloat = 244
    private static let pad: CGFloat = 18.4
    private static let gap: CGFloat = 13.8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if outline.headings.isEmpty { emptyState } else { rows }
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(palette.sidebar)
    }

    private var header: some View {
        Text("Contents")
            .font(Typeface.display(10))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(palette.muted)
            .padding(.horizontal, Self.pad)
            .padding(.top, Self.pad)
            .padding(.bottom, Self.gap)
    }

    private var emptyState: some View {
        Text("No headings in this document.")
            .font(Typeface.text(12))
            .foregroundStyle(palette.muted)
            .padding(.horizontal, Self.pad)
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(outline.headings) { heading in
                    OutlineRow(
                        heading: heading,
                        isCurrent: heading.index == outline.current,
                        palette: palette
                    ) {
                        jump(heading.index)
                    }
                }
            }
            .padding(.bottom, Self.pad)
        }
    }
}

private struct OutlineRow: View {
    let heading: Outline.Heading
    let isCurrent: Bool
    let palette: Palette
    let jump: () -> Void
    @State private var hovering = false

    /// Level sets the indent, the tick's length and the type size, as in the
    /// design's contents panel.
    private var indent: CGFloat {
        switch heading.level {
        case 1: return 14
        case 2: return 26
        default: return 40
        }
    }

    private var tickWidth: CGFloat {
        switch heading.level {
        case 1: return 14
        case 2: return 9
        default: return 6
        }
    }

    /// The body face, with weight carrying the hierarchy.
    ///
    /// Cormorant is a high-contrast serif: at list sizes its hairlines thin to
    /// nothing, and a heavier weight only thickens the stems, widening the
    /// contrast that costs the legibility. Lora holds its strokes at 12pt. The
    /// document still sets headings in Cormorant, where the size suits it.
    private var font: Font {
        switch heading.level {
        case 1: return Typeface.text(13, weight: .semibold)
        case 2: return Typeface.text(12, weight: .medium)
        default: return Typeface.text(11.5)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Rectangle()
                .fill(isCurrent ? palette.accent : palette.text.opacity(0.28))
                .frame(width: tickWidth, height: 1)
                .offset(y: -4)
            Text(heading.title)
                .font(font)
                .foregroundStyle(isCurrent ? palette.accentText : palette.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, indent)
        .padding(.trailing, 9.2)
        .padding(.vertical, 5)
        .background(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(palette.accent).frame(width: 2)
            } else if hovering {
                Rectangle().fill(palette.accent.opacity(0.09))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: jump)
    }
}
