import SwiftUI

/// The frontmatter disclosure that hangs under the document's name in the
/// titlebar: a 344pt card with a gold rule under its header, the fields as a
/// label/value grid, and list values as outlined pills.
struct FrontmatterPanel: View {
    let frontmatter: Frontmatter
    let palette: Palette

    private static let space2: CGFloat = 9.2
    private static let space3: CGFloat = 13.8
    private static let space4: CGFloat = 18.4
    private static let labelColumn: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if frontmatter.isEmpty { emptyState } else { parsedView }
        }
        .padding(Self.space4)
        .frame(width: 344)
        .background(palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(palette.divider, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 20)
    }

    /// Says so plainly, rather than opening an empty card.
    private var emptyState: some View {
        Text("This document has no front matter.")
            .font(Typeface.text(12.5))
            .foregroundStyle(palette.muted)
            .padding(.vertical, 2)
    }

    /// The one place a gold rule is used as a header underline.
    private var header: some View {
        HStack(spacing: Self.space3) {
            Text("Front matter")
                .font(Typeface.display(10))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(palette.accentText)
        }
        .padding(.bottom, Self.space2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.accent).frame(height: 1)
        }
        .padding(.bottom, Self.space3)
    }

    private var parsedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(frontmatter.rows.enumerated()), id: \.element.id) { index, field in
                HStack(alignment: .top, spacing: Self.space4) {
                    Text(field.name)
                        .font(Typeface.display(10))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(palette.muted)
                        .frame(width: Self.labelColumn, alignment: .leading)
                    Text(field.values.joined(separator: ", "))
                        .font(Typeface.text(13))
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) {
                    // The last row carries no rule.
                    if index < frontmatter.rows.count - 1 || !frontmatter.pills.isEmpty {
                        Rectangle().fill(palette.divider).frame(height: 1)
                    }
                }
            }

            if !frontmatter.pills.isEmpty {
                pills
            }
        }
    }

    private var pills: some View {
        FlowRow(spacing: 6) {
            ForEach(frontmatter.pills.flatMap(\.values), id: \.self) { value in
                Text(value)
                    .font(Typeface.display(10))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.accentText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(palette.accent, lineWidth: 1)
                    )
            }
        }
        .padding(.top, Self.space3)
    }

}

/// Wraps its children onto as many lines as they need. SwiftUI has no flow
/// layout, and the pills have to wrap in a 344pt panel.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
