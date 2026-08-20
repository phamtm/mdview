import SwiftUI

/// The frontmatter disclosure that hangs under the document's name in the
/// titlebar: a 344pt card with a gold rule under its header, the fields as a
/// label/value grid, list values as outlined pills, and a raw view of the block
/// as it appears in the file.
struct FrontmatterPanel: View {
    let frontmatter: Frontmatter
    @Binding var showingRaw: Bool
    let palette: Palette

    private static let space2: CGFloat = 9.2
    private static let space3: CGFloat = 13.8
    private static let space4: CGFloat = 18.4
    private static let labelColumn: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showingRaw { rawView } else { parsedView }
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

    /// The one place a gold rule is used as a header underline.
    private var header: some View {
        HStack(spacing: Self.space3) {
            Text("Front matter")
                .font(Typeface.display(10))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(palette.accentText)
            Spacer(minLength: 0)
            viewToggle
        }
        .padding(.bottom, Self.space2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.accent).frame(height: 1)
        }
        .padding(.bottom, Self.space3)
    }

    private var viewToggle: some View {
        HStack(spacing: 0) {
            ForEach(Array(["Parsed", "Raw"].enumerated()), id: \.element) { index, name in
                let selected = (name == "Raw") == showingRaw
                Text(name)
                    .font(Typeface.display(11))
                    .foregroundStyle(selected ? palette.text : palette.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(palette.accent.opacity(selected ? 0.16 : 0))
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle().fill(palette.divider).frame(width: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showingRaw = (name == "Raw") }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(palette.divider, lineWidth: 1)
        )
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

    /// The block exactly as it appears in the file, fences included.
    private var rawView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(frontmatter.raw)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(palette.text.opacity(0.85))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, Self.space3)
                .padding(.vertical, Self.space2)
        }
        .background(palette.surface)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous)
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.accent).frame(width: 2)
        }
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
