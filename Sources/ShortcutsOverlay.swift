import SwiftUI

/// Every key binding in the app, in the settings panel's clothes: a small window
/// over a dimmed, blurred backdrop, closed by Escape or by clicking away.
///
/// It holds no list of its own. Rows, sections and key caps are all read out of
/// `Shortcuts.all`, so a shortcut that is not in the table cannot appear here —
/// and one that is cannot be forgotten.
struct ShortcutsOverlay: View {
    let palette: Palette
    let close: () -> Void

    private static let space2: CGFloat = 9.2
    private static let space3: CGFloat = 13.8
    private static let space4: CGFloat = 18.4
    private static let space6: CGFloat = 27.6

    /// The table's own height, measured. The scroll area is given exactly this
    /// until the window is too short for it, which is what keeps the panel the
    /// same size as before at the current row count.
    @State private var tableHeight: CGFloat = 0

    /// What the panel needs besides the table: its title bar, its footer, and
    /// enough air above and below that it does not touch the window's edges.
    private static let chrome: CGFloat = 42 + 56 + 48

    var body: some View {
        // The window's height, which is the only thing that says whether the
        // table fits. A short window used to simply crop the panel: the title
        // bar, the first section and the Done button all ran off the edges with
        // no way to reach them.
        GeometryReader { geo in
            ZStack {
                backdrop
                panel(budget: max(geo.size.height - Self.chrome, 140))
            }
        }
        .onExitCommand(perform: close)
    }

    private var backdrop: some View {
        Color(.sRGB, red: 20 / 255, green: 19 / 255, blue: 18 / 255, opacity: 0.34)
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .onTapGesture(perform: close)
    }

    private func panel(budget: CGFloat) -> some View {
        VStack(spacing: 0) {
            panelTitleBar
            scrollingContent(budget: budget)
            footer
        }
        .frame(width: 640)
        .background(palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.text.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 35, x: 0, y: 30)
    }

    private var panelTitleBar: some View {
        HStack(spacing: 0) {
            Button(action: close) {
                Circle()
                    .fill(Color(hex: 0xe8_695f))
                    .overlay(Circle().strokeBorder(.black.opacity(0.16), lineWidth: 1))
                    .frame(width: 11, height: 11)
            }
            .buttonStyle(.plain)
            .help("Close")
            .frame(width: 90, alignment: .leading)

            Text("Keyboard Shortcuts")
                .font(Typeface.display(13))
                .tracking(0.26)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity)

            Spacer().frame(width: 90)
        }
        .padding(.horizontal, Self.space4)
        .frame(height: 42)
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    /// The table, scrollable only when it has to be.
    ///
    /// Held to its measured height, so at the current row count this is exactly
    /// the fixed-height panel it was before and nothing scrolls. Once the table
    /// is taller than the window can spare, the height stops at `budget` and the
    /// rest is reachable by scrolling instead of being cropped away.
    private func scrollingContent(budget: CGFloat) -> some View {
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { inner in
                        Color.clear
                            .onChange(of: inner.size.height, initial: true) { _, height in
                                tableHeight = height
                            }
                    }
                )
        }
        // nil until the first measurement: an unmeasured table keeps the old
        // behaviour rather than collapsing to nothing.
        .frame(height: tableHeight > 0 ? min(tableHeight, budget) : nil)
        // No rubber-band when everything fits, so a panel that does not scroll
        // does not feel like one that does.
        .scrollBounceBehavior(.basedOnSize)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Self.space6) {
            ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: Self.space4) {
                    ForEach(column) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            sectionLabel(section.group.rawValue)
                                .padding(.bottom, Self.space2)
                            ForEach(section.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                // Width shared evenly; height left to the content, so the panel
                // is as tall as the table and no taller.
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, Self.space6)
        .padding(.vertical, Self.space6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typeface.display(10))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(palette.muted)
    }

    /// One action, with every key that reaches it.
    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.space2) {
            Text(entry.title)
                .font(Typeface.text(12))
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: Self.space2)
            HStack(spacing: 4) {
                ForEach(entry.keys, id: \.self) { key in
                    keyCap(key)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 3)
    }

    /// Outlined, never filled — the design's rule — at the same 4pt radius as the
    /// segmented control in the settings panel.
    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(Typeface.text(11, weight: .medium))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(palette.divider, lineWidth: 1)
            )
    }

    private var footer: some View {
        HStack {
            Text("Plain keys work while you are reading, not while you are typing.")
                .font(Typeface.text(11))
                .foregroundStyle(palette.muted)
            Spacer()
            Button("Done", action: close)
                .buttonStyle(OutlineButtonStyle(palette: palette))
        }
        .padding(.horizontal, Self.space4)
        .padding(.vertical, Self.space3)
        .background(palette.surface.opacity(0.45))
        .overlay(alignment: .top) {
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }

    // MARK: Read from the table

    /// One row: an action, its title, and every key that reaches it. Bindings of
    /// the same action share a title, which `tools/test-shortcuts.swift` pins.
    private struct Entry: Identifiable {
        let action: ShortcutAction
        let title: String
        var keys: [String]
        var id: ShortcutAction { action }
    }

    private struct Section: Identifiable {
        let group: Shortcut.Group
        let entries: [Entry]
        var id: String { group.rawValue }
        /// A heading plus a row each — what the two columns are balanced by.
        var rowCount: Int { entries.count + 1 }
    }

    private static let sections: [Section] = Shortcut.Group.allCases.compactMap { group in
        var entries: [Entry] = []
        for shortcut in Shortcuts.all where shortcut.group == group {
            if let index = entries.firstIndex(where: { $0.action == shortcut.action }) {
                entries[index].keys.append(shortcut.keyLabel)
            } else {
                entries.append(
                    Entry(action: shortcut.action, title: shortcut.title, keys: [shortcut.keyLabel])
                )
            }
        }
        return entries.isEmpty ? nil : Section(group: group, entries: entries)
    }

    /// Two columns, each section going wherever there is more room, so the panel
    /// is wide rather than a 600pt-tall list. Balanced from the table's own row
    /// counts; nothing here is placed by hand.
    private static let columns: [[Section]] = {
        var columns: [[Section]] = [[], []]
        var rows = [0, 0]
        for section in sections {
            let target = rows[0] <= rows[1] ? 0 : 1
            columns[target].append(section)
            rows[target] += section.rowCount
        }
        return columns
    }()
}
