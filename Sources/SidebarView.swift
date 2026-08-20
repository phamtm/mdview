import SwiftUI

/// The library. Per the design: a labelled header with a search field, 27pt rows
/// carrying a chevron or file glyph and a badge, and a counted footer. Selection
/// is a gold tint with a 2pt rule down its left edge.
struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var doc: DocumentModel
    let palette: Palette

    static let width: CGFloat = 258
    static let rowHeight: CGFloat = 27
    static let indentStep: CGFloat = 16
    private static let pad: CGFloat = 18.4  // --space-4
    private static let gap: CGFloat = 13.8  // --space-3

    var body: some View {
        VStack(spacing: 0) {
            header
            if workspace.roots.isEmpty { emptyState } else { tree }
            footer
        }
        .background(palette.sidebar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9.2) {
            Text("Library")
                .font(Typeface.display(10))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(palette.muted)
            SearchField(
                query: Binding(
                    get: { workspace.query },
                    set: { workspace.query = $0 }
                ), palette: palette
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(palette.divider, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, Self.pad)
        .padding(.top, Self.pad)
        .padding(.bottom, Self.gap)
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(workspace.rows) { row in
                    SidebarRowView(row: row, palette: palette, workspace: workspace, doc: doc)
                }
            }
            .padding(.horizontal, 9.2)
            .padding(.bottom, Self.pad)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text(workspace.libraryMeta)
                .font(Typeface.text(10))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(palette.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.pad)
        .padding(.vertical, Self.gap)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9.2) {
            Text("No folders")
                .font(Typeface.display(15))
                .foregroundStyle(palette.muted)
            Button("Add Folder…") { workspace.addFolderPanel() }
                .buttonStyle(OutlineButtonStyle(palette: palette))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A text field with the design's outlined input treatment; the system search
/// field brings chrome of its own that fights the palette.
struct SearchField: NSViewRepresentable {
    @Binding var query: String
    let palette: Palette

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search files"
        field.font = NSFont(name: Typeface.body, size: 12) ?? .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != query { field.stringValue = query }
        field.textColor = NSColor(palette.text)
    }

    func makeCoordinator() -> Coordinator { Coordinator(query: $query) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let query: Binding<String>
        init(query: Binding<String>) { self.query = query }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            query.wrappedValue = field.stringValue
        }
    }
}

struct SidebarRowView: View {
    let row: SidebarRow
    let palette: Palette
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var doc: DocumentModel
    @State private var hovering = false

    private var node: FileNode { row.node }
    private var isCurrent: Bool { doc.canonicalPath == node.canonicalPath }

    var body: some View {
        HStack(spacing: 7) {
            glyph
            Text(node.name)
                .font(node.isDirectory ? Typeface.display(12.5) : Typeface.text(12.5))
                .tracking(node.isDirectory ? 0.75 : 0)
                .foregroundStyle(labelColour)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !badge.isEmpty {
                Text(badge)
                    .font(Typeface.text(10))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.text.opacity(0.45))
            }
        }
        .padding(.leading, 8 + CGFloat(row.depth) * SidebarView.indentStep)
        .padding(.trailing, 9.2)
        .frame(height: SidebarView.rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { activate() }
        .contextMenu { menu }
    }

    private var labelColour: Color {
        if isCurrent { return palette.text }
        return node.isDirectory ? palette.text : palette.muted
    }

    /// Folders carry a rotating chevron; files carry a page glyph.
    private var glyph: some View {
        Image(systemName: node.isDirectory ? "chevron.right" : "doc")
            .font(.system(size: node.isDirectory ? 9 : 10.5, weight: .medium))
            .foregroundStyle(isCurrent ? palette.accentText : palette.text.opacity(0.62))
            .rotationEffect(.degrees(node.isDirectory && node.isExpanded ? 90 : 0))
            .frame(width: 12, alignment: .leading)
    }

    /// Folders show how many children they hold when closed; files show their
    /// kind, unless it is the markdown this app is for.
    private var badge: String {
        if node.isDirectory {
            return node.isExpanded || node.children.isEmpty ? "" : String(node.children.count)
        }
        let ext = node.url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? "" : ext
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if isCurrent {
            shape
                .fill(palette.accent.opacity(0.16))
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.accent).frame(width: 2)
                }
        } else if hovering {
            shape.fill(palette.accent.opacity(0.10))
        }
    }

    private func activate() {
        if node.isDirectory { node.toggle() } else { doc.open(node.url) }
    }

    @ViewBuilder
    private var menu: some View {
        if node.isDirectory {
            Button(node.isExpanded ? "Collapse" : "Expand") { node.toggle() }
        } else {
            Button("Open") { doc.open(node.url) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        if node.isRoot {
            Divider()
            Button("Remove Folder from Sidebar") { workspace.remove(node) }
        }
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
