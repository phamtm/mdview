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
            if let points = score(query: needle, path: node.url.path, name: node.name), points > 0 {
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
     * Subsequence match over the full path, scored so what the reader means wins.
     *
     * Matching the path rather than the name alone lets a folder narrow the
     * field (`notes api` finds notes/api.md); the name's hits weigh more than
     * the folders', so a filename match beats a distant directory that merely
     * contains the letters. Contiguous runs beat scattered letters, word starts
     * beat word middles, and shorter paths break ties — `README.md` outranks
     * `vendor/lib/README.md`.
     */
    private func score(query: String, path: String, name: String) -> Int? {
        let haystack = Array(path.lowercased())
        let needle = Array(query.lowercased())
        let nameStart = path.count - name.count

        var total = 0
        var searchFrom = 0
        var runBonus = 0
        for character in needle {
            // firstIndex on the slice reports absolute positions — slices keep
            // their parent's indices.
            guard let at = haystack[searchFrom...].firstIndex(of: character) else { return nil }
            var gained = 1
            if at == searchFrom, total > 0 {
                gained += 4  // contiguous with the previous letter
                runBonus += 2
                gained += runBonus
            } else {
                runBonus = 0
            }
            if at == 0 || "/ ._-".contains(haystack[at - 1]) {
                gained += 3  // a word start
            }
            if at >= nameStart {
                gained += 6  // in the file's own name
            }
            total += gained
            searchFrom = at + 1
        }
        // Shorter paths win ties, and a match spread over a long path decays.
        return total * 8 - path.count / 4
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
/// this panel is nothing but arrows and return; an NSTextField subclass says
/// exactly what each key means. While the field holds focus the app's own plain
/// keys stand down (`KeyContext.isEditingText`), so `j` types a letter here
/// instead of turning the page underneath.
private struct QuickOpenField: NSViewRepresentable {
    @Binding var query: String
    let palette: Palette
    let onChange: () -> Void
    let onMove: (Int) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> QuickOpenTextField {
        let field = QuickOpenTextField()
        field.placeholderString = "Find a file by name"
        field.font = NSFont(name: Typeface.body, size: 15) ?? .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.onMove = onMove
        field.onConfirm = onConfirm
        field.onCancel = onCancel
        // Focus on arrival: the palette exists to be typed into.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: QuickOpenTextField, context: Context) {
        if field.stringValue != query { field.stringValue = query }
        field.textColor = NSColor(palette.text)
    }

    func makeCoordinator() -> Coordinator { Coordinator(query: $query, onChange: onChange) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let query: Binding<String>
        private let onChange: () -> Void
        init(query: Binding<String>, onChange: @escaping () -> Void) {
            self.query = query
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            query.wrappedValue = field.stringValue
            onChange()
        }
    }
}

final class QuickOpenTextField: NSTextField {
    var onMove: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow: onMove?(-1)
        case .downArrow: onMove?(1)
        default:
            switch event.charactersIgnoringModifiers {
            case "\r", "\u{3}": onConfirm?()
            case "\u{1b}": onCancel?()
            default: super.keyDown(with: event)
            }
        }
    }
}
