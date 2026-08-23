import AppKit
import SwiftUI

/// Quick Open (⌘P): type a few letters, land on the file.
///
/// The fastest way between two documents in a library is not the sidebar tree,
/// which asks the reader to remember where things live; it is the thing every
/// editor taught them: fuzzy-match over everything, ranked, keyboard-driven.
/// Files come from `WorkspaceModel.allFiles()`, which reads folders that have
/// never been expanded, so nothing is missing just because the sidebar is
/// collapsed. An empty query lists the recents, which is usually the answer.
struct QuickOpenPanel: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var doc: DocumentModel
    let palette: Palette
    let close: () -> Void

    @State private var query = ""
    @State private var results: [FileNode] = []
    @State private var selection = 0
    /// Built once per presentation; a library does not change mid-keystroke.
    @State private var files: [FileNode] = []

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenField(
                query: $query, palette: palette, onChange: { filter() },
                onMove: moveSelection, onConfirm: confirm, onCancel: close
            )
            .padding(.horizontal, 13.8)
            .padding(.vertical, 10)

            if !results.isEmpty {
                Divider().overlay(palette.divider)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, node in
                                row(node, selected: index == selection)
                                    .id(index)
                                    .onTapGesture {
                                        selection = index
                                        confirm()
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) { _, newValue in
                        proxy.scrollTo(newValue, anchor: nil)
                    }
                    .frame(maxHeight: 324)
                }
            } else if !query.isEmpty {
                Text("No file matches")
                    .font(Typeface.displayMatching(13))
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.bg)
                .shadow(color: palette.text.opacity(0.22), radius: 22, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.divider, lineWidth: 1)
                )
        )
        .frame(width: 540)
        .onAppear(perform: loadLibrary)
        .onExitCommand(perform: close)
    }

    // MARK: Data

    private func loadLibrary() {
        files = workspace.allFiles()
        filter()
    }
    /// Recents when there is nothing typed; fuzzy matches, best first, after.
    /// Ranked results are capped — a reader narrows the query rather than
    /// scrolling a list of two hundred.
    private func filter() {
        let needle = query.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty {
            let recentPaths = Set(doc.recents.map(\.path))
            let alive = doc.recents.filter { FileManager.default.fileExists(atPath: $0.path) }
            var ordered: [FileNode] = []
            for url in alive {
                if let node = files.first(where: { $0.url.path == url.path }) {
                    ordered.append(node)
                }
            }
            let rest =
                files
                .filter { !recentPaths.contains($0.url.path) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            results = Array((ordered + rest).prefix(9))
            selection = 0
            return
        }

        var scored: [(Int, FileNode)] = []
        for node in files {
            let folder = node.url.deletingLastPathComponent().lastPathComponent
            if let points = score(query: needle, name: node.name, folder: folder),
                points > 0
            {
                scored.append((points, node))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1.name.localizedStandardCompare(rhs.1.name) == .orderedAscending
        }
        results = scored.prefix(12).map(\.1)
        selection = 0
    }

    /**
     * Ranks one file against the query: every whitespace-separated term must
     * land in the file's *name*, falling back to its immediate folder only for
     * terms the name does not carry.
     *
     * The first version matched scattered letters across the absolute path,
     * and `/Users/minh/…` carried enough vowels that almost nothing was ruled
     * out — typing a filename barely narrowed the list. Matching now starts
     * from what the reader actually types (the file's name), with the folder
     * as the secondary signal, so `notes api` still finds notes/api.md while
     * `readme` can no longer match half the library through its home prefix.
     */
    private func score(query: String, name: String, folder: String) -> Int? {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return nil }

        var total = 0
        for term in terms {
            let lowered = Array(term.lowercased())
            if let inName = subsequenceScore(lowered, in: name.lowercased()) {
                total += inName * 10
                continue
            }
            // A folder hit narrows the field but must never outrank a file
            // whose own name matched.
            guard let inFolder = subsequenceScore(lowered, in: folder.lowercased()) else {
                return nil
            }
            total += inFolder * 3
        }
        // Shorter names win ties.
        return total - name.count / 4
    }

    /**
     * How well `needle` fits into `haystack` as an unordered-in-advance
     * subsequence: every letter in order, nothing required between them.
     *
     * Contiguous runs beat scattered letters (a growing bonus per letter in
     * the run), letters after a separator or at the front beat word middles,
     * and anything short of a full subsequence returns nil — no match.
     */
    private func subsequenceScore(_ needle: [Character], in haystack: String) -> Int? {
        let hay = Array(haystack)
        var total = 0
        var searchFrom = 0
        var runBonus = 0
        for character in needle {
            // firstIndex on the slice reports absolute positions — slices keep
            // their parent's indices.
            guard let at = hay[searchFrom...].firstIndex(of: character) else { return nil }
            var gained = 1
            if at == searchFrom, total > 0 {
                gained += 4  // contiguous with the previous letter
                runBonus += 2
                gained += runBonus
            } else {
                runBonus = 0
            }
            if at == 0 || " ._-".contains(hay[at - 1]) {
                gained += 3  // a word start
            }
            total += gained
            searchFrom = at + 1
        }
        return total
    }
    // MARK: Keys

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func confirm() {
        guard results.indices.contains(selection) else { return }
        let target = results[selection].url
        close()
        doc.open(target)
    }

    // MARK: One row

    private func row(_ node: FileNode, selected: Bool) -> some View {
        let folder = node.url.deletingLastPathComponent().path
        return HStack(spacing: 7) {
            Image(systemName: "doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(selected ? palette.accentText : palette.muted.opacity(0.8))
                .frame(width: 14)
            Text(node.name)
                .font(Typeface.text(13))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(folder)
                .font(Typeface.displayMatching(11))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 13.8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.accent.opacity(0.16))
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The query field, with the four keys the palette lives by.
///
/// SwiftUI's TextField cannot take the arrow keys without a focus dance, and
/// this panel is nothing but arrows and return; an NSTextField says exactly
/// what each key means — through its *delegate*, not a keyDown override,
/// because while a field is being edited the keys are taken by the window's
/// field editor (an NSTextView), and the field's own keyDown never runs. The
/// field editor asks the delegate what to do about each editing command, and
/// that is where Enter, the arrows and Escape get their meaning.
/// `cancelOperation` also covers Escape when the field has lost focus, via
/// the panel's onExitCommand.
private struct QuickOpenField: NSViewRepresentable {
    @Binding var query: String
    let palette: Palette
    let onChange: () -> Void
    let onMove: (Int) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Find a file by name"
        field.font = NSFont(name: Typeface.body, size: 15) ?? .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        // Focus on arrival: the palette exists to be typed into.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != query { field.stringValue = query }
        field.textColor = NSColor(palette.text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            query: $query, onChange: onChange, onMove: onMove,
            onConfirm: onConfirm, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let query: Binding<String>
        private let onChange: () -> Void
        private let onMove: (Int) -> Void
        private let onConfirm: () -> Void
        private let onCancel: () -> Void

        init(
            query: Binding<String>, onChange: @escaping () -> Void,
            onMove: @escaping (Int) -> Void, onConfirm: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.query = query
            self.onChange = onChange
            self.onMove = onMove
            self.onConfirm = onConfirm
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            query.wrappedValue = field.stringValue
            onChange()
        }

        /// The palette's keys, as editing commands from the field editor.
        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSStandardKeyBindingResponding.moveUp(_:)):
                onMove(-1)
                return true
            case #selector(NSStandardKeyBindingResponding.moveDown(_:)):
                onMove(1)
                return true
            case #selector(NSStandardKeyBindingResponding.insertNewline(_:)):
                onConfirm()
                return true
            case #selector(NSStandardKeyBindingResponding.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}
