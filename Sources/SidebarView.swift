import SwiftUI

/// The file tree: flat tint, no dividers, no icons — chevrons carry the
/// structure and root folders read as section labels.
struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var doc: DocumentModel
    /// Space kept clear at the top for the window's traffic lights.
    var topInset: CGFloat = 8

    // Density is set once for the whole surface — see DESIGN.md, "Components".
    static let rowHeight: CGFloat = 32
    static let indentStep: CGFloat = 18
    static let fontSize: CGFloat = 13
    /// Horizontal breathing room, and the inset of the selection fill.
    static let inset: CGFloat = 12
    /// Space above a root folder's label, so folders read as separate groups
    /// without a divider.
    static let groupSpacing: CGFloat = 16

    var body: some View {
        ZStack(alignment: .top) {
            background
            if workspace.roots.isEmpty { emptyState } else { tree }
        }
    }

    /// A hair off the document's own background, with no dividing line.
    private var background: some View {
        Color(nsColor: .textBackgroundColor)
            .overlay(Color.primary.opacity(0.035))
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(workspace.rows.enumerated()), id: \.element.id) { index, row in
                    SidebarRowView(
                        row: row, isFirst: index == 0,
                        workspace: workspace, doc: doc)
                }
                addFolderRow
            }
            .padding(.top, topInset)
            .padding(.bottom, 16)
            .padding(.horizontal, 6)
        }
    }

    /// Adding a folder lives at the end of the list instead of in a footer bar,
    /// so the sidebar needs no divider at the bottom.
    private var addFolderRow: some View {
        Button {
            workspace.addFolderPanel()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: SidebarView.indentStep)
                Text("Add Folder")
                    .font(.system(size: SidebarView.fontSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .frame(height: SidebarView.rowHeight)
            .padding(.horizontal, SidebarView.inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No folders")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Button("Add Folder…") { workspace.addFolderPanel() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarRowView: View {
    let row: SidebarRow
    let isFirst: Bool
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var doc: DocumentModel
    @State private var hovering = false

    private var node: FileNode { row.node }
    private var isCurrent: Bool { doc.canonicalPath == node.canonicalPath }
    /// Root folders read as quiet section headers rather than rows.
    private var isSectionHeader: Bool { node.isRoot }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * SidebarView.indentStep, height: 1)
            chevron
            title
            Spacer(minLength: 0)
        }
        .frame(height: isSectionHeader ? SidebarView.rowHeight - 4 : SidebarView.rowHeight)
        .padding(.horizontal, SidebarView.inset)
        .background(selection)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { activate() }
        .contextMenu { menu }
        .padding(.top, isSectionHeader && !isFirst ? SidebarView.groupSpacing : 0)
    }

    @ViewBuilder
    private var chevron: some View {
        if node.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: isSectionHeader ? 8 : 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                .frame(width: 13, alignment: .leading)
        } else {
            // Keeps file names aligned with folder names, since there are no icons.
            Color.clear.frame(width: 13, height: 1)
        }
    }

    private var title: some View {
        Text(isSectionHeader ? node.name.uppercased() : node.name)
            .font(
                .system(
                    size: isSectionHeader ? 10.5 : SidebarView.fontSize,
                    weight: isSectionHeader ? .semibold : .regular)
            )
            .tracking(isSectionHeader ? 0.5 : 0)
            .foregroundStyle(isSectionHeader ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var selection: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isCurrent {
            shape.fill(Color.primary.opacity(0.085))
        } else if hovering && !isSectionHeader {
            shape.fill(Color.primary.opacity(0.045))
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
